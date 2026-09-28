# Spike: Claude Code in a Docker stage — FINDINGS

Throwaway feasibility spike for troupe.run. Started 2026-09-28.
Host: macOS arm64, Docker 29.8.0, Claude Code 2.1.281 (host).

Status legend: yes / yes-with-caveats / no / needs-owner-input / PENDING

| # | Question | Answer |
|---|---|---|
| 1 | Image with Claude Code; `claude --version` works | **yes** |
| 2 | Sandbox shape: only scratch workspace, no creds/env leakage | PENDING |
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

## Q2
PENDING
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
