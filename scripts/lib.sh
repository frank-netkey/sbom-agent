#!/usr/bin/env bash
# Shared config + helpers. Sourced by entrypoint.sh and reconcile.sh.

STATE="${STATE_DIR:-/state}"
HOST_ID="${HOST_ID:?HOST_ID is required (e.g. docker-host-01)}"
DTRACK_URL="${DTRACK_URL:?DTRACK_URL is required}"
DTRACK_URL="${DTRACK_URL%/}"
INTERVAL="${RECONCILE_INTERVAL:-60}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-900}"
UPLOAD_TIMEOUT="${UPLOAD_TIMEOUT:-300}"
DEFAULT_TAGS="${DEFAULT_TAGS:-coolify,${HOST_ID}}"
BACKOFF_MAX="${BACKOFF_MAX:-3600}"
SBOM_KEEP_DAYS="${SBOM_KEEP_DAYS:-1}"
SBOM_AUTHOR="${SBOM_AUTHOR:-sbom-agent (${HOST_ID})}"
QUALITY_MIN_PURL_PCT="${QUALITY_MIN_PURL_PCT:-80}"
PARENT_VERSION="${PARENT_VERSION:-current}"
case "${DTRACK_PARENTS:-true}" in false|FALSE|False|0|no|NO) DTRACK_PARENTS=false;; *) DTRACK_PARENTS=true;; esac
HDR_FILE="${HDR_FILE:-/run/dtrack.hdr}"

log() { # level message...
  local lvl="$1"; shift
  printf '%s %-5s %s\n' "$(date -u +%FT%TZ)" "$lvl" "$*" >&2
}

init_state() {
  umask 077
  mkdir -p "$STATE"/{markers,failures,parents,sboms,tmp,cache,home}
}

# Write the API key into a header file so it never appears in `ps` output.
init_auth() {
  local key="${DTRACK_API_KEY:-}"
  if [[ -z $key && -n ${DTRACK_API_KEY_FILE:-} ]]; then
    key="$(<"$DTRACK_API_KEY_FILE")"
  fi
  [[ -n $key ]] || { log ERROR "DTRACK_API_KEY (or DTRACK_API_KEY_FILE) is required"; return 1; }
  ( umask 077; printf 'X-Api-Key: %s\n' "$key" > "$HDR_FILE" )
  unset DTRACK_API_KEY
}

key_of() { printf '%s' "$1" | sha256sum | cut -c1-16; }

new_uuid() { # random UUID for the parent BOM serialNumber
  local u=""
  if [[ -r /proc/sys/kernel/random/uuid ]]; then u="$(cat /proc/sys/kernel/random/uuid)"
  elif command -v uuidgen >/dev/null 2>&1; then u="$(uuidgen | tr 'A-Z' 'a-z')"
  else u="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12}).*/\1-\2-4\3-a\4-\5/')"
  fi
  printf '%s' "$u"
}
