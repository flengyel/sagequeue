#!/usr/bin/env bash
set -euo pipefail

: "${SERVICE:?}"
: "${COMPOSE_FILE:?}"
: "${CONTAINER_WORKDIR:?}"
: "${SAGE_BIN:?}"

running="$(podman inspect -f '{{.State.Running}}' "$SERVICE" 2>/dev/null || true)"
if [[ "$running" != "true" ]]; then
  if command -v podman-compose >/dev/null 2>&1; then
    podman-compose -f "$COMPOSE_FILE" up -d "$SERVICE"
  else
    podman compose -f "$COMPOSE_FILE" up -d "$SERVICE"
  fi
fi

# Preflight: Sage exists inside the container
podman exec "$SERVICE" bash -lc "cd '$CONTAINER_WORKDIR' && $SAGE_BIN --version >/dev/null"

