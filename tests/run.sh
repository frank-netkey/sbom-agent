#!/usr/bin/env bash
# Behaviour tests for reconcile.sh with stubbed docker/syft/curl/timeout (tests/stubs).
#   bash tests/run.sh      (from the repo root; bash 3.2 compatible; non-zero exit on any failure)
# Every test uses its own fresh state dir under one mktemp dir.
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap '[[ -n $TMPROOT && -d $TMPROOT ]] && rm -rf "$TMPROOT"' EXIT
pass=0; fail=0; seq_n=0

ok() { # name rc  (rc 0 = pass)
  if [[ $2 == 0 ]]; then pass=$((pass + 1)); echo "PASS $1"; else fail=$((fail + 1)); echo "FAIL $1"; fi
}
# check <name> <command...>: passes when the command succeeds.
check() { local n="$1"; shift; "$@" >/dev/null 2>&1; ok "$n" $?; }
# check_eq <name> <expected> <actual>
check_eq() {
  if [[ $2 == "$3" ]]; then ok "$1" 0; else ok "$1" 1; echo "     want: $2"; echo "     got:  $3"; fi
}

# ---- per-test environment ---------------------------------------------------------------
# new_env: fresh state dir + stub logs, initialised like the entrypoint does.
new_env() {
  seq_n=$((seq_n + 1))
  D="$TMPROOT/t$seq_n"; mkdir -p "$D"
  export STATE_DIR="$D/state" HDR_FILE="$D/dtrack.hdr" HOST_ID=n8n01 DTRACK_URL=https://dt.test DTRACK_API_KEY=k
  export STUB_INSPECT="$D/inspect.json" STUB_CURL_LOG="$D/curl.log" STUB_SYFT_LOG="$D/syft.log"
  export STUB_SYFT_SBOM="$ROOT/tests/fixtures/syft-sample.json"
  unset STUB_CURL_FAIL_MATCH STUB_SYFT_FAIL DTRACK_PARENTS PARENT_VERSION
  : > "$STUB_CURL_LOG"; : > "$STUB_SYFT_LOG"
  ( source "$ROOT/scripts/lib.sh"; init_state; init_auth ) || echo "init failed"
  PASSN=0
}
# container <id> <image> <labels-json>  -> one inspect object (name derived from id)
container() {
  jq -n --arg id "$1" --arg img "$2" --argjson l "$3" \
    '{Id:$id, Name:("/"+$id+"-1"), Image:("sha256:"+$img), Config:{Image:"app:1", Labels:$l}}'
}
set_containers() { jq -s '.' > "$STUB_INSPECT"; }   # stdin: container objects

# run_pass: one reconcile pass; stderr (the log) goes to $D/pass.N.log, available as $LOG.
run_pass() {
  PASSN=$((PASSN + 1)); LOG="$D/pass.$PASSN.log"
  PATH="$ROOT/tests/stubs:$PATH" bash "$ROOT/scripts/reconcile.sh" "$@" 2> "$LOG" > "$D/pass.$PASSN.out"
}
curl_calls() { wc -l < "$STUB_CURL_LOG" | tr -d ' '; }
# calls matching a fixed string (e.g. "parentName=")
count() { grep -cF -- "$1" "$STUB_CURL_LOG"; }
list() { PATH="$ROOT/tests/stubs:$PATH" bash "$ROOT/scripts/reconcile.sh" --list 2>/dev/null; }

IMG1=aaaaaaaaaaaa1111; IMG2=bbbbbbbbbbbb2222
RES=2qbahiotobqphmtpe0wga4kp
LBL_SVC='{"coolify.resourceName":"leantime-yjzr4v2btmwirvyk6d44fsdn","com.docker.compose.service":"mysql"}'

# ---- 1. identity normalization on the observed names -------------------------------------------
new_env
cp "$ROOT/tests/fixtures/inspect-observed.json" "$STUB_INSPECT"
got="$(list | cut -f1,5 | sort)"
want="$(printf '%s\n' \
  "docker-image-$RES/$RES	docker-image-$RES" \
  "leantime-yjzr4v2btmwirvyk6d44fsdn/mysql	leantime-yjzr4v2btmwirvyk6d44fsdn" \
  "mgiknioijkrcjwlhnbqszldn	" \
  "n8n-with-postgresql-ygqyirwwe2e45zs4qvx48plb/task-runners	n8n-with-postgresql-ygqyirwwe2e45zs4qvx48plb" \
  "service-z8yxmfx57resjzvs2goywu0c/apiserver	service-z8yxmfx57resjzvs2goywu0c" \
  "source/coolify	source" | sort)"
check_eq "identity+group for all observed names (--list)" "$want" "$got"

