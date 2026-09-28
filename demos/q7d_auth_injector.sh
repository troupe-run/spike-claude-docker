#!/usr/bin/env bash
# Q7 option D: the credential never enters the actor container. Actor has a DUMMY token and
# ANTHROPIC_BASE_URL pointing at an injector sidecar that swaps in the real (here: bogus) token.
set -uo pipefail
cd "$(dirname "$0")/.."
REAL="bogus-oauth-token-for-spike-$$"
EXPECT=$(printf 'Bearer %s' "$REAL" | shasum -a 256 | cut -c1-12)
DUMMY=$(printf 'Bearer %s' "dummy" | shasum -a 256 | cut -c1-12)
ACT=troupe-q7d-act-$$; UP=troupe-q7d-up-$$; LOG=$(mktemp -d); SEC=$(mktemp -d)
trap 'docker rm -f fakeapi-$$ inj-$$ >/dev/null 2>&1; docker network rm $ACT $UP >/dev/null 2>&1; rm -rf "$LOG" "$SEC"' EXIT
chmod 777 "$LOG"; printf '%s' "$REAL" > "$SEC/token"; chmod 644 "$SEC/token"
docker network create --internal $ACT >/dev/null; docker network create --internal $UP >/dev/null
docker run -d --name fakeapi-$$ --network $UP --network-alias fakeapi -v "$LOG":/log -v "$PWD/demos/fake_api.py":/fake_api.py:ro python:3.12-alpine python /fake_api.py >/dev/null
docker run -d --name inj-$$ --network $UP -e UPSTREAM=http://fakeapi:8080 -e TOKEN_FILE=/secret/token \
  -v "$SEC/token":/secret/token:ro -v "$PWD/demos/auth_injector.py":/inj.py:ro python:3.12-alpine python /inj.py >/dev/null
docker network connect --alias authproxy $ACT inj-$$
sleep 2
docker run --rm --init --network $ACT --read-only --tmpfs /tmp --tmpfs /home/actor:uid=1000,gid=1000 --user 1000:1000 \
  --cap-drop ALL --security-opt no-new-privileges -e CLAUDE_CODE_MAX_RETRIES=0 \
  -e ANTHROPIC_BASE_URL=http://authproxy:8080 -e CLAUDE_CODE_OAUTH_TOKEN=dummy \
  troupe-claude:spike bash -c "claude -p 'say hi' --setting-sources '' --strict-mcp-config --output-format json </dev/null 2>/dev/null | grep -o '\"result\":\"[^\"]*\"'; echo \"actor can see real token anywhere in its fs/env: \$(grep -rl bogus-oauth / --exclude-dir=proc --exclude-dir=sys 2>/dev/null | wc -l) files, env=\$(env | grep -c bogus-oauth)\""
echo "fake API saw injected REAL token: $(cat "$LOG"/*.json | grep -c "$EXPECT") request(s); saw actor's dummy: $(cat "$LOG"/*.json | grep -c "$DUMMY")"
echo "paths: $(cat "$LOG"/*.json | grep -oE '"path": "[^"?]+' | sort -u | tr '\n' ' ')"
