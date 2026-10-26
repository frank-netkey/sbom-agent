#!/usr/bin/env bash
# Local tests for healthcheck.sh and the heartbeat/status behaviour of reconcile.sh (stubbed docker/syft/curl).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { # name expected_rc actual_rc
  if [[ $2 == "$3" ]]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1 (want $2, got $3)"; fi
}
hc() { STATE_DIR="$S" "$ROOT/scripts/healthcheck.sh" >/dev/null; echo $?; }
fresh() { S="$T/state.$RANDOM"; mkdir -p "$S"; touch "$S/heartbeat"; }

fresh; check "fresh heartbeat" 0 "$(hc)"
fresh; touch -t 202001010000 "$S/heartbeat"; check "stale heartbeat" 1 "$(hc)"
fresh; check "missing heartbeat" 1 "$(rm "$S/heartbeat"; hc)"
fresh; echo '{"consecutive_failed_passes":10}' > "$S/status.json"; check "10 failed passes" 1 "$(hc)"
fresh; echo '{"consecutive_failed_passes":9}' > "$S/status.json"; check "9 failed passes" 0 "$(hc)"
fresh; echo '{"targets":5,"ok":4,"failed":1,"backoff":0,"consecutive_failed_passes":0}' > "$S/status.json"; check "one failing target" 0 "$(hc)"

# Stubs for reconcile.sh
B="$T/bin"; mkdir -p "$B"
cat > "$B/docker" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "container ls") echo aaa; echo bbb;;
  "container inspect") cat "$STUB_TARGETS";;
esac
S
cat > "$B/curl" <<'S'
#!/usr/bin/env bash
[[ -n ${STUB_DT_DOWN:-} ]] && exit 7
for a in "$@"; do [[ $a == -w ]] && { echo 200; }; done
exit 0
S
cat > "$B/syft" <<'S'
#!/usr/bin/env bash
[[ -n ${STUB_SYFT_SLEEP:-} ]] && sleep "$STUB_SYFT_SLEEP"
for a in "$@"; do [[ $a == cyclonedx-json=* ]] && out="${a#cyclonedx-json=}"; done
echo '{"bomFormat":"CycloneDX","components":[{"name":"x"}]}' > "$out"
S
printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$B/timeout"   # macOS has no timeout(1)
chmod +x "$B"/*
rec() { # runs reconcile with a fixed identity set; extra env via caller
  STATE_DIR="$S" HOST_ID=h DTRACK_URL=http://dt HDR_FILE="$S/hdr" PATH="$B:$PATH" \
    STUB_TARGETS="$T/targets.json" "$ROOT/scripts/reconcile.sh" >/dev/null 2>&1
}
cat > "$T/targets.json" <<'S'
[{"Id":"sha256:1111111111111111111111111111111111111111111111111111111111111111","Name":"/a","Config":{"Image":"a:1","Labels":{}},"Image":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}]
S
if (cd "$ROOT" && STATE_DIR="$T/probe" HOST_ID=h DTRACK_URL=http://dt PATH="$B:$PATH" STUB_TARGETS="$T/targets.json" scripts/reconcile.sh --list 2>/dev/null | grep -q .); then
  # DT down -> streak increments, status written
  fresh; STUB_DT_DOWN=1 rec; STUB_DT_DOWN=1 rec
  check "DT down streak=2" 2 "$(jq .consecutive_failed_passes "$S/status.json")"
  check "DT down flagged" false "$(jq .dt_reachable "$S/status.json")"
  # DT up, target ok -> streak resets
  rec; check "recovery resets streak" 0 "$(jq .consecutive_failed_passes "$S/status.json")"
  # Long pass keeps heartbeat fresh: heartbeat touched at target start/end
  fresh; rm -rf "$S/markers"; touch -t 202001010000 "$S/heartbeat"
  STUB_SYFT_SLEEP=1 rec
  age=$(( $(date +%s) - $(stat -f %m "$S/heartbeat" 2>/dev/null || stat -c %Y "$S/heartbeat") ))
  check "heartbeat touched during pass" 1 "$(( age < 30 ? 1 : 0 ))"
else
  echo "SKIP reconcile tests: stub identity discovery produced nothing"
fi
echo "passed=$pass failed=$fail"; exit $((fail > 0))
