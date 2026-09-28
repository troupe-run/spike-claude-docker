#!/usr/bin/env bash
# Q3: egress allowlist = internal-only network + allowlisting proxy sidecar bridged to the outside.
set -uo pipefail
cd "$(dirname "$0")/.."
RUN=q3$$
INT=troupe-int-$RUN
ALLOW=$(mktemp); trap 'docker rm -f proxy-$RUN >/dev/null 2>&1; docker network rm $INT >/dev/null 2>&1; rm -f $ALLOW' EXIT
printf '%s\n' '^api\.anthropic\.com$' > "$ALLOW"
chmod 644 "$ALLOW"

docker network create --internal "$INT" >/dev/null
docker run -d --name proxy-$RUN --network bridge -v "$ALLOW":/etc/tinyproxy/allow.txt:ro troupe-egress:spike >/dev/null
docker network connect --alias egress "$INT" proxy-$RUN
sleep 1

actor() {  # hardened actor on the internal network only
  docker run --rm --network "$INT" \
    --read-only --tmpfs /tmp --tmpfs /home/actor:uid=1000,gid=1000 \
    --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges \
    -e HTTPS_PROXY=http://egress:3128 -e HTTP_PROXY=http://egress:3128 -e NO_PROXY= \
    troupe-claude:spike bash -c "$1"
}
code() { echo "curl $*: HTTP $(curl -s -o /dev/null -m 8 -w '%{http_code}' "$@" 2>/dev/null) exit=$?"; }
export -f code

echo "--- allowed host via proxy (expect a real HTTP status from api.anthropic.com, e.g. 404/401/405)"
actor "$(declare -f code); code https://api.anthropic.com/"
echo "--- disallowed host via proxy (expect proxy refusal: 403 on CONNECT -> curl exit 56, HTTP 000)"
actor "$(declare -f code); code https://example.com/"
echo "--- bypass attempt: ignore proxy, go direct (expect no route: exit 6/7/28)"
actor "$(declare -f code); code --noproxy '*' https://example.com/; code --noproxy '*' https://1.1.1.1/"
echo "--- bypass attempt: Mac host via host.docker.internal (expect failure)"
actor "$(declare -f code); code --noproxy '*' http://host.docker.internal:80/"
echo "--- DNS from inside internal network (does external name resolution work? = DNS exfil channel)"
actor "getent hosts example.com && echo 'RESOLVED (dns leaks)' || echo 'no external DNS'"
summarise() { python3 -c '
import sys,json
for l in sys.stdin:
    try: d=json.loads(l)
    except Exception: print("non-json:", l.strip()[:120]); continue
    if d.get("type")=="result": print("result:", {k:d.get(k) for k in ("subtype","is_error","result")})
'; }
CLAUDE="CLAUDE_CODE_MAX_RETRIES=0 ANTHROPIC_API_KEY=sk-ant-bogus-not-a-real-key timeout 60 claude -p --bare --output-format stream-json --verbose 'say hi' </dev/null"
echo "--- claude itself through the proxy (bogus API key, --bare; expect 401 from Anthropic = reached API)"
actor "$CLAUDE" | summarise
echo "--- claude with allowlist that does NOT include api.anthropic.com (expect proxy tunnel error)"
printf '%s\n' '^nothing\.invalid$' > "$ALLOW"
docker restart proxy-$RUN >/dev/null; sleep 1
actor "$CLAUDE" | summarise
echo "--- proxy log (CONNECT decisions)"
docker logs proxy-$RUN 2>&1 | grep -iE 'connect|filter|denied|refus' | sed -E 's/^[A-Z]+ +//' | tail -12
