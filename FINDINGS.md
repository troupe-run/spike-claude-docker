# Spike: Claude Code in a Docker stage — FINDINGS

Throwaway feasibility spike for troupe.run. Started 2026-09-28.
Host: macOS arm64, Docker 29.8.0, Claude Code 2.1.281 (host).

Status legend: yes / yes-with-caveats / no / needs-owner-input / PENDING

| # | Question | Answer |
|---|---|---|
| 1 | Image with Claude Code; `claude --version` works | **yes** |
| 2 | Sandbox shape: only scratch workspace, no creds/env leakage | **yes** (network is separate — see Q3) |
| 3 | Egress allowlist | **yes** — `--internal` network + allowlisting CONNECT proxy sidecar |
| 4 | Write effects: RO inputs, RW declared output | **yes** |
| 5 | asyncio supervisor, stream-json, cancel cleanly incl. container | **yes-with-caveats** (must target the container, not just the CLI) |
| 6 | `--bare` and auth on host; settings/MCP/memory controls | **yes** — prior-art claim confirmed; and there are OAuth-compatible alternatives |
| 7 | Auth inside container — options only | **needs-owner-input** (options measured with bogus tokens; recommendation below) |
| 8 | Surprises / prior-art corrections | see below — prior art mostly right; `killpg` alone is insufficient |

## Q1 — Image with Claude Code installed

**Answer: yes.** `claude --version` → `2.1.281 (Claude Code)` inside the container, including with `--read-only` root fs and a tmpfs `$HOME`.

**Demo:** `demos/q1_image.sh` (Dockerfile at `image/Dockerfile`).

- Install method: the official **native installer** (`curl -fsSL https://claude.ai/install.sh | bash -s <VERSION>`), version pinned via build arg. `claude install [stable|latest|VERSION]` is the host-side equivalent. (The installer script itself refuses `sudo` from a user shell but is fine as plain root / a container user.)
- The native build is **one self-contained binary** (~237 MB, bundles its runtime). A builder stage runs the installer; the final stage `COPY`s only the binary to `/usr/local/bin/claude`. This (a) keeps the installer's download cache out of the image and (b) lets `$HOME` be a tmpfs at run time — if you leave the binary in `~/.local/share/claude` a tmpfs `$HOME` hides it.
- Base: `debian:bookworm-slim` + `ca-certificates curl git procps`; non-root `actor` uid 1000.
- Env baked in: `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, `DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.