new_env
container x "$IMG1" '{"sbom.name":"custom-name-20261024T112144"}' | set_containers
check_eq "sbom.name is an exact override (not normalized)" "custom-name-20261024T112144" "$(list | cut -f1)"

# ---- 2. redeploy -> same project, new version; parent created once ------------------------------
new_env
container a "$IMG1" "{\"coolify.resourceName\":\"docker-image-$RES\",\"com.docker.compose.service\":\"$RES-20261024T112144\"}" | set_containers
run_pass
container a "$IMG2" "{\"coolify.resourceName\":\"docker-image-$RES\",\"com.docker.compose.service\":\"$RES-20261101T090000\"}" | set_containers
run_pass
child="projectName=n8n01/docker-image-$RES/$RES "
check_eq "redeploy: two child uploads to the same project name" 2 "$(count "projectName=n8n01/docker-image-$RES/$RES -F")"
check "redeploy: new version (v1)" grep -qF -- "projectVersion=aaaaaaaaaaaa" "$STUB_CURL_LOG"
check "redeploy: new version (v2)" grep -qF -- "projectVersion=bbbbbbbbbbbb" "$STUB_CURL_LOG"
check_eq "parent created once and reused across passes" 1 "$(count "projectName=n8n01/docker-image-$RES -F")"
check_eq "every child upload carries parentName" 2 "$(count "parentName=n8n01/docker-image-$RES")"
check_eq "every child upload carries parentVersion=current" 2 "$(count "parentVersion=current")"
check "parent upload comes before the first child upload" \
  bash -c 'head -n1 "$1" | grep -qF "projectName=n8n01/docker-image-'"$RES"' -F"' _ "$STUB_CURL_LOG"
check "parent state file recorded" test -n "$(ls "$STATE_DIR/parents")"
parent_bom="$STUB_CURL_LOG.1.bom"
check "parent BOM is minimal CycloneDX 1.6" jq -e \
  '.bomFormat=="CycloneDX" and .specVersion=="1.6" and (.serialNumber|startswith("urn:uuid:")) and .version==1
   and .metadata.timestamp and .metadata.component.type=="application"
   and .metadata.component.name=="n8n01/docker-image-'"$RES"'" and .metadata.component["bom-ref"]
   and .components==[]' "$parent_bom"
check "parent upload has autoCreate and tags" grep -qF -- "-F autoCreate=true -F isLatest=true -F projectTags=coolify,n8n01" "$STUB_CURL_LOG"

# ---- 3. nothing changed -> second pass uploads nothing ------------------------------------------
new_env
container a "$IMG1" "$LBL_SVC" | set_containers
run_pass; before="$(curl_calls)"
run_pass
check_eq "second pass without changes makes no uploads" "$before" "$(curl_calls)"
check_eq "second pass without changes does not rescan" 1 "$(wc -l < "$STUB_SYFT_LOG" | tr -d ' ')"
check_eq "first pass: parent + child" 2 "$before"

# ---- 4. DTRACK_PARENTS=false --------------------------------------------------------------------
new_env
export DTRACK_PARENTS=false
container a "$IMG1" "$LBL_SVC" | set_containers
run_pass
check_eq "DTRACK_PARENTS=false: only the child upload" 1 "$(curl_calls)"
check_eq "DTRACK_PARENTS=false: no parentName/parentVersion" 0 "$(count "parent")"
check "DTRACK_PARENTS=false: no parents state" test -z "$(ls "$STATE_DIR/parents")"
unset DTRACK_PARENTS

# ---- 5. parent failure never blocks the child ---------------------------------------------------
new_env
export STUB_CURL_FAIL_MATCH="projectVersion=current"
container a "$IMG1" "$LBL_SVC" | set_containers
run_pass
check_eq "parent failure: child still uploaded" 1 "$(count "projectName=n8n01/leantime-yjzr4v2btmwirvyk6d44fsdn/mysql")"
check_eq "parent failure: child has no parent fields" 0 "$(count "parentName")"
check "parent failure: WARN logged" grep -q 'WARN.*parent project upload failed' "$LOG"
check "parent failure: no failure backoff for the child" test -z "$(ls "$STATE_DIR/failures")"
check "parent failure: no parent state written" test -z "$(ls "$STATE_DIR/parents")"
run_pass; n_after2="$(count "projectName=n8n01/leantime-yjzr4v2btmwirvyk6d44fsdn/mysql")"
check_eq "parent still failing: child is not re-uploaded each pass" 1 "$n_after2"
unset STUB_CURL_FAIL_MATCH
run_pass
check_eq "parent recovered: child re-uploaded once with parent" 1 "$(count "parentName=n8n01/leantime-yjzr4v2btmwirvyk6d44fsdn")"
run_pass
check_eq "after linking: stable again" 1 "$(count "parentName=n8n01/leantime-yjzr4v2btmwirvyk6d44fsdn")"

