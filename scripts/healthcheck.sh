#!/usr/bin/env bash
# Container health: alive and making progress, and not failing every pass for a long time.
# A single failing target (in backoff) is NOT unhealthy.
set -uo pipefail

STATE="${STATE_DIR:-/state}"
INTERVAL="${RECONCILE_INTERVAL:-60}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-900}"
MAX_AGE="${HEALTH_MAX_AGE:-$((3 * INTERVAL + SCAN_TIMEOUT))}"
FAIL_PASSES="${HEALTH_FAIL_PASSES:-10}"

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

hb="$(mtime "$STATE/heartbeat")" || { echo "unhealthy: no heartbeat"; exit 1; }
age=$(( $(date +%s) - hb ))
if (( age > MAX_AGE )); then
  echo "unhealthy: heartbeat ${age}s old (max ${MAX_AGE}s)"; exit 1
fi

if [[ -f $STATE/status.json ]]; then
  n="$(jq -r '.consecutive_failed_passes // 0' "$STATE/status.json" 2>/dev/null)" || n=0
  if [[ $n =~ ^[0-9]+$ ]] && (( n >= FAIL_PASSES )); then
    echo "unhealthy: $n consecutive failed passes (max $((FAIL_PASSES - 1)))"; exit 1
  fi
fi
echo "healthy"
