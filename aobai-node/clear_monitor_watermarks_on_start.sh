#!/usr/bin/env bash
# Clear aobai monitor traffic watermark keys before sbox starts.
# Prevents last_reported_* from surviving a process restart while live
# counters reset, which otherwise stalls SSPanel traffic reporting.
set -euo pipefail
REDIS_CLI="${AOBAI_REDIS_CLI:-/home/ops/aobai-node/bin/redis-cli-embedded}"
REDIS_PORT="${AOBAI_REDIS_PORT:-6382}"
PREFIX="${AOBAI_MONITOR_PREFIX:-sbox:5uf-multi:monitor:}"

if [[ ! -x "$REDIS_CLI" ]]; then
  echo "redis-cli not found: $REDIS_CLI" >&2
  exit 0
fi

# Wait briefly if redis unit is still coming up
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if "$REDIS_CLI" -p "$REDIS_PORT" PING >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

deleted=0
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  "$REDIS_CLI" -p "$REDIS_PORT" DEL "$key" >/dev/null
  deleted=$((deleted + 1))
done < <("$REDIS_CLI" -p "$REDIS_PORT" --scan --pattern "${PREFIX}*")

echo "cleared ${deleted} monitor keys with prefix ${PREFIX}"
