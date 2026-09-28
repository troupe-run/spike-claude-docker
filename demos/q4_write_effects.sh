#!/usr/bin/env bash
# Q4: declared write effects -> mounts. Inputs read-only, declared output read-write, everything
# else read-only (root fs) or ephemeral tmpfs. Also: a nested read-only mount carving a protected
# subpath (.git, .claude) out of a read-write repo mount.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/inputs" "$T/out" "$T/repo/src" "$T/repo/.git/hooks" "$T/repo/.claude"
echo "spec" > "$T/inputs/spec.md"; echo "code" > "$T/repo/src/a.py"
docker run --rm \
  --read-only --tmpfs /tmp --tmpfs /home/actor:uid=1000,gid=1000 \
  --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges --network none \
  -v "$T/inputs":/inputs:ro \
  -v "$T/out":/out:rw \
  -v "$T/repo":/workspace:rw \
  -v "$T/repo/.git":/workspace/.git:ro \
  -v "$T/repo/.claude":/workspace/.claude:ro \
  troupe-claude:spike bash -c '
    try() { if sh -c "$1" 2>/dev/null; then echo "WRITE OK     : $2"; else echo "WRITE DENIED : $2"; fi; }
    echo "read input: $(cat /inputs/spec.md)"
    try "echo x > /out/result.txt"              "/out/result.txt        (declared output)"
    try "echo x > /workspace/src/b.py"          "/workspace/src/b.py    (declared rw repo)"
    try "echo x > /inputs/spec.md"              "/inputs/spec.md        (input, ro)"
    try "rm /inputs/spec.md"                    "rm /inputs/spec.md     (input, ro)"
    try "echo x > /workspace/.git/hooks/pre-commit" "/workspace/.git/hooks/pre-commit (nested ro)"
    try "echo {} > /workspace/.claude/settings.json" "/workspace/.claude/settings.json (nested ro)"
    try "echo x > /etc/passwd"                  "/etc/passwd            (root fs)"
    try "echo x > /usr/local/bin/claude"        "/usr/local/bin/claude  (root fs)"
    try "echo x > /opt/new"                     "/opt/new               (root fs)"
    try "echo x > /tmp/scratch"                 "/tmp/scratch           (ephemeral tmpfs, discarded)"
  '
echo "host view after run:"; (cd "$T" && find . -type f | sort)
