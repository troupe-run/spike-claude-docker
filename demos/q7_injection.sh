#!/usr/bin/env bash
# Q7: credential-injection mechanics, using ONLY a bogus token. Compares:
#   A) env var  -e CLAUDE_CODE_OAUTH_TOKEN
#   B) secret file bind-mount + CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR (fd opened by a wrapper)
# For each: does claude send it (fake API sees a Bearer whose hash matches), is it visible in
# `docker inspect`, in a child process's env (hook = stand-in for the Bash tool), in
# /proc/<claude>/environ, via an inherited fd, or in the secret file (readable by the actor?).
set -uo pipefail
cd "$(dirname "$0")/.."
BOGUS="bogus-oauth-token-for-spike-$$"
EXPECT=$(printf 'Bearer %s' "$BOGUS" | shasum -a 256 | cut -c1-12)
NET=troupe-q7-$$; LOG=$(mktemp -d); SEC=$(mktemp -d)
trap 'docker rm -f fakeapi-$$ q7a-$$ q7b-$$ >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; rm -rf "$LOG" "$SEC"' EXIT
chmod 777 "$LOG"; printf '%s' "$BOGUS" > "$SEC/token"; chmod 600 "$SEC/token"
docker network create --internal $NET >/dev/null
docker run -d --name fakeapi-$$ --network $NET --network-alias fakeapi -v "$LOG":/log -v "$PWD/demos/fake_api.py":/fake_api.py:ro python:3.12-alpine python /fake_api.py >/dev/null
sleep 2
HOOKS='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/probe_hook.sh"}]}]}}'
COMMON=(--network $NET --init --read-only --tmpfs /tmp --tmpfs /home/actor:uid=1000,gid=1000 --user 1000:1000
        --cap-drop ALL --security-opt no-new-privileges -e CLAUDE_CODE_MAX_RETRIES=0 -e ANTHROPIC_BASE_URL=http://fakeapi:8080
        -v "$PWD/demos/q7_hook_probe.sh":/probe_hook.sh:ro)
CLAUDE="claude -p 'say hi' --settings '$HOOKS' --setting-sources '' --strict-mcp-config </dev/null >/dev/null 2>&1; cat /tmp/probe.txt"
run() { # $1 name, $2 inner command
  rm -f "$LOG"/*.json
  docker run -d --name "$1" "${@:3}" troupe-claude:spike bash -c "$2" >/dev/null
  sleep 1
  echo "  docker inspect Env has token: $(docker inspect "$1" --format '{{json .Config.Env}}' | grep -c bogus-oauth)"
  echo "  docker inspect Mounts: $(docker inspect "$1" --format '{{range .Mounts}}{{.Destination}}:{{.Mode}} {{end}}')"
  docker wait "$1" >/dev/null; docker logs "$1" 2>&1
  echo "  fake API saw Bearer matching bogus token: $(cat "$LOG"/*.json 2>/dev/null | grep -c "$EXPECT") request(s)"
  docker rm -f "$1" >/dev/null
}
echo "### A) env var (-e CLAUDE_CODE_OAUTH_TOKEN; value from supervisor env, not argv)"
export CLAUDE_CODE_OAUTH_TOKEN="$BOGUS"
run q7a-$$ "$CLAUDE" "${COMMON[@]}" -e CLAUDE_CODE_OAUTH_TOKEN
unset CLAUDE_CODE_OAUTH_TOKEN
echo "### B) secret file bind-mounted ro, wrapper opens it as fd 3, exports only the fd number"
run q7b-$$ "exec 3</run/secrets/token; CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3 $CLAUDE" \
  "${COMMON[@]}" --mount "type=bind,src=$SEC/token,dst=/run/secrets/token,readonly"
echo "### C) token piped on stdin of docker run -i; wrapper turns it into fd 3 (never on disk/env)"
rm -f "$LOG"/*.json
docker run -i --rm --name q7c-$$ "${COMMON[@]}" troupe-claude:spike bash -c \
  "IFS= read -r T; exec 3< <(printf %s \"\$T\"); unset T; CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3 $CLAUDE" < "$SEC/token" &
sleep 2; echo "  docker inspect Env has token: $(docker inspect q7c-$$ --format '{{json .Config.Env}}' | grep -c bogus-oauth)"; wait
echo "  fake API saw Bearer matching bogus token: $(cat "$LOG"/*.json 2>/dev/null | grep -c "$EXPECT") request(s)"