**Size:** layer content ≈ 453 MB (108 MB debian-slim + 108 MB apt packages + 237 MB claude binary). `docker images` reports **623 MB** (Docker 29's containerd image store counts compressed + unpacked). Naive single-stage build was 968 MB (binary duplicated across layers) — use multi-stage.

```
$ demos/q1_image.sh
reported size: 623MB
237MB	COPY --chmod=0755 /home/actor/claude-bin /us…
69.6kB	RUN /bin/sh -c useradd --create-home --uid 1…
108MB	RUN /bin/sh -c apt-get update  && apt-get in…
108MB	# debian.sh --arch 'arm64' out/ 'bookworm' '…
2.1.281 (Claude Code)
```

Caveats: `curl` and `git` are in the image (needed by Claude Code's git features and the demos); a hardened image could drop `curl`. Slimming the 108 MB apt layer (e.g. no `git`) is possible but Claude Code expects git in most repo work.

## Q2 — Sandbox shape (only a scratch workspace)

**Answer: yes.** With the flags below, the container sees exactly one host path (`/workspace`), none of the host's env, no SSH agent, no `~/.ssh`/`~/.aws`/`~/.gnupg`/`~/.claude`, no docker socket, zero capabilities, read-only root.

**Demo:** `demos/q2_sandbox_shape.sh` (host side; sets a `HOST_CANARY` env var with a live `SSH_AUTH_SOCK` and real `~/.ssh` on the host) + `demos/probe_sandbox.sh` (runs inside; prints names only, never values).

Flags used (this is the "stage" baseline):
```
docker run --rm \
  --read-only --tmpfs /tmp:rw,nosuid,nodev --tmpfs /home/actor:rw,nosuid,nodev,uid=1000,gid=1000 \
  --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
  -v "$SCRATCH":/workspace:rw  troupe-claude:spike ...
```

Output (`demos/q2_output.txt`):
```
host: SSH_AUTH_SOCK set? yes  ~/.ssh exists? yes  HOST_CANARY set? yes
== whoami: uid=1000(actor) gid=1000(actor) groups=1000(actor)
== env (names only):
CLAUDE_CODE_DISABLE_AUTO_MEMORY CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_AUTOUPDATER HOME HOSTNAME PATH PWD SHLVL _ 
ok: SSH_AUTH_SOCK unset
ok: AWS_ACCESS_KEY_ID unset
ok: ANTHROPIC_API_KEY unset
ok: CLAUDE_CODE_OAUTH_TOKEN unset
ok: HOST_CANARY unset
absent: /Users
absent: /home/actor/.ssh
absent: /home/actor/.aws
absent: /home/actor/.gnupg
absent: /home/actor/.claude
absent: /home/actor/.claude.json
absent: /run/host-services/ssh-auth.sock
absent: /var/run/docker.sock
PRESENT: /root (drwx------ 2 root root 4096 Sep 18 00:00 /root)
== mounts (non-proc/sys/dev):
/ overlay ro,relatime,lowerdir=/var/lib/desktop-containerd/daemon/io.containerd.snapshotte
/dev tmpfs rw,nosuid,size=65536k,mode=755
/dev/shm tmpfs rw,nosuid,nodev,noexec,relatime,size=65536k
/probe.sh virtiofs ro,nosuid,nodev,relatime,ignore_atime,no_xattr
/tmp tmpfs rw,nosuid,nodev,noexec,relatime
/workspace virtiofs rw,nosuid,nodev,relatime,ignore_atime,no_xattr
/etc/hostname ext4 ro,relatime,discard
/etc/hosts ext4 ro,relatime,discard
/etc/resolv.conf ext4 ro,relatime,discard
/home/actor tmpfs rw,nosuid,nodev,noexec,relatime,mode=755,uid=1000,gid=1000
/proc/interrupts tmpfs rw,nosuid,size=65536k,mode=755
/proc/kcore tmpfs rw,nosuid,size=65536k,mode=755
/proc/keys tmpfs rw,nosuid,size=65536k,mode=755
/proc/scsi tmpfs ro,relatime,size=4k,nr_inodes=1
/proc/timer_list tmpfs rw,nosuid,size=65536k,mode=755
/sys/firmware tmpfs ro,relatime,size=4k,nr_inodes=1
== CapEff: 0000000000000000  NoNewPrivs: 1
== write to / : touch: cannot touch '/evil': Read-only file system
blocked
== write to /workspace : ok
```

Notes / caveats:
- Docker's default is already "nothing leaks": env vars only cross with `-e`/`--env-file`, and host paths only with `-v`. The risk is the **supervisor** adding them by habit (e.g. `-e SSH_AUTH_SOCK`, `-v ~/.claude:...`, `-v /var/run/docker.sock`). The stage must build the `docker run` argv from the declared effects only — never pass-through.
- Docker Desktop magic paths (`/run/host-services/ssh-auth.sock`) are **absent unless explicitly mounted** — confirmed.
- `/root` exists in the image but is `0700 root` and the actor is uid 1000 — not a leak, just the base image.
- `--tmpfs` defaults to **`noexec`** on Docker Desktop (see `/tmp` and `/home/actor` in the mount list). Fine for Claude Code itself (it sources shell snapshots, doesn't exec them) but actors that build/run binaries in `/tmp` need `--tmpfs /tmp:exec`. Not yet tested with a real `claude -p` session (needs auth — Q7).
- `$HOME` as tmpfs means Claude Code's `~/.claude.json` / session transcripts are ephemeral per run — good for isolation, and means **session transcripts are lost** unless troupe captures stream-json (it should — that's the event source anyway) or mounts a per-run `~/.claude/projects` dir.
- **Network is NOT restricted by this shape**: the default bridge reaches the internet and `host.docker.internal` (the Mac host). See Q3.

## Q3 — Network effects (egress allowlist)

**Answer: yes.** Recommended approach: **per-run `docker network create --internal` network + an allowlisting forward-proxy sidecar** (tinyproxy, default-deny host regex list) that is attached to both the internal network and the normal bridge. The actor container is only on the internal network and gets `HTTPS_PROXY=http://egress:3128`. Claude Code honours `HTTPS_PROXY` (verified: its traffic appears in the proxy log and its error message names the proxy).

**Demo:** `demos/q3_egress.sh` (proxy image: `proxy/Dockerfile`, `proxy/tinyproxy.conf`). Allowlist file is mounted into the proxy per run = the actor's declared hosts.

Output (`demos/q3_output.txt`):
```
--- allowed host via proxy (expect a real HTTP status from api.anthropic.com, e.g. 404/401/405)
curl https://api.anthropic.com/: HTTP 404 exit=0
--- disallowed host via proxy (expect proxy refusal: 403 on CONNECT -> curl exit 56, HTTP 000)
curl https://example.com/: HTTP 000 exit=56
--- bypass attempt: ignore proxy, go direct (expect no route: exit 6/7/28)
curl --noproxy * https://example.com/: HTTP 000 exit=6
curl --noproxy * https://1.1.1.1/: HTTP 000 exit=7
--- bypass attempt: Mac host via host.docker.internal (expect failure)
curl --noproxy * http://host.docker.internal:80/: HTTP 000 exit=6
--- DNS from inside internal network (does external name resolution work? = DNS exfil channel)
no external DNS
--- claude itself through the proxy (bogus API key, --bare; expect 401 from Anthropic = reached API)
result: {'subtype': 'success', 'is_error': True, 'result': 'Failed to authenticate. API Error: 401 API key is invalid.'}
--- claude with allowlist that does NOT include api.anthropic.com (expect proxy tunnel error)
result: {'subtype': 'success', 'is_error': True, 'result': "API Error: Couldn't connect through your proxy (ERR_PROXY_TUNNEL) — the proxy refused the tunnel: check its credentials and that it allows this host"}
--- proxy log (CONNECT decisions)
Sep 28 11:41:44.964 [1]: Connect (file descriptor 4): 172.23.0.3
Sep 28 11:41:44.964 [1]: Request (file descriptor 4): CONNECT api.anthropic.com:443 HTTP/1.1
Sep 28 11:41:44.964 [1]: Proxying refused on filtered domain "api.anthropic.com"
Sep 28 11:41:53.013 [1]: Connect (file descriptor 4): 172.23.0.3
Sep 28 11:41:53.013 [1]: Request (file descriptor 4): CONNECT api.anthropic.com:443 HTTP/1.1
Sep 28 11:41:53.013 [1]: Proxying refused on filtered domain "api.anthropic.com"
Sep 28 11:41:54.133 [1]: Connect (file descriptor 4): 172.23.0.3
Sep 28 11:41:54.133 [1]: Request (file descriptor 4): CONNECT api.anthropic.com:443 HTTP/1.1
Sep 28 11:41:54.133 [1]: Proxying refused on filtered domain "api.anthropic.com"
Sep 28 11:41:54.214 [1]: Connect (file descriptor 4): 172.23.0.3
Sep 28 11:41:54.214 [1]: Request (file descriptor 4): CONNECT api.anthropic.com:443 HTTP/1.1
Sep 28 11:41:54.214 [1]: Proxying refused on filtered domain "api.anthropic.com"
```

(The trailing proxy-log lines are from the second claude run, where `api.anthropic.com` was deliberately removed from the allowlist. The 401 in the first claude run is from Anthropic's API for a deliberately bogus key — proof the request got there; no real credential was used.)

What Claude Code genuinely needs (observed via proxy log, `--bare`, API-key mode):
- **`api.anthropic.com:443` only** — for the Messages call *and* startup fetches ("remote settings", "policy limits" — both on api.anthropic.com).
- With `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` **unset**, it additionally tries `http-intake.logs.us5.datadoghq.com` (telemetry). With it set (baked into the image), nothing else. Blocking telemetry does not break the run.
- Not observed (because never exercised): OAuth token refresh endpoints (OAuth-mode runs — Q7, unverified), `downloads.claude.ai` (autoupdater, disabled), WebFetch/WebSearch targets, MCP servers, `git`/package registries the *work* may need. Those are per-actor declared hosts.

Why this approach over the alternatives:
- **`--internal` network gives the hard guarantee** (no route; also no external DNS — confirmed `getent hosts example.com` fails, so no DNS exfil channel, and `host.docker.internal` does not resolve). The proxy is only the *allow* path. Even if the actor ignores `HTTPS_PROXY` (`curl --noproxy '*'`) it gets nowhere.
- `--network none` + proxy: cleanest isolation, but then the proxy has to be reached through a unix socket bind-mount plus an in-container TCP relay (socat) because Claude Code wants an HTTP proxy URL. More moving parts, same result. Viable fallback.
- iptables inside the actor container needs `NET_ADMIN` (contradicts `--cap-drop ALL`) and is DNS-fragile (IP allowlists for CDN-fronted hosts). Rejected.
- Docker Desktop on macOS gives no host-level per-container firewall. Rejected.

Caveats:
- CONNECT filtering is by **hostname**, not TLS-inspected. It cannot stop exfiltration *to an allowed host* — in particular the model conversation with api.anthropic.com is itself a channel. That is inherent to running an LLM agent; the allowlist bounds *where else* data can go.
- tinyproxy regexes are ERE; anchor them (`^api\.anthropic\.com$`). Unanchored patterns would allow `api.anthropic.com.evil.tld`.
- Plain-HTTP (non-CONNECT) requests are also filtered by host, but `ConnectPort 443` means CONNECT to other ports is refused — declare non-443 needs explicitly.
- Proxy is one extra container per run (~8 MB alpine image, starts in <1 s). Could be one shared proxy with per-source-IP allowlists, but per-run is simpler and matches "effects are per actor".
- Blocked egress shows up in stream-json as `api_retry` events then a final result with `is_error: true` and a clear `ERR_PROXY_TUNNEL` message — see Q8 on retries.

## Q4 — Write effects

**Answer: yes.** Declared inputs → `-v src:dst:ro`; declared outputs → `-v src:dst:rw`; everything else is the `--read-only` root fs (denied) or a tmpfs (`/tmp`, `$HOME`) that is discarded at exit. **Nested `:ro` mounts over a `:rw` mount work**, so "may edit the repo but not `.git/` or `.claude/`" is expressible — useful because `.git/hooks` and `.claude/settings.json` are code-execution vectors for the *next* process that touches the repo (including the host).

**Demo:** `demos/q4_write_effects.sh` (runs with `--network none`, uid 1000).

```
read input: spec
WRITE OK     : /out/result.txt        (declared output)
WRITE OK     : /workspace/src/b.py    (declared rw repo)
WRITE DENIED : /inputs/spec.md        (input, ro)
WRITE DENIED : rm /inputs/spec.md     (input, ro)
WRITE DENIED : /workspace/.git/hooks/pre-commit (nested ro)
WRITE DENIED : /workspace/.claude/settings.json (nested ro)
WRITE DENIED : /etc/passwd            (root fs)
WRITE DENIED : /usr/local/bin/claude  (root fs)
WRITE DENIED : /opt/new               (root fs)
WRITE OK     : /tmp/scratch           (ephemeral tmpfs, discarded)
host view after run:
./inputs/spec.md
./out/result.txt
./repo/src/a.py
./repo/src/b.py
```

Caveats:
- **Docker Desktop (macOS) does not enforce host file permissions** on bind mounts: a container uid 1000 wrote into a host dir with mode `0700` owned by the Mac user, and files land owned by the Mac user (virtiofs maps everything to the host user). So on macOS the `:ro` flag is the *only* write control — host perms/uid mismatch is no defence. On a Linux host uids are real and the actor uid must be able to write declared outputs (plan for `--user $(id -u):$(id -g)` or chown).
- Effects are mount-granular (directories or single files). A declared effect like "may write `src/**/*.py` but not `src/secrets/`" needs either nested ro mounts or a post-run diff check. Recommend troupe declares effects as path prefixes and a post-run `git status`/diff audit produces the event of record anyway (exit 0 ≠ work happened).
- `/tmp` and `$HOME` are writable but ephemeral; they are not "outputs". If an actor genuinely needs a cache (e.g. `~/.cache/uv`) that's an explicit declared mount.
- Mounting a single file (not dir) `:ro` works but editors that write-via-rename will fail on it — fine for inputs.

## Q5 — Supervision

**Answer: yes-with-caveats.** An asyncio supervisor streams stream-json lines (incl. >64 KiB lines) and cancels graceful-then-hard with **no orphaned containers** — *provided cancellation is aimed at the container* (`docker stop -t <grace>` → `docker rm -f`), not only at the local `docker run` process. Verified against a stand-in **and against real `claude -p`** (no credentials needed: `--network none` + bogus key keeps claude alive in its retry backoff, which is a genuine long-running claude to cancel).

**Demo:** `src/spike_claude_docker/supervisor.py`, `tests/test_supervisor.py`, `tests/standin.sh`. Run `uv run pytest -v -s tests/test_supervisor.py`. Every test has an autouse fixture that fails if any labelled container is left over; `docker ps -a --filter label=run.troupe.spike -q | wc -l` → `0` after the suite.

```
============================= test session starts ==============================
collecting ... collected 7 items

tests/test_supervisor.py::test_streams_lines_bigger_than_64k_and_cancels_gracefully 
  lines=8 big_line_len=200000 how=graceful rc=143 elapsed=1.1s last={'type': 'system', 'subtype': 'sigterm_received'}
PASSED
tests/test_supervisor.py::test_hard_cancel_when_actor_ignores_sigterm 
  how=hard rc=137 elapsed=5.1s ticks=24
PASSED
tests/test_supervisor.py::test_without_init_pid1_ignores_sigterm 
  without --init: hard   with --init: graceful
PASSED
tests/test_supervisor.py::test_killing_only_the_docker_cli_orphans_the_container 
  container alive after killpg(docker CLI): True; swept by label: 1
PASSED
tests/test_supervisor.py::test_sigterm_to_docker_cli_is_proxied 
  rc=143 container alive=False
PASSED
tests/test_supervisor.py::test_default_64k_reader_limit_breaks_on_big_line 
  default limit: ValueError: Separator is not found, and chunk exceed the limit
PASSED
tests/test_supervisor.py::test_real_claude_cancels_gracefully_while_retrying 
  how=graceful rc=143 elapsed=19.8s events=[('system', 'init'), ('system', 'api_retry'), ('system', 'api_retry'), ('system', 'api_retry')]
PASSED

============================== 7 passed in 39.55s ==============================
```

What the tests establish:
1. **Killing the `docker run` CLI does not kill the container.** `killpg(SIGKILL)` on the CLI (or the supervisor itself dying hard) leaves the container running (`test_killing_only_the_docker_cli_orphans_the_container`). `start_new_session=True` + `killpg` from the prior art is necessary for the local process tree but **not sufficient**. Hence: supervisor-chosen `--name`, a `--label`, cancellation via `docker stop`/`rm -f`, and a **startup orphan sweep by label** (reconcile against the event log's live runs).
2. SIGTERM (not SIGKILL) to the CLI *is* proxied to the container (`--sig-proxy` default without `-t`) — a nice-to-have, not something to rely on.
3. **`--init` is required.** Without it the actor is PID 1 and the kernel drops SIGTERM for PID 1 without a handler → every stop waits the full grace then SIGKILLs. With `--init` (tini) the same command stops immediately.
4. Graceful path: `docker stop -t N` → SIGTERM → actor → exit 143. Hard path: actor ignores TERM → SIGKILL at N s → exit 137. Both leave no container (`--rm`).
5. The 64 KiB asyncio default reader limit **does** raise (`ValueError: Separator is not found, and chunk exceed the limit`) on a 200 KB line — prior-art claim confirmed; `limit=` on `create_subprocess_exec` fixes it.
6. **Real claude honours SIGTERM** (exit 143 well inside the 10 s grace) — but emits **no final `result` event** when terminated. The supervisor must synthesise the "cancelled" event itself; absence of `result` is the signal.

What differs for real claude vs the stand-in (beyond the above):
- Claude's own subprocesses (Bash tool children) are torn down with the container's PID namespace regardless of whether claude forwards the signal — container-level kill is the reliable tree kill, which is a real advantage over host-side `killpg`.
- Cancelling mid-tool-call: side effects already written to rw mounts stay. Post-cancel audit (diff of declared output paths) should be recorded.
- Session transcripts live in the tmpfs `$HOME` and vanish; stream-json captured by the supervisor is the only record (by design).
- Useful stream-json events for supervision seen in this spike: `system/init` (tools, model, mcp_servers, permissionMode — record it), `system/api_retry` (`attempt`, `max_retries`, `error_status`, `error`: e.g. `authentication_failed`), final `result` (`is_error`, `result`, `total_cost_usd`).

## Q6 — `--bare`, auth, and config-source controls

**Answer: prior-art claim CONFIRMED.** `--bare` does block the target repo's hooks, `.mcp.json` servers and CLAUDE.md — **and** it never reads OAuth credentials (neither the keychain login nor `CLAUDE_CODE_OAUTH_TOKEN`). New finding: **`--safe-mode` and `--setting-sources user --strict-mcp-config` give the same repo-isolation while still accepting OAuth**, so the security control and subscription auth are not mutually exclusive.

### Evidence 1 — `claude --help` (2.1.281), verbatim
> `--bare` Minimal mode: skip hooks (those defined in settings and by installed plugins; ...), LSP, plugin sync, attribution, auto-memory, background prefetches, keychain reads, and CLAUDE.md auto-discovery. Sets CLAUDE_CODE_SIMPLE=1. **Anthropic auth is strictly ANTHROPIC_API_KEY or apiKeyHelper via --settings (OAuth and keychain are never read).** ... Explicitly provide context via: --system-prompt[-file], --append-system-prompt[-file], --add-dir (CLAUDE.md dirs), --mcp-config, --settings, --agents, --plugin-dir.

### Evidence 2 — one host invocation (logged in via claude.ai OAuth, Max subscription; no `ANTHROPIC_API_KEY` in env)
```
$ claude auth status --json   # fields other than these redacted
{'loggedIn': True, 'authMethod': 'claude.ai', 'apiProvider': 'firstParty', 'subscriptionType': 'max', ...}
$ CLAUDE_CODE_MAX_RETRIES=0 claude -p --bare --no-session-persistence --max-budget-usd 0.01 --output-format json 'say hi'
{'subtype': 'success', 'is_error': True, 'result': 'Not logged in · Please run /login', 'total_cost_usd': 0, 'num_turns': 1, 'duration_api_ms': 0}
```
Zero cost, no API call. This was the only host-side `claude -p` call in the spike.

### Evidence 3 — hostile-repo matrix, in the container, no network, bogus credentials (`demos/q6_config_sources.sh`)
Target repo has `.claude/settings.json` with SessionStart + UserPromptSubmit hooks that `touch` marker files and `"enableAllProjectMcpServers": true`, a `.mcp.json` server that touches a marker, and a CLAUDE.md. Hooks and MCP start *before* any API call, so markers prove execution without auth.
```
##### auth env: CLAUDE_CODE_OAUTH_TOKEN (bogus value)
default (-p)                                 markers=[hook_promptsubmit hook_sessionstart mcp_started ] tools=21 mcp=['evil:pending'] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
--bare                                       markers=[] tools=3 mcp=[] | result='Not logged in · Please run /login'
--setting-sources user --strict-mcp-config   markers=[] tools=21 mcp=[] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
--setting-sources '' --strict-mcp-config     markers=[] tools=21 mcp=[] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
--safe-mode                                  markers=[] tools=21 mcp=[] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
--restricted --strict-mcp-config             markers=[] tools=19 mcp=[] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
##### auth env: ANTHROPIC_API_KEY (bogus value)
default (-p)                                 markers=[hook_promptsubmit hook_sessionstart mcp_started ] tools=21 mcp=['evil:pending'] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
--bare                                       markers=[] tools=3 mcp=[] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
--setting-sources user --strict-mcp-config   markers=[] tools=21 mcp=[] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
--setting-sources '' --strict-mcp-config     markers=[] tools=21 mcp=[] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
--safe-mode                                  markers=[] tools=21 mcp=[] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
--restricted --strict-mcp-config             markers=[] tools=19 mcp=[] | result="API Error: Can't reach the API server — check your internet or DNS (EA"
```
Evidence 4 — does the repo's CLAUDE.md reach the model? Fake API endpoint via `ANTHROPIC_BASE_URL` records the request body (`demos/q6_claude_md.sh`, `demos/fake_api.py`):
```
[default]                                    requests-with-CLAUDE.md=1  endpoints=['/v1/messages']
[--bare]                                     requests-with-CLAUDE.md=0  endpoints=['/v1/messages']
[--safe-mode]                                requests-with-CLAUDE.md=0  endpoints=['/v1/messages']
[--setting-sources user --strict-mcp-config] requests-with-CLAUDE.md=0  endpoints=['/v1/messages']
[--bare --add-dir /workspace]                requests-with-CLAUDE.md=1  endpoints=['/v1/messages']
```

Takeaways:
- **Plain `claude -p` in an untrusted repo executes that repo's hooks and MCP servers** — including a repo that self-approves its MCP servers via `enableAllProjectMcpServers` in its own project settings. `-p` skips the workspace-trust dialog (the help says so). This is the real hazard the prior art was guarding against; confirmed.
- `--bare`: nothing runs, CLAUDE.md not sent, **tools shrink to `Bash, Edit, Read`** (no `Write`, `WebFetch`, `Task`, …; `--tools Read,Write,...` does *not* restore them under `--bare`). OAuth rejected ("Not logged in"). Context must be passed explicitly (`--add-dir` re-enables CLAUDE.md from that dir — shown above).
- `--safe-mode`: nothing from the repo runs or is sent, full tool set, auth "works normally" per help (OAuth env accepted — got as far as the network).
- `--setting-sources user --strict-mcp-config`: same isolation for *project/local* settings + MCP, and project CLAUDE.md is not sent either. `--setting-sources ''` (empty) is accepted too. In the container, "user" settings = the tmpfs `$HOME`, i.e. empty, unless troupe provides one.
- `--restricted --strict-mcp-config`: isolation + drops code-running tools (19 tools) + confines file tools to working dirs. Too restrictive for a coding actor, interesting for review-only actors.

### Control surface (flags / env vars found in `--help` and the 2.1.281 binary)
| Concern | Control |
|---|---|
| Settings sources | `--setting-sources user,project,local` (subset or `''`), `--settings <file|json>` (additive), `--bare`, `--safe-mode` (`CLAUDE_CODE_SAFE_MODE=1`), `--restricted`, managed settings (`CLAUDE_CODE_MANAGED_SETTINGS_PATH`) still apply in all modes |
| MCP | `--mcp-config <files|json>`, `--strict-mcp-config` (ignore all other MCP config), `CLAUDE_CODE_SKIP_PLUGIN_MCP_SERVERS` |
| Memory | `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` (prior art: confirmed the var exists), `CLAUDE_CODE_DISABLE_ORG_MEMORY`; `--bare` disables auto-memory; CLAUDE.md discovery off under `--bare`/`--safe-mode`/`--setting-sources` without `project` |
| Config dir | `CLAUDE_CONFIG_DIR` (host session here uses `~/.claude-troupe`) |
| Retries | `CLAUDE_CODE_MAX_RETRIES` (default 10 — see Q8) |
| Budget / turns | `--max-budget-usd` (print mode). No `--max-turns` flag in 2.1.281 help. |
| Traffic | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `DISABLE_AUTOUPDATER=1` |
| Permission prompts in -p | `--permission-mode`, `--permission-prompts none` (anything that would prompt is auto-denied), `--allowedTools/--disallowedTools/--tools` |
| Auth | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR`, `apiKeyHelper` (settings), `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL` |

Caveats: env var names were found by `strings` on the binary, not all are documented — treat undocumented ones as unstable. `--safe-mode`'s OAuth acceptance was shown with a bogus token reaching the network stage, not with a real login.

## Q7 — Authentication inside the container (options only)

**Answer: needs-owner-input.** No real credential was read, copied, printed or created; `claude setup-token` was not run. All mechanics below were measured with a **bogus token** against a **fake API endpoint** (`ANTHROPIC_BASE_URL` → `demos/fake_api.py`, which logs only a SHA-256 prefix of the auth header) so we could see what claude actually sends and what an in-container process can see.

The key experimental result: **anything the actor process holds, the model's tools can reach.** Claude Code scrubs the token from its children's environment (good), but a child running as the same uid can still read `/proc/<claude>/environ`, `/proc/<claude>/fd/*` and even open `/proc/<claude>/mem` (Yama ptrace_scope is not enabled in the Docker Desktop VM; verified `child-open-parent-mem: ALLOWED`). So "not visible in `docker inspect`/`ps`" is achievable, but "not reachable by a prompt-injected actor" is only achievable by **keeping the credential out of the container**.

### Measured (`demos/q7_injection.sh`, hook = stand-in for a Bash-tool child; `demos/q7_hook_probe.sh`)
```
### A) env var (-e CLAUDE_CODE_OAUTH_TOKEN; value from supervisor env, not argv)
  docker inspect Env has token: 1
  docker inspect Mounts: /probe_hook.sh:ro 
  [child] own env has token: 0
  [child] own inherited fds: 0->socket:[9936814] 1->/tmp/probe.txt 10->/probe_hook.sh 11->socket:[9936817] 2->socket:[9936819] 3->pipe:[9940481] 
  [child] can read /proc/<claude>/environ token: 1
  [child] claude's fds: 0->/dev/null 1->/dev/null 10->anon_inode:[eventfd] 11->anon_inode:[eventpoll] 12->anon_inode:[eventfd] 13->socket:[9936802] 14->anon_inode:inotify 19->socket:[9936816] 2->/dev/null 23->socket:[9936818] 25->anon_inode:[pidfd] 3->anon_inode:[eventpoll] 4->anon_inode:[eventfd] 5->/dev/urandom 6->/proc/8/statm 7->/dev/null 8->/dev/null 9->anon_inode:[eventpoll] 
  [child] can read token via /proc/<claude>/fd/*: 0 fd(s)
  [child] secret file /run/secrets/token readable: no/absent
  fake API saw Bearer matching bogus token: 1 request(s)
### B) secret file bind-mounted ro, wrapper opens it as fd 3, exports only the fd number
  docker inspect Env has token: 0
  docker inspect Mounts: /probe_hook.sh:ro /run/secrets/token: 
  [child] own env has token: 0
  [child] own inherited fds: 0->socket:[9940559] 1->/tmp/probe.txt 10->/probe_hook.sh 11->socket:[9940562] 2->socket:[9940564] 3->pipe:[9940568] 
  [child] can read /proc/<claude>/environ token: 0
  [child] claude's fds: 0->/dev/null 1->/dev/null 10->anon_inode:[eventpoll] 11->anon_inode:[eventfd] 12->anon_inode:[eventpoll] 13->anon_inode:[eventfd] 14->socket:[9940547] 16->anon_inode:inotify 2->/dev/null 20->socket:[9940561] 24->socket:[9940563] 26->anon_inode:[pidfd] 3->/run/secrets/token 4->anon_inode:[eventpoll] 5->anon_inode:[eventfd] 6->/dev/urandom 7->/proc/9/statm 8->/dev/null 9->/dev/null 
  [child] can read token via /proc/<claude>/fd/*: 1 fd(s)
  [child] secret file /run/secrets/token readable: YES
  fake API saw Bearer matching bogus token: 1 request(s)
### C) token piped on stdin of docker run -i; wrapper turns it into fd 3 (never on disk/env)
  [child] own env has token: 0
  [child] own inherited fds: 0->socket:[9941334] 1->/tmp/probe.txt 10->/probe_hook.sh 11->socket:[9941337] 2->socket:[9941339] 3->pipe:[9940659] 
  [child] can read /proc/<claude>/environ token: 0
  [child] claude's fds: 0->/dev/null 1->/dev/null 10->anon_inode:[eventpoll] 11->anon_inode:[eventfd] 12->anon_inode:[eventpoll] 13->anon_inode:[eventfd] 14->socket:[9941322] 16->anon_inode:inotify 2->/dev/null 20->socket:[9941336] 24->socket:[9941338] 26->anon_inode:[pidfd] 3->pipe:[9939798] 4->anon_inode:[eventpoll] 5->anon_inode:[eventfd] 6->/dev/urandom 7->/proc/9/statm 8->/dev/null 9->/dev/null 
  [child] can read token via /proc/<claude>/fd/*: 0 fd(s)
  [child] secret file /run/secrets/token readable: no/absent
error: no such object: q7c-55485
  docker inspect Env has token: 0
  fake API saw Bearer matching bogus token: 1 request(s)
```
(For C, the `docker inspect` race — container already gone — is moot: option C passes no `-e` for the token by construction.)

### Option D measured (`demos/q7d_auth_injector.sh`, `demos/auth_injector.py`)
```
"result":"Failed to authenticate. API Error: 401 fake api"
actor can see real token anywhere in its fs/env: 0 files, env=0
fake API saw injected REAL token: 1 request(s); saw actor's dummy: 0
paths: "path": "/v1/messages 
```

### Options

| | How injected | Visible in `docker inspect` / host `ps` | Reachable by actor's tools | Notes |
|---|---|---|---|---|
| **(a) `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`**, as env (`-e NAME`, value from supervisor env) | env | **inspect: yes** (even with `-e NAME` form); `ps`: no (if not `-e NAME=value`) | **yes** via `/proc/<claude>/environ` (children's own env is scrubbed) | Simplest. Long-lived subscription token (exact validity/revocation path per Anthropic docs — not verified here). Uses subscription quota. `--bare` refuses it (Q6) → use `--setting-sources '' --strict-mcp-config` / `--safe-mode` instead. |
| (a') same token via **`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`**, fed through `docker run -i` stdin → wrapper → fd 3 (option C above) | stdin pipe | **no** / no | not via environ or fd (pipe drained); **yes via `/proc/<claude>/mem`** | Best in-container variant. Used by `run_authenticated.sh`. |
| (b) **file-based credential** (mount a credentials file / secret file) | bind mount | path only | **yes** — the file itself (Docker Desktop ignores host perms, Q4) and claude keeps the fd open (option B above) | Host login lives in the **macOS Keychain**, not a file, so there is no `~/.claude/.credentials.json` to mount; extracting it from the keychain means handling the raw OAuth access+refresh tokens (short-lived access token, refresh writes back to a store the container can't persist to a read-only/ephemeral HOME). Awkward and the worst exposure. **Not recommended.** On Linux hosts `~/.claude/.credentials.json` exists but the same objections apply (refresh token in the sandbox). |
| (c) **`ANTHROPIC_API_KEY`** (Console API key) | env, or `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR` (same stdin→fd trick), or `apiKeyHelper` in `--settings` | as (a)/(a') | same as (a)/(a') | Pay-per-token billing, org-level spend limits and per-key revocation; **works with `--bare`**. Cleanest fit for automation and for per-actor keys (one key per troupe / per actor for attribution and blast-radius). |
| **(d) credential-injecting sidecar** (recommended target) | actor gets a **dummy** token + `ANTHROPIC_BASE_URL=http://authproxy:8080`; sidecar (only it mounts the secret) swaps the auth header and forwards to `https://api.anthropic.com` | **no** (actor container) | **no** — the real credential never enters the actor's namespace (measured: 0 files, env 0; API saw the injected token, never the dummy) | Works with either credential type. Adds one small service. The sidecar also *is* the Anthropic egress path, so it doubles as the audit point (token usage per run). The prototype here is HTTP-to-fake-API; production must forward over TLS and stream (SSE) without buffering. |

Security trade-offs in one line each:
- (a) env: simplest; token readable by the actor and in `docker inspect` (anyone with Docker socket access = anyone who could already own the box, but inspect output tends to end up in logs/bug reports).
- (a') stdin→fd: keeps it out of inspect/ps/env/disk; still extractable by a malicious actor from process memory.
- (b) file: worst of both; also fights the keychain.
- (c) API key: better revocation/billing/`--bare` story; same in-container exposure as (a)/(a') unless combined with (d).
- (d) injector: only option where a prompt-injected actor **cannot exfiltrate the credential** (it can still spend it, via the model call — bound that with budget caps at the injector).

Open owner questions:
1. Subscription token (a) vs Console API key (c)? Check current Anthropic terms for using a subscription `setup-token` for unattended automation of this kind before relying on it.
2. Is (d) worth building for v1, or accept (a') for local single-user use and move to (d) before any multi-tenant/untrusted-repo use?
3. OAuth-with-injector is **unverified against the real API** (only fake API). `run_authenticated.sh` (option a') is the first real-credential test; an injector variant against the real API would be the second.

**`run_authenticated.sh`** (not run): expects `CLAUDE_CODE_OAUTH_TOKEN` in the environment; pipes it on stdin to an in-container wrapper → fd 3 → `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3`; full stage (internal network + allowlist proxy, RO root, tmpfs HOME, no caps, scratch workspace); asks claude to write `out/hello.txt` and then **checks the file** rather than trusting exit 0; prints proxy decisions so any extra host OAuth needs shows up as a refusal.

## Q8 — Surprises, things that didn't work, prior-art corrections

### Prior-art claims, verdicts
| Claim | Verdict | Evidence |
|---|---|---|
| `--bare` stops repo `.claude/settings.json` hooks and `.mcp.json` servers | **Confirmed** (also stops CLAUDE.md) | Q6 matrix |
| `--bare` "never reads OAuth credentials" | **Confirmed** — keychain login *and* `CLAUDE_CODE_OAUTH_TOKEN` both ignored ("Not logged in") | `--help` text; host run; container matrix |
| Set `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` | **Confirmed exists** (in binary); `--bare` also disables auto-memory | Q6 |
| Exit 0 is not evidence the work happened | **Confirmed, and worse**: failures report `"subtype": "success"` with `"is_error": true`. Check `is_error` + verify the effect | Q3/Q6 result events |
| asyncio subprocess, `start_new_session=True`, `killpg` | **Necessary but NOT sufficient in Docker**: killing the `docker run` CLI orphans the container | `test_killing_only_the_docker_cli_orphans_the_container` |
| Raise the 64 KiB stream reader limit | **Confirmed** (`ValueError` at default) | `test_default_64k_reader_limit_breaks_on_big_line` |
| `--output-format stream-json --verbose` | **Confirmed** (verified: `Error: When using --print, --output-format=stream-json requires --verbose`) | all demos |
| Blocked tools silently don't run | **Not tested** (needs a real model turn). Mitigations exist: `--permission-prompts none` makes would-prompt tools deny deterministically; verify effects post-run | — |
| *Implied*: `--bare` is the way to get the security control | **Refined**: `--safe-mode` or `--setting-sources '' --strict-mcp-config` give the same repo isolation *and* keep OAuth and the full tool set | Q6 |

### Surprises
1. **Auth failures and blocked egress look like hangs.** Default is 10 retries with exponential backoff (up to ~38 s per step): a bad key took **188 s** to fail. Set `CLAUDE_CODE_MAX_RETRIES` low (0–2) and/or have the supervisor abort on the `system/api_retry` event with `error: "authentication_failed"`. The retry events are nicely structured (`attempt`, `max_retries`, `retry_delay_ms`, `error_status`, `error`).
2. **`--bare` cuts the toolset to `Bash, Edit, Read`** (no `Write`, `WebFetch`, `Task`, …) and `--tools` can't add them back. Not in `--help`. A coding actor under `--bare` can still create files via Bash/Edit, but it is a different agent than default claude.
3. **Plain `claude -p` in a hostile repo runs its hooks and MCP servers, even ones self-approved by the repo's own `enableAllProjectMcpServers`.** `-p` skips the trust dialog. Never run plain `-p` on untrusted content.
4. **Claude honours SIGTERM but emits no `result` event** when terminated — the supervisor must write the "cancelled" event.
5. **PID 1 problem**: without `--init`, `docker stop` always takes the full grace period.
6. **Docker Desktop ignores host file permissions on bind mounts** (container uid 1000 wrote into a host `0700` dir and read a host `0600` secret). `:ro` is the only write control; never mount secrets you don't want the actor to read.
7. **Same-uid processes can read claude's `/proc/<pid>/environ`, open fds and memory** — any credential inside the actor container is reachable by the actor's tools. Claude does scrub the token from children's env, and keeps the `…_FILE_DESCRIPTOR` fd open for its lifetime.
8. `--tmpfs` mounts are `noexec` by default on Docker Desktop — pass `exec` if actors run built binaries from `/tmp`.
9. Variadic flags (`--add-dir`, `--tools`, `--allowedTools`, `--mcp-config`, …) swallow a following positional prompt → `Error: Input must be provided either through stdin or as a prompt argument`. Put the prompt immediately after `-p` (or pass it on stdin).
10. **No `--max-turns` in 2.1.281** `--help`; `--max-budget-usd` exists (print mode). Budget is the available cap.
11. Default model in a fresh container is `claude-opus-5-5[1m]` — pin `--model` per actor for cost predictability.
12. Even with nonessential traffic enabled, the only extra egress was Datadog log intake; with it disabled, **only `api.anthropic.com`** — a very small allowlist (API-key mode; OAuth-mode refresh endpoints unverified).
13. `docker images` reports 623 MB while layer content is ~453 MB (containerd image store accounting).
14. The `system/init` event is rich (tools, mcp_servers with status, model, permissionMode, apiKeySource, plugins, skills, claude_code_version) — worth recording as the first event of every run for auditability.

## RECOMMENDATION

**Feasible.** Docker is a workable first "stage" for a Claude Code executor: every declared effect in scope maps onto `docker run` flags, supervision is clean if cancellation targets the container, and the only genuinely open decision is the credential.

### Image
- `debian:bookworm-slim` + `ca-certificates curl git procps`; **native installer, version pinned** (`install.sh <VERSION>`) in a builder stage; copy the single binary to `/usr/local/bin/claude`. ~453 MB of content.
- Bake `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, `DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. Tag images by Claude Code version; upgrading is a rebuild, recorded in the event log.

### Egress
- Per run: `docker network create --internal troupe-<run>`; actor joins only that network.
- Allowlisting CONNECT proxy sidecar (tinyproxy, default-deny, anchored host regexes from the actor's declared hosts) bridged to the outside; actor gets `HTTPS_PROXY`/`HTTP_PROXY`. Baseline allowlist: `^api\.anthropic\.com$`.
- The internal network is the enforcement (no route, no external DNS, no `host.docker.internal`); the proxy is only the allow path and the audit log (every CONNECT decision → event).
- If auth option (d) is adopted, the auth injector becomes the Anthropic path and the CONNECT proxy only carries the actor's *other* declared hosts.

### Declared effects → `docker run` flags
| Effect | Flags |
|---|---|
| Baseline (always) | `--rm --init --name troupe-<run> --label run.troupe=<run> --read-only --tmpfs /tmp --tmpfs /home/actor:uid=1000,gid=1000 --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --pids-limit N` (+ `--memory`/`--cpus`) ; stdin `-i` only for credential hand-off |
| reads: path | `-v host:ctr:ro` |
| writes: path | `-v host:ctr:rw` |
| writes: repo except protected subpaths | `-v repo:/workspace:rw -v repo/.git:/workspace/.git:ro -v repo/.claude:/workspace/.claude:ro` (nested ro) |
| network: none | `--network none` |
| network: hosts [..] | `--network troupe-<run>` (internal) + proxy sidecar allowlist + `-e HTTPS_PROXY=…` |
| env: explicit names only | `-e NAME` for each declared name; never pass-through; never credentials |
| exec in tmp | `--tmpfs /tmp:exec` only if declared |

Plus Claude-level flags: `--setting-sources '' --strict-mcp-config` (or `--safe-mode`; `--bare` only with API-key auth and if the reduced toolset is acceptable), explicit `--mcp-config`/`--append-system-prompt`/`--add-dir` for context troupe *chooses* to give, `--permission-mode` + `--permission-prompts none`, `--model`, `--max-budget-usd`, `--no-session-persistence`, `--output-format stream-json --verbose`, `CLAUDE_CODE_MAX_RETRIES=2`. Prompt right after `-p` (or on stdin).

### Supervision
- asyncio `create_subprocess_exec(docker run …, start_new_session=True, limit=64 MiB)`, read stream-json line by line, each line → event.
- Cancel = `docker stop -t <grace> <name>` → if still present `docker rm -f` → reap/`killpg` the local CLI. Requires `--init`.
- On supervisor start: sweep containers with the troupe label that the event log doesn't show as live.
- Outcome is derived, not trusted: `result.is_error`, absence of `result` (cancelled/crashed), `api_retry` with `authentication_failed` → fail fast, and a post-run **effect audit** (diff of declared write paths) as the event of record. Exit code and `subtype` are not evidence.

### Auth (needs owner decision)
- **Target: option (d), credential-injecting sidecar.** The only option where a prompt-injected actor cannot read the credential (measured: actor sees nothing; API receives the injected token). Works with either a subscription token or an API key. Cost: one small service that must do TLS + SSE streaming properly; natural place for per-run spend caps and usage events.
- **Interim / first real test: option (a') — `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN`, handed over stdin → fd (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`)**, as in `run_authenticated.sh`. Keeps the token out of `docker inspect`, `ps`, env and disk; a malicious actor could still dig it out of process memory. Acceptable for a single owner running their own trusted prompts on their own repos; not for untrusted inputs.
- **API key (c)** is the better long-term credential for automation (per-key revocation and spend limits, works with `--bare`); pair it with (d).
- **Avoid (b)** file-based credentials: the macOS login is in the Keychain (no file to mount), extraction exposes refresh tokens, and Docker Desktop won't protect the file from the actor.

### What is verified vs not
- **Verified by running:** Q1 image; Q2 isolation; Q3 egress allow/deny/bypass/DNS incl. claude's own traffic via the proxy; Q4 ro/rw/nested mounts; Q5 supervisor + cancellation (stand-in and real claude), orphan pitfall, `--init`, 64 KiB; Q6 `--bare` behaviour (host + container), hostile-repo isolation matrix, CLAUDE.md inclusion via fake API; Q7 injection mechanics with bogus tokens, fake API, and injector sidecar.
- **Not verified (need a real credential):** an actual model turn in the container (tool use, file writes by claude, permission behaviour, "blocked tools silently don't run"); which extra hosts OAuth-mode needs (token refresh/profile); OAuth token through the injector against the real API; SSE streaming through a production injector; `run_authenticated.sh` itself (deliberately not run).


## Addendum 2026-09-28 — authenticated run (owner-run, real `setup-token` credential)

`run_authenticated.sh` was run by the owner in their own terminal (token never entered the agent session).
Result: **effect verified** — `out/hello.txt == hi`; `exit 0` plus the file check both pass. The egress proxy
logged exactly **3 × `CONNECT api.anthropic.com:443`** and nothing else, so OAuth-token mode needed no extra
hosts for this run (token refresh not exercised). Cost reported: $0.0298 (client-side estimate).
Note: the run used the default model (`claude-sonnet-5`) — the bake-off must pass `--model` explicitly to pin.
The init event listed the full tool set (Task, Bash, Edit, Cron*, worktree tools, …) — tool allowlisting
must be explicit per actor.
