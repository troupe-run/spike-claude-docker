"""Q5: supervisor cancellation tests against a stand-in (no auth needed).

Run: uv run pytest -v -s tests/test_supervisor.py
"""
import asyncio
import os
import signal
import subprocess
import time
from pathlib import Path

import pytest

from spike_claude_docker.supervisor import LABEL, Run, container_exists, sweep_orphans

IMAGE = "troupe-claude:spike"
STANDIN = str(Path(__file__).with_name("standin.sh"))
HARDEN = ["--read-only", "--tmpfs", "/tmp", "--cap-drop", "ALL",
          "--security-opt", "no-new-privileges", "--network", "none", "--user", "1000:1000",
          "-v", f"{STANDIN}:/standin.sh:ro"]


def labelled_containers() -> list[str]:
    out = subprocess.run(["docker", "ps", "-aq", "--filter", f"label={LABEL}"],
                         capture_output=True, text=True).stdout
    return out.split()


@pytest.fixture(autouse=True)
def clean():
    asyncio.run(sweep_orphans())
    yield
    leftover = labelled_containers()
    asyncio.run(sweep_orphans())
    assert leftover == [], f"orphaned containers after test: {leftover}"


def test_streams_lines_bigger_than_64k_and_cancels_gracefully():
    r = Run(IMAGE, ["bash", "/standin.sh"], HARDEN + ["-e", "MODE=graceful"], grace_s=5)
    t0 = time.monotonic()
    res = asyncio.run(r.run(cancel_when=lambda l: isinstance(l, dict) and l.get("tick") == 5))
    dt = time.monotonic() - t0
    big = [l for l in res.lines if isinstance(l, dict) and "big" in l]
    print(f"\n  lines={len(res.lines)} big_line_len={len(big[0]['big'])} how={res.how} "
          f"rc={res.returncode} elapsed={dt:.1f}s last={res.lines[-1]}")
    assert big and len(big[0]["big"]) == 200_000
    assert res.cancelled and res.how == "graceful"
    assert {"type": "system", "subtype": "sigterm_received"} in res.lines
    assert not asyncio.run(container_exists(r.container))


def test_hard_cancel_when_actor_ignores_sigterm():
    r = Run(IMAGE, ["bash", "/standin.sh"], HARDEN + ["-e", "MODE=ignore"], grace_s=3)
    t0 = time.monotonic()
    res = asyncio.run(r.run(cancel_after_s=2))
    dt = time.monotonic() - t0
    print(f"\n  how={res.how} rc={res.returncode} elapsed={dt:.1f}s ticks={sum(1 for l in res.lines if isinstance(l, dict) and 'tick' in l)}")
    assert res.cancelled and res.how == "hard"
    assert res.returncode == 137  # SIGKILLed after grace
    assert not asyncio.run(container_exists(r.container))


def test_without_init_pid1_ignores_sigterm():
    """`sleep` as PID 1 with no handler: kernel drops SIGTERM for PID 1 -> docker stop waits the
    full grace then SIGKILLs. With --init (tini) the same command stops immediately."""
    timings = {}
    for init in (False, True):
        r = Run(IMAGE, ["sleep", "300"], HARDEN, grace_s=4, init=init)
        res = asyncio.run(r.run(cancel_after_s=1))
        timings[init] = res.how
    print(f"\n  without --init: {timings[False]}   with --init: {timings[True]}")
    assert timings == {False: "hard", True: "graceful"}


def test_killing_only_the_docker_cli_orphans_the_container():
    """The pitfall: killpg(SIGKILL) on the local `docker run` process (what a naive supervisor
    does, or what happens if the supervisor itself is SIGKILLed) leaves the container running."""
    async def go():
        r = Run(IMAGE, ["bash", "/standin.sh"], HARDEN)
        await r.start()
        await asyncio.sleep(2)
        os.killpg(r.proc.pid, signal.SIGKILL)
        await r.proc.wait()
        await asyncio.sleep(1)
        alive = await container_exists(r.container)
        swept = await sweep_orphans()
        return alive, swept
    alive, swept = asyncio.run(go())
    print(f"\n  container alive after killpg(docker CLI): {alive}; swept by label: {len(swept)}")
    assert alive is True
    assert len(swept) == 1


def test_sigterm_to_docker_cli_is_proxied():
    """docker run (no -t) proxies SIGTERM to the container by default (--sig-proxy)."""
    async def go():
        r = Run(IMAGE, ["bash", "/standin.sh"], HARDEN + ["-e", "MODE=graceful"])
        await r.start()
        await asyncio.sleep(2)
        os.killpg(r.proc.pid, signal.SIGTERM)
        rc = await asyncio.wait_for(r.proc.wait(), 15)
        await asyncio.sleep(1)
        return rc, await container_exists(r.container)
    rc, alive = asyncio.run(go())
    print(f"\n  rc={rc} container alive={alive}")
    assert alive is False


def test_default_64k_reader_limit_breaks_on_big_line():
    """Confirms the prior-art claim: asyncio's default StreamReader limit (64 KiB) raises on a
    single stream-json line bigger than that."""
    async def go():
        p = await asyncio.create_subprocess_exec(
            "python3", "-c", "print('x'*200000)", stdout=asyncio.subprocess.PIPE)
        try:
            await p.stdout.readline()
            return "ok"
        except ValueError as e:
            return f"ValueError: {e}"
        finally:
            await p.wait()
    msg = asyncio.run(go())
    print(f"\n  default limit: {msg}")
    assert msg.startswith("ValueError")


def test_real_claude_cancels_gracefully_while_retrying():
    """Real `claude -p` (no credentials needed): --network none + a bogus key makes it sit in its
    connection-retry backoff, which is a long-running claude we can cancel. Checks that claude
    itself honours SIGTERM (via tini) within the grace period and the container is removed."""
    flags = ["--read-only", "--tmpfs", "/tmp", "--tmpfs", "/home/actor:uid=1000,gid=1000",
             "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--network", "none",
             "--user", "1000:1000", "-e", "ANTHROPIC_API_KEY=sk-ant-bogus-not-a-real-key"]
    r = Run(IMAGE, ["claude", "-p", "--bare", "--output-format", "stream-json", "--verbose",
                    "say hi"], flags, grace_s=10)
    t0 = time.monotonic()
    res = asyncio.run(r.run(cancel_when=lambda l: isinstance(l, dict)
                            and l.get("subtype") == "api_retry" and l.get("attempt") == 3))
    dt = time.monotonic() - t0
    kinds = [(l.get("type"), l.get("subtype")) for l in res.lines if isinstance(l, dict)]
    print(f"\n  how={res.how} rc={res.returncode} elapsed={dt:.1f}s events={kinds}")
    assert res.cancelled and res.how == "graceful"
    assert not asyncio.run(container_exists(r.container))
