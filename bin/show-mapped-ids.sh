#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: ${0##*/} [C_UID [C_GID]]

Shows the host-mapped uid/gid for a container uid/gid under rootless Podman.

Defaults:
  C_UID=1000
  C_GID=1000
EOF
}

case "${1:-}" in
  "" ) ;;
  -h|--help) usage; exit 0 ;;
esac

C_UID="${1:-1000}"
C_GID="${2:-1000}"

if ! [[ "$C_UID" =~ ^[0-9]+$ ]]; then
  echo "Invalid C_UID: $C_UID (expected integer)" >&2
  usage >&2
  exit 2
fi
if ! [[ "$C_GID" =~ ^[0-9]+$ ]]; then
  echo "Invalid C_GID: $C_GID (expected integer)" >&2
  usage >&2
  exit 2
fi

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

HUID="$(map_one uid "$C_UID")" || { echo "Could not map container uid $C_UID via podman unshare" >&2; exit 1; }
HGID="$(map_one gid "$C_GID")" || { echo "Could not map container gid $C_GID via podman unshare" >&2; exit 1; }

echo "container ${C_UID}:${C_GID} -> host ${HUID}:${HGID}"

