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
| 5 | asyncio supervisor, stream-json, cancel cleanly incl. container | PENDING |
| 6 | `--bare` and auth on host; settings/MCP/memory controls | PENDING |
| 7 | Auth inside container — options only | PENDING |
| 8 | Surprises / prior-art corrections | PENDING |

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

## Q5
PENDING
## Q6
PENDING
## Q7
PENDING
## Q8
PENDING
## RECOMMENDATION
PENDING
