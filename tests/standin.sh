#!/usr/bin/env bash
# Stand-in for `claude -p --output-format stream-json`: emits JSON lines, one of them >64 KiB,
# spawns a process tree (like Bash tool subprocesses), then runs "forever".
# MODE=graceful: trap SIGTERM, emit a final line, exit 143.  MODE=ignore: ignore SIGTERM.
MODE=${MODE:-graceful}
if [ "$MODE" = ignore ]; then trap '' TERM; else
  trap 'echo "{\"type\":\"system\",\"subtype\":\"sigterm_received\"}"; kill $(jobs -p) 2>/dev/null; exit 143' TERM
fi
echo '{"type":"system","subtype":"init","session_id":"standin"}'
big=$(head -c 200000 /dev/zero | tr '\0' 'x')
echo "{\"type\":\"user\",\"big\":\"$big\"}"
( sleep 1000 & bash -c 'sleep 1001' & wait ) &
for i in $(seq 1 100000); do
  echo "{\"type\":\"assistant\",\"tick\":$i}"
  sleep 0.2 & wait $!
done
