#!/usr/bin/env bash
# run_authenticated.sh — first REAL authenticated run of claude -p inside the troupe stage.
# NOT RUN during the spike. The owner supplies the credential:
#
#   claude setup-token                    # on the host, interactively; copy the printed token
#   read -rs CLAUDE_CODE_OAUTH_TOKEN; export CLAUDE_CODE_OAUTH_TOKEN
#   ./run_authenticated.sh
#
# How the token is handled (see FINDINGS.md Q7, option C):
#   - read from this script's environment, written to `docker run -i` STDIN (never argv, never
#     `-e`, never a file) -> not in `docker inspect`, not in host `ps`, not on disk.
#   - an in-container wrapper turns stdin into fd 3 and execs claude with
#     CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3, so the token is not in claude's environ either.
# Stage: internal network + allowlisting proxy (api.anthropic.com only), read-only root, tmpfs
# HOME, no caps, only a scratch workspace mounted. Repo hooks/MCP/CLAUDE.md are NOT loaded
# (--setting-sources '' --strict-mcp-config; --bare can't be used because it refuses OAuth).
set -euo pipefail
cd "$(dirname "$0")"
: "${CLAUDE_CODE_OAUTH_TOKEN:?export CLAUDE_CODE_OAUTH_TOKEN first (from claude setup-token)}"
ALLOW_HOSTS=${ALLOW_HOSTS:-'^api\.anthropic\.com$'}   # add e.g. OAuth refresh hosts if the run shows refusals

docker image inspect troupe-claude:spike >/dev/null 2>&1 || docker build -q -t troupe-claude:spike image/
docker image inspect troupe-egress:spike >/dev/null 2>&1 || docker build -q -t troupe-egress:spike proxy/

RUN=auth$$; NET=troupe-int-$RUN; WS=$(mktemp -d); ALLOW=$(mktemp)
cleanup() { docker rm -f "actor-$RUN" "proxy-$RUN" >/dev/null 2>&1 || true
            docker network rm "$NET" >/dev/null 2>&1 || true; rm -f "$ALLOW"; }
trap cleanup EXIT
mkdir -p "$WS/out"
printf '%s\n' $ALLOW_HOSTS > "$ALLOW"; chmod 644 "$ALLOW"

docker network create --internal "$NET" >/dev/null
docker run -d --name "proxy-$RUN" --network bridge -v "$ALLOW":/etc/tinyproxy/allow.txt:ro troupe-egress:spike >/dev/null
docker network connect --alias egress "$NET" "proxy-$RUN"

PROMPT="Create the file /workspace/out/hello.txt containing exactly the word: hi"
WRAPPER='IFS= read -r T; exec 3< <(printf %s "$T"); unset T
exec env CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3 claude -p "$PROMPT" \
  --setting-sources "" --strict-mcp-config \
  --permission-mode acceptEdits --permission-prompts none \
  --no-session-persistence --max-budget-usd 0.05 \
  --output-format stream-json --verbose </dev/null'

printf '%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" | docker run -i --rm --init --name "actor-$RUN" \
  --network "$NET" -e HTTPS_PROXY=http://egress:3128 -e HTTP_PROXY=http://egress:3128 \
  --read-only --tmpfs /tmp --tmpfs /home/actor:uid=1000,gid=1000 --user 1000:1000 \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 512 \
  -e CLAUDE_CODE_MAX_RETRIES=2 -e PROMPT="$PROMPT" \
  -v "$WS":/workspace:rw \
  troupe-claude:spike bash -c "$WRAPPER" | tee "$WS/stream.jsonl" | cut -c1-200

echo "--- exit 0 is not evidence; check the effect:"
if [ "$(cat "$WS/out/hello.txt" 2>/dev/null)" = "hi" ]; then echo "EFFECT VERIFIED: out/hello.txt == hi"; else echo "EFFECT MISSING"; fi
echo "--- proxy decisions:"; docker logs "proxy-$RUN" 2>&1 | grep -oE 'CONNECT [^ ]+|refused on filtered domain "[^"]+"' | sort | uniq -c
echo "(workspace kept at $WS)"
