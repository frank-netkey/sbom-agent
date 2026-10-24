#!/usr/bin/env bash
# One reconciliation pass: running containers -> SBOM (Syft) -> Dependency-Track.
#   reconcile.sh          run a pass
#   reconcile.sh --list   print discovered identities and exit (no scan/upload)
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
init_state

WORK="$(mktemp -d "$STATE/tmp/cycle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

discover() {
  local -a ids=()
  local id
  while IFS= read -r id; do ids+=("$id"); done < <(docker container ls --quiet --no-trunc)
  ((${#ids[@]})) || return 0
  docker container inspect "${ids[@]}" | jq -c -f "$HERE/identities.jq"
}

if [[ ${1:-} == --list ]]; then
  discover | jq -r '[.identity, .image_id, .image_ref, .name] | @tsv'
  exit 0
fi

dt_up() {
  curl -fsS --connect-timeout 5 --max-time 15 "$DTRACK_URL/api/version" >/dev/null
}

failure_blocked() { # key -> 0 if still in backoff window
  local f="$STATE/failures/$1" count next
  [[ -f $f ]] || return 1
  read -r count next < "$f" || return 1
  (( $(date +%s) < next ))
}

record_failure() { # key identity reason
  local f="$STATE/failures/$1" count=0 next delay
  [[ -f $f ]] && read -r count _ < "$f" || true
  count=$((count + 1))
  delay=$(( 60 * (1 << (count > 6 ? 6 : count - 1)) ))
  (( delay > BACKOFF_MAX )) && delay=$BACKOFF_MAX
  next=$(( $(date +%s) + delay ))
  printf '%s %s\n' "$count" "$next" > "$f"
  log WARN "$2: $3 (failure #$count, retry in ${delay}s)"
}

scan_image() { # image_id identity out
  # Called inside `||`, where errexit is off: every step must return explicitly.
  local image_id="$1" identity="$2" out="$3"
  local raw="$WORK/raw.json" filtered="$WORK/filtered.json"
  timeout "$SCAN_TIMEOUT" syft scan "docker:$image_id" \
      --source-name "$identity" --source-version "$image_id" \
      -o "cyclonedx-json=$raw" -q || return 1
  jq -f "$HERE/filter-sbom.jq" "$raw" > "$filtered" || return 1
  jq -e '.bomFormat == "CycloneDX"' "$filtered" >/dev/null || { echo "not a CycloneDX document"; return 1; }
  local n; n="$(jq '.components // [] | length' "$filtered")" || return 1
  (( n > 0 )) || log WARN "$identity: SBOM has 0 components" >&2
  mv "$filtered" "$out"
}

upload_sbom() { # sbom project version project_uuid tags
  local sbom="$1" project="$2" version="$3" uuid="$4" tags="$5"
  local resp="$WORK/resp.txt" code
  local -a args=(-F "bom=@$sbom;type=application/json")
  if [[ -n $uuid ]]; then
    args+=(-F "project=$uuid")
  else
    args+=(-F "projectName=$project" -F "projectVersion=$version"
           -F "autoCreate=true" -F "isLatest=true")
    [[ -n $tags ]] && args+=(-F "projectTags=$tags")
  fi
  code="$(curl -sS -o "$resp" -w '%{http_code}' \
      --connect-timeout 10 --max-time "$UPLOAD_TIMEOUT" \
      --retry 4 --retry-delay 3 --retry-connrefused \
      -H "@$HDR_FILE" "${args[@]}" "$DTRACK_URL/api/v1/bom")" || { echo "curl failed"; return 1; }
  [[ $code == 200 ]] && return 0
  echo "HTTP $code: $(head -c 300 "$resp" | tr '\n' ' ')"
  return 1
}

process_target() { # target-json
  local t="$1" identity image_id uuid tags_label
  IFS=$'\x1f' read -r identity image_id uuid tags_label \
    < <(jq -r '[.identity, .image_id, .project_uuid, .tags] | join("\u001f")' <<<"$t")

  local project="${HOST_ID}/${identity}"
  local version="${image_id#sha256:}"; version="${version:0:12}"
  local tags="$DEFAULT_TAGS"; [[ -n $tags_label ]] && tags="$tags,$tags_label"
  local key; key="$(key_of "$project")"
  local fp; fp="$(printf '%s\n' "$project" "$version" "$uuid" "$tags" | sha256sum | cut -d' ' -f1)"
  local marker="$STATE/markers/$key.json"
  local sbom="$STATE/sboms/${image_id#sha256:}.cdx.json"

  if [[ -f $marker ]] && jq -e --arg id "$image_id" --arg fp "$fp" \
        '.image_id == $id and .fingerprint == $fp' "$marker" >/dev/null 2>&1; then
    return 0   # already uploaded for this exact image + config
  fi
  if failure_blocked "$key"; then
    log DEBUG "$identity: in backoff, skipping"
    return 2
  fi

  if [[ ! -s $sbom ]]; then
    log INFO "scanning $identity ($image_id)"
    scan_image "$image_id" "$project" "$sbom" 2> "$WORK/err.txt" || {
      record_failure "$key" "$identity" "scan failed: $(tail -n 3 "$WORK/err.txt" | tr '\n' ' ')"
      return 1
    }
  fi

  local err
  if ! err="$(upload_sbom "$sbom" "$project" "$version" "$uuid" "$tags")"; then
    record_failure "$key" "$identity" "upload failed: $err"
    return 1
  fi

  jq -n --arg p "$project" --arg v "$version" --arg id "$image_id" --arg fp "$fp" \
        --arg u "$uuid" --arg ts "$(date -u +%FT%TZ)" \
        '{project:$p, version:$v, image_id:$id, fingerprint:$fp, project_uuid:$u, uploaded_at:$ts}' \
        > "$marker.tmp" && mv "$marker.tmp" "$marker" || return 1
  rm -f "$STATE/failures/$key"
  log INFO "uploaded $project @ $version"
}

gc_sboms() { # remove SBOMs no marker references anymore
  local keep="$WORK/keep.txt"
  { shopt -s nullglob; for m in "$STATE"/markers/*.json; do jq -r '.image_id | ltrimstr("sha256:")' "$m"; done; } > "$keep"
  find "$STATE/sboms" -name '*.cdx.json' -mtime "+$((SBOM_KEEP_DAYS - 1))" -print0 |
    while IFS= read -r -d '' f; do
      grep -qxF "$(basename "$f" .cdx.json)" "$keep" || { rm -f "$f"; log INFO "gc: removed $(basename "$f")"; }
    done
}

main() {
  if ! dt_up; then
    log WARN "Dependency-Track not reachable at $DTRACK_URL; skipping pass"
    return 0
  fi
  discover > "$WORK/targets.jsonl"
  local total=0 ok=0 failed=0 blocked=0 rc
  while IFS= read -r t; do
    total=$((total + 1))
    rc=0; process_target "$t" || rc=$?
    case $rc in 0) ok=$((ok + 1));; 2) blocked=$((blocked + 1));; *) failed=$((failed + 1));; esac
  done < "$WORK/targets.jsonl"
  gc_sboms
  log INFO "pass done: targets=$total ok=$ok failed=$failed backoff=$blocked"
}

main
