#!/usr/bin/env bash
set -euo pipefail

# Bring the SageMath container *down*.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILE="${SCRIPT_DIR}/podman-compose.yml"

usage() {
  cat <<'USAGE'
Usage: ./man-down.sh

Stops the stack defined by podman-compose.yml in this repository.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

# Prefer the repo-local venv podman-compose if it exists.
if [[ -x "${SCRIPT_DIR}/.venv/bin/podman-compose" ]]; then
  PODMAN_COMPOSE="${SCRIPT_DIR}/.venv/bin/podman-compose"
else
  if ! command -v podman-compose >/dev/null 2>&1; then
    echo "podman-compose not found. If you haven't built the venv, run: ./venvfix.sh" >&2
    echo "If you built it already, you can also: source bin/activate" >&2
    exit 127
  fi
  PODMAN_COMPOSE="podman-compose"
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

"$PODMAN_COMPOSE" -f "${COMPOSE_FILE}" down
