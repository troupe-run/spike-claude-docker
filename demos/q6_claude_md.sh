#!/usr/bin/env bash
# Q6b: does the target repo's CLAUDE.md reach the model, per mode? Uses a fake API endpoint
# (ANTHROPIC_BASE_URL) on an internal network that records request bodies. No real credential.
set -uo pipefail
cd "$(dirname "$0")/.."
NET=troupe-fakeapi-$$; LOG=$(mktemp -d); R=$(mktemp -d)
trap 'docker rm -f fakeapi-$$ >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; rm -rf "$LOG" "$R"' EXIT
chmod 777 "$LOG"; echo "# Repo instructions: MARKER_REPO_CLAUDE_MD" > "$R/CLAUDE.md"
docker network create --internal $NET >/dev/null
docker run -d --name fakeapi-$$ --network $NET --network-alias fakeapi -v "$LOG":/log -v "$PWD/demos/fake_api.py":/fake_api.py:ro python:3.12-alpine python /fake_api.py >/dev/null
sleep 2
for mode in "" "--bare" "--safe-mode" "--setting-sources user --strict-mcp-config" "--bare --add-dir /workspace"; do
  rm -f "$LOG"/*.json
  docker run --rm --network $NET --tmpfs /tmp --tmpfs /home/actor:uid=1000,gid=1000 --user 1000:1000 \
    -v "$R":/workspace -e CLAUDE_CODE_MAX_RETRIES=0 -e ANTHROPIC_API_KEY=sk-ant-bogus -e ANTHROPIC_BASE_URL=http://fakeapi:8080 \
    troupe-claude:spike bash -c "timeout 60 claude -p 'say hi' $mode </dev/null >/dev/null 2>&1"
  msgs=$(grep -l '/v1/messages' "$LOG"/*.json 2>/dev/null | wc -l | tr -d ' ')
  hit=$(cat "$LOG"/*.json 2>/dev/null | grep -c MARKER_REPO_CLAUDE_MD)
  paths=$(cat "$LOG"/*.json 2>/dev/null | python3 -c 'import sys,json,re; print(sorted({re.sub(r"\?.*","",m) for m in re.findall(r"\"path\": \"([^\"]+)\"", sys.stdin.read())}))')
  printf '%-44s requests-with-CLAUDE.md=%s  endpoints=%s\n' "[${mode:-default}]" "$hit" "$paths"
done
