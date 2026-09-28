#!/usr/bin/env bash
# Runs INSIDE the container. Reports what the actor can see. Never prints secret values.
echo "== whoami: $(id)"
echo "== env (names only):"; env | cut -d= -f1 | sort | tr '\n' ' '; echo
for v in SSH_AUTH_SOCK AWS_ACCESS_KEY_ID ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN HOST_CANARY; do
  if [ -n "${!v:-}" ]; then echo "LEAK: $v is set"; else echo "ok: $v unset"; fi
done
for p in /Users "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg" "$HOME/.claude" "$HOME/.claude.json" \
         /run/host-services/ssh-auth.sock /var/run/docker.sock /root; do
  if [ -e "$p" ]; then echo "PRESENT: $p ($(ls -ld "$p" 2>&1 | cut -c1-60))"; else echo "absent: $p"; fi
done
echo "== mounts (non-proc/sys/dev):"; grep -vE ' (proc|sysfs|cgroup2?|devpts|mqueue|devtmpfs) ' /proc/self/mounts | awk '{print $2, $3, $4}' | cut -c1-90
echo "== CapEff: $(grep CapEff /proc/self/status | awk '{print $2}')  NoNewPrivs: $(grep NoNewPrivs /proc/self/status | awk '{print $2}')"
echo "== write to / : $(touch /evil 2>&1 && echo WRITABLE || echo blocked)"
echo "== write to /workspace : $(touch /workspace/ok && echo ok && rm /workspace/ok)"
