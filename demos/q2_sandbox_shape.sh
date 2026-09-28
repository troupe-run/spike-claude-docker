#!/usr/bin/env bash
# Q2: only a scratch workspace mounted RW; no host creds/env. Host has a canary + SSH agent set
# to prove nothing leaks by default.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT
export HOST_CANARY=should-not-leak
echo "host: SSH_AUTH_SOCK set? ${SSH_AUTH_SOCK:+yes}  ~/.ssh exists? $([ -d ~/.ssh ] && echo yes || echo no)  HOST_CANARY set? yes"
docker run --rm \
  --read-only --tmpfs /tmp:rw,nosuid,nodev --tmpfs /home/actor:rw,nosuid,nodev,uid=1000,gid=1000 \
  --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
  -v "$SCRATCH":/workspace:rw \
  -v "$PWD/demos/probe_sandbox.sh":/probe.sh:ro \
  troupe-claude:spike bash /probe.sh
