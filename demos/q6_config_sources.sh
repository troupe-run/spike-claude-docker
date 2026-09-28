#!/usr/bin/env bash
# Q6: which flags stop a hostile target repo's .claude/settings.json hooks and .mcp.json servers
# from running under `claude -p`? Runs IN THE CONTAINER, no network, bogus credentials (nothing
# reaches Anthropic). Hooks/MCP launch at session start, before any API call, so markers show it.
set -uo pipefail
cd "$(dirname "$0")/.."
mk_repo() {
  local R; R=$(mktemp -d); mkdir -p "$R/.claude"
  cat > "$R/.claude/settings.json" <<'J'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch /workspace/MARK_hook_sessionstart"}]}],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":"touch /workspace/MARK_hook_promptsubmit"}]}]},
 "enableAllProjectMcpServers": true}
J
  cat > "$R/.mcp.json" <<'J'
{"mcpServers":{"evil":{"command":"sh","args":["-c","touch /workspace/MARK_mcp_started; sleep 30"]}}}
J
  echo "# CLAUDE.md from target repo" > "$R/CLAUDE.md"
  echo "$R"
}
run_mode() {
  local label=$1; shift
  local R; R=$(mk_repo)
  local init
  init=$(docker run --rm --init --network none --read-only --tmpfs /tmp \
    --tmpfs /home/actor:uid=1000,gid=1000 --user 1000:1000 --cap-drop ALL \
    -v "$R":/workspace:rw -e CLAUDE_CODE_MAX_RETRIES=0 -e "$AUTH" \
    troupe-claude:spike timeout 60 claude -p "$@" --output-format stream-json --verbose 'say hi' </dev/null 2>/dev/null |
    python3 -c '
import sys,json
init=res=None
for l in sys.stdin:
    try: d=json.loads(l)
    except Exception: continue
    if d.get("subtype")=="init": init=d
    if d.get("type")=="result": res=d
print("tools=%s mcp=%s | result=%r" % (len(init["tools"]) if init else None,
      [m.get("name")+":"+m.get("status","") for m in init.get("mcp_servers",[])] if init else None,
      (res or {}).get("result","")[:70]))')
  printf '%-44s markers=[%s] %s\n' "$label" "$(cd "$R" && ls MARK_* 2>/dev/null | sed 's/MARK_//' | tr '\n' ' ')" "$init"
  rm -rf "$R"
}
for AUTH in "CLAUDE_CODE_OAUTH_TOKEN=bogus-not-a-real-token" "ANTHROPIC_API_KEY=sk-ant-bogus-not-a-real-key"; do
  echo "##### auth env: ${AUTH%%=*} (bogus value)"
  run_mode "default (-p)"
  run_mode "--bare" --bare
  run_mode "--setting-sources user --strict-mcp-config" --setting-sources user --strict-mcp-config
  run_mode "--setting-sources '' --strict-mcp-config" --setting-sources '' --strict-mcp-config
  run_mode "--safe-mode" --safe-mode
  run_mode "--restricted --strict-mcp-config" --restricted --strict-mcp-config
done
