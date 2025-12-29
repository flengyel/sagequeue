#!/usr/bin/env bash
set -euo pipefail

: "${SERVICE:?}"
: "${COMPOSE_FILE:?}"
: "${PODMAN_COMPOSE:?}"
: "${CONTAINER_WORKDIR:?}"
: "${SAGE_BIN:?}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }; }
require_cmd podman

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Compose file not found: $COMPOSE_FILE" >&2
  exit 2
fi

if [[ ! -x "$PODMAN_COMPOSE" ]]; then
  echo "podman-compose not executable: $PODMAN_COMPOSE" >&2
  echo "run: $(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/setup.sh" >&2
  exit 2
fi

"$PODMAN_COMPOSE" -f "$COMPOSE_FILE" up -d "$SERVICE"

# Preflight: Sage exists inside the container
podman exec "$SERVICE" bash -c "set -euo pipefail; cd '$CONTAINER_WORKDIR' && $SAGE_BIN --version >/dev/null"

