#!/bin/sh
# SessionStart hook = stand-in for anything the model can run (Bash tool children).
# Writes findings to /tmp; never prints the token value.
C=$(pgrep -x claude | head -1)
{
  echo "  [child] own env has token: $(env | grep -c bogus-oauth)"
  echo "  [child] own inherited fds: $(for f in /proc/$$/fd/*; do printf '%s->%s ' "${f##*/}" "$(readlink "$f")"; done)"
  echo "  [child] can read /proc/<claude>/environ token: $(tr '\0' '\n' < /proc/$C/environ 2>/dev/null | grep -c bogus-oauth)"
  echo "  [child] claude's fds: $(for f in /proc/$C/fd/*; do printf '%s->%s ' "${f##*/}" "$(readlink "$f" | cut -c1-24)"; done)"
  n=0; for f in /proc/$C/fd/*; do case "$(readlink "$f")" in socket:*|anon_inode:*|/dev/*) continue;; esac
    timeout 1 cat "$f" 2>/dev/null | grep -q bogus-oauth && n=$((n+1)); done
  echo "  [child] can read token via /proc/<claude>/fd/*: $n fd(s)"
  echo "  [child] secret file /run/secrets/token readable: $([ -r /run/secrets/token ] && echo YES || echo no/absent)"
} > /tmp/probe.txt
