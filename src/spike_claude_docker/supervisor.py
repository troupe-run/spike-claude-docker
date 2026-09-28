"""Spike: asyncio supervisor for `docker run ... claude -p ...` (throwaway).

Design points being tested:
- The container is NAMED and LABELLED by the supervisor. Cancellation targets the container via
  the Docker API/CLI (`docker stop` / `docker rm -f`), not just the local `docker run` process —
  killing the `docker run` CLI does not reliably kill the container.
- `--init` so PID 1 in the container is tini, which forwards SIGTERM to the actor and reaps.
- The local `docker run` CLI is started in its own session (start_new_session=True) so we can
  killpg it without touching the supervisor.
- stdout reader limit raised well above asyncio's 64 KiB default (stream-json lines can be huge:
  a single tool_result with a file's contents).
- Startup sweep: remove any container carrying our label whose owner run is not live (orphans
  from a supervisor that died hard).
"""

from __future__ import annotations

import asyncio
import json
import os
import signal
import uuid
from collections.abc import AsyncIterator, Sequence
from dataclasses import dataclass, field

LABEL = "run.troupe.spike"
STREAM_LIMIT = 64 * 1024 * 1024  # 64 MiB per line


@dataclass
class RunResult:
    run_id: str
    container: str
    returncode: int | None
    cancelled: bool
    how: str  # "exited" | "graceful" | "hard"
    lines: list[dict | str] = field(default_factory=list)
    stderr: str = ""


async def _docker(*args: str) -> tuple[int, str]:
    p = await asyncio.create_subprocess_exec(
        "docker", *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT
    )
    out, _ = await p.communicate()
    return p.returncode or 0, out.decode(errors="replace").strip()


async def container_exists(name: str) -> bool:
    rc, out = await _docker("ps", "-a", "--filter", f"name=^{name}$", "--format", "{{.Names}}")
    return rc == 0 and out.strip() == name


async def sweep_orphans() -> list[str]:
    """Remove every container carrying our label. In real troupe this would skip runs the event
    log says are live; for the spike, 'no live supervisor' == orphan."""
    rc, out = await _docker("ps", "-aq", "--filter", f"label={LABEL}")
    ids = [i for i in out.split() if i]
    if ids:
        await _docker("rm", "-f", *ids)
    return ids


class Run:
    def __init__(self, image: str, argv: Sequence[str], docker_flags: Sequence[str] = (),
                 grace_s: float = 5.0, init: bool = True):
        self.run_id = uuid.uuid4().hex[:12]
        self.container = f"troupe-{self.run_id}"
        self.image, self.argv, self.docker_flags = image, list(argv), list(docker_flags)
        self.grace_s, self.init = grace_s, init
        self.proc: asyncio.subprocess.Process | None = None
        self._cancel_how: str | None = None

    def docker_argv(self) -> list[str]:
        return [
            "docker", "run", "--rm", "--name", self.container,
            "--label", f"{LABEL}=1", "--label", f"{LABEL}.run={self.run_id}",
            *(["--init"] if self.init else []),
            *self.docker_flags, self.image, *self.argv,
        ]

    async def start(self) -> None:
        self.proc = await asyncio.create_subprocess_exec(
            *self.docker_argv(),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
            limit=STREAM_LIMIT,
        )

    async def lines(self) -> AsyncIterator[dict | str]:
        assert self.proc and self.proc.stdout
        while True:
            raw = await self.proc.stdout.readline()
            if not raw:
                return
            text = raw.decode(errors="replace").rstrip("\n")
            try:
                yield json.loads(text)
            except json.JSONDecodeError:
                yield text

    async def cancel(self) -> str:
        """Graceful: `docker stop -t grace` (SIGTERM to PID1 -> tini -> actor, SIGKILL after grace).
        Hard fallback: `docker rm -f` + killpg of the local docker CLI. Returns how it ended."""
        assert self.proc
        loop = asyncio.get_running_loop()
        t0 = loop.time()
        await _docker("stop", "-t", str(int(self.grace_s)), self.container)
        elapsed = loop.time() - t0
        how = "graceful" if elapsed < self.grace_s - 0.5 else "hard"
        # Belt and braces: container gone, local CLI gone.
        if await container_exists(self.container):
            await _docker("rm", "-f", self.container)
            how = "hard"
        try:
            await asyncio.wait_for(self.proc.wait(), timeout=5)
        except TimeoutError:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            await self.proc.wait()
        self._cancel_how = how
        return how

    async def run(self, cancel_after_s: float | None = None,
                  cancel_when=None) -> RunResult:
        """Run to completion, or cancel after a delay / when predicate(line) is true."""
        await self.start()
        result = RunResult(self.run_id, self.container, None, False, "exited")
        cancel_task: asyncio.Task | None = None

        async def consume():
            nonlocal cancel_task
            async for line in self.lines():
                result.lines.append(line)
                if cancel_when and cancel_task is None and cancel_when(line):
                    cancel_task = asyncio.create_task(self.cancel())

        consumer = asyncio.create_task(consume())
        if cancel_after_s is not None:
            done, _ = await asyncio.wait({consumer}, timeout=cancel_after_s)
            if not done:
                cancel_task = asyncio.create_task(self.cancel())
        await consumer
        if cancel_task:
            result.how = await cancel_task
            result.cancelled = True
        assert self.proc
        result.returncode = await self.proc.wait()
        if self.proc.stderr:
            result.stderr = (await self.proc.stderr.read()).decode(errors="replace")
        return result