# ---- 6. sbom.parent override, single-container, existing-project label --------------------------
new_env
container a "$IMG1" '{"sbom.parent":"my-stack","sbom.name":"web"}' | set_containers
check_eq "sbom.parent in --list" "web	my-stack" "$(list | cut -f1,5)"
run_pass
check "sbom.parent override used as parentName" grep -qF -- "parentName=n8n01/my-stack -F parentVersion=current" "$STUB_CURL_LOG"

new_env
container a "$IMG1" '{"coolify.resourceName":"solo"}' | set_containers
check_eq "single-container resource has no group" "solo	" "$(list | cut -f1,5)"
run_pass
check_eq "single-container resource: no parent upload" 1 "$(curl_calls)"

new_env
container a "$IMG1" '{"coolify.resourceName":"stack","com.docker.compose.service":"web","sbom.dtrack.project":"11111111-2222-3333-4444-555555555555"}' | set_containers
run_pass
check_eq "sbom.dtrack.project: single upload, no parent" 1 "$(curl_calls)"
check "sbom.dtrack.project: project field, no parent fields" \
  bash -c 'grep -qF -- "-F project=11111111" "$1" && ! grep -qF parent "$1"' _ "$STUB_CURL_LOG"

# ---- 7. existing behaviours -----------------------------------------------------------------------
new_env
container a "$IMG1" "$LBL_SVC" | set_containers
run_pass
sbom="$STATE_DIR/sboms/$IMG1.cdx.json"
check "CPE filter: component with purl loses cpe" jq -e '.components[] | select(.name=="with-both") | has("cpe") | not' "$sbom"
check "CPE filter: cpe-only component keeps cpe" jq -e '.components[] | select(.name=="cpe-only") | has("cpe")' "$sbom"
marker="$(ls "$STATE_DIR"/markers/*.json | head -n1)"
check "quality summary stored in marker" jq -e '.quality.components == 2 and (.quality.purl_pct == 50)' "$marker"
check "marker has sha256 of the SBOM" jq -e '.sbom_sha256 | length == 64' "$marker"
check "quality WARN below QUALITY_MIN_PURL_PCT" grep -q 'WARN.*only 50% of components have a PURL' "$LOG"

# SHA-256 sidecar mismatch -> rescan (a changed tag list forces a new upload attempt that reuses the cached SBOM)
echo "tampered" >> "$sbom"
container a "$IMG1" "$(jq -c '. + {"sbom.tags":"extra"}' <<<"$LBL_SVC")" | set_containers
run_pass
check "sidecar hash mismatch: WARN and rescan" grep -q 'cached SBOM missing/mismatched hash, rescanning' "$LOG"
check_eq "sidecar hash mismatch: syft ran again" 2 "$(wc -l < "$STUB_SYFT_LOG" | tr -d ' ')"
check "rescanned SBOM is valid again" jq -e '.bomFormat=="CycloneDX"' "$sbom"

# scan failure -> backoff, nothing uploaded
new_env
export STUB_SYFT_FAIL=1
container a "$IMG1" "$LBL_SVC" | set_containers
run_pass
check_eq "scan failure: no child upload" 0 "$(count "projectName=n8n01/leantime-yjzr4v2btmwirvyk6d44fsdn/mysql")"
check "scan failure: backoff recorded" test -n "$(ls "$STATE_DIR/failures")"
unset STUB_SYFT_FAIL

# parent deleted in DT: child upload with parent fields fails -> retried without parent, parent forgotten
new_env
container a "$IMG1" "$LBL_SVC" | set_containers
run_pass                                   # creates parent state
container a "$IMG2" "$LBL_SVC" | set_containers
export STUB_CURL_FAIL_MATCH="parentName="
run_pass
check_eq "parent gone: child retried without parent" 1 "$(grep -F "projectVersion=bbbbbbbbbbbb" "$STUB_CURL_LOG" | grep -cvF parentName)"
check "parent gone: WARN logged" grep -q 'retrying without parent' "$LOG"
check "parent gone: no failure backoff" test -z "$(ls "$STATE_DIR/failures")"
check "parent gone: parent state forgotten" test -z "$(ls "$STATE_DIR/parents")"
unset STUB_CURL_FAIL_MATCH
run_pass
check_eq "parent gone: parent recreated next pass" 2 "$(count "projectName=n8n01/leantime-yjzr4v2btmwirvyk6d44fsdn -F projectVersion=current")"

echo
echo "passed=$pass failed=$fail"
[[ $fail == 0 ]]
