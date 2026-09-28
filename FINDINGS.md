# Spike: Claude Code in a Docker stage — FINDINGS

Throwaway feasibility spike for troupe.run. Started 2026-09-28.
Host: macOS arm64, Docker 29.8.0, Claude Code 2.1.281 (host).

Status legend: yes / yes-with-caveats / no / needs-owner-input / PENDING

| # | Question | Answer |
|---|---|---|
| 1 | Image with Claude Code; `claude --version` works | **yes** |
| 2 | Sandbox shape: only scratch workspace, no creds/env leakage | **yes** (network is separate — see Q3) |
| 3 | Egress allowlist | PENDING |
| 4 | Write effects: RO inputs, RW declared output | PENDING |
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

## Q3
PENDING
## Q4
PENDING
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
