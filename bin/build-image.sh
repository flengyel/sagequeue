#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SAGE_TAG="${SAGE_TAG:-10.7}"
IMAGE="localhost/sagequeue-sagemath:${SAGE_TAG}-pycryptosat"
SERVICE="${SERVICE:-sagemath}"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/podman-compose.yml}"

cd "$REPO_ROOT"

echo "[build] $IMAGE"
podman build -f Containerfile --build-arg "SAGE_TAG=${SAGE_TAG}" -t "$IMAGE" .

echo "[recreate] container ${SERVICE}"
podman rm -f "${SERVICE}" 2>/dev/null || true

echo "[up] ${SERVICE}"
podman-compose -f "$COMPOSE_FILE" up -d "$SERVICE"

echo "[ok] running image:"
podman inspect "${SERVICE}" --format '{{.ImageName}}'

