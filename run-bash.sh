#!/usr/bin/env bash
set -euo pipefail
exec podman exec -it "${SAGEPOD_CONTAINER:-sagepod}" bash
