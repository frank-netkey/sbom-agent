#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

init_state
init_auth || exit 1

child=""
trap 'log INFO "shutting down"; [[ -n $child ]] && kill "$child" 2>/dev/null; exit 0' TERM INT

log INFO "sbom-agent starting: host=$HOST_ID dtrack=$DTRACK_URL interval=${INTERVAL}s"

while :; do
  "$HERE/reconcile.sh" & child=$!
  wait "$child" || log ERROR "reconcile pass exited with status $?"
  child=""
  touch "$STATE/heartbeat"
  sleep "$INTERVAL" & child=$!
  wait "$child" || true
  child=""
done
