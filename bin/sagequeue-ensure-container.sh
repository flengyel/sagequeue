#!/usr/bin/env bash
set -euo pipefail

: "${SERVICE:?}"
: "${COMPOSE_FILE:?}"
: "${PODMAN_COMPOSE:?}"
: "${CONTAINER_WORKDIR:?}"
: "${SAGE_BIN:?}"


if [[ ! -x "$PODMAN_COMPOSE" ]]; then
  echo "podman-compose not executable: $PODMAN_COMPOSE" >&2
  exit 2
fi

+"$PODMAN_COMPOSE" -f "$COMPOSE_FILE" up -d "$SERVICE"


# Preflight: Sage exists inside the container
podman exec "$SERVICE" bash -lc "cd '$CONTAINER_WORKDIR' && $SAGE_BIN --version >/dev/null"

