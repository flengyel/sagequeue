#!/usr/bin/env bash
set -euo pipefail
CONTAINER="${SERVICE:-${SAGEPOD_CONTAINER:-sagepod}}"
if [[ "$(podman container inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != true ]]; then
  printf 'SagePod container %s is not running. Start SagePod first.\n' "$CONTAINER" >&2
  exit 1
fi
podman exec "$CONTAINER" /sage/sage --version
