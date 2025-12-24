#!/usr/bin/env bash
set -euo pipefail

C_UID="${1:-1000}"
C_GID="${2:-1000}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 127; }; }
require_cmd podman
require_cmd awk

map_one() {
  local which="$1" target="$2"
  podman unshare awk -v target="$target" '
    $1 <= target && target < ($1+$3) { print $2 + (target-$1); found=1; exit }
    END { if (!found) exit 1 }
  ' "/proc/self/${which}_map"
}

HUID="$(map_one uid "$C_UID")"
HGID="$(map_one gid "$C_GID")"

echo "container ${C_UID}:${C_GID} -> host ${HUID}:${HGID}"

