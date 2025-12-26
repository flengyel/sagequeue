#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SAGE_TAG="${SAGE_TAG:-10.7}"
IMAGE="localhost/sagequeue-sagemath:${SAGE_TAG}-pycryptosat"
SERVICE="${SERVICE:-sagemath}"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/podman-compose.yml}"

# Host directory that bind-mounts to /home/sage/.sage (DOT_SAGE) in podman-compose.yml.
# If /home/sage/.sage is bind-mounted, it *masks* any packages installed there at image-build time
# (including pycryptosat). We therefore seed pycryptosat into the host DOT_SAGE directory.
DOT_SAGE_HOST="${DOT_SAGE_HOST:-${HOME}/.sagequeue-dot_sage}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 127
  }
}

require_cmd podman

# Prefer repo-local venv podman-compose if present (no need to 'source .venv/bin/activate').
if [[ -x "${REPO_ROOT}/.venv/bin/podman-compose" ]]; then
  PODMAN_COMPOSE="${REPO_ROOT}/.venv/bin/podman-compose"
else
  require_cmd podman-compose
  PODMAN_COMPOSE="podman-compose"
fi

cd "$REPO_ROOT"

echo "[build] $IMAGE"
podman build -f Containerfile --build-arg "SAGE_TAG=${SAGE_TAG}" -t "$IMAGE" .

# If the compose file bind-mounts /home/sage/.sage, seed pycryptosat into the host DOT_SAGE dir.
if grep -q "/home/sage/\.sage" "$COMPOSE_FILE"; then
  echo "[seed] host DOT_SAGE=${DOT_SAGE_HOST}"
  mkdir -p "$DOT_SAGE_HOST"

  podman run --rm --user 1000:1000     -e HOME=/home/sage -e DOT_SAGE=/home/sage/.sage     -v "${DOT_SAGE_HOST}:/seed:Z,U"     "$IMAGE"     bash -lc '
      set -euo pipefail
      # NOTE: /home/sage/.sage is often bind-mounted from the host in podman-compose.yml.
      # We avoid Python quoting pitfalls here and discover the pythonX.Y site-packages path via globbing.
      SRC=""
      for d in /home/sage/.sage/local/lib/python*/site-packages; do
        if [[ -d "$d" ]]; then SRC="$d"; break; fi
      done
      [[ -n "$SRC" ]] || { echo "[seed] could not find site-packages under /home/sage/.sage/local/lib" >&2; exit 1; }
      PYDIR="$(basename "$(dirname "$SRC")")"   # e.g. python3.12
      DST="/seed/local/lib/${PYDIR}/site-packages"
      mkdir -p "$DST"
      rm -f "$DST"/pycryptosat* 2>/dev/null || true
      cp -a "$SRC"/pycryptosat* "$DST"/
      echo "[ok] seeded pycryptosat into host DOT_SAGE at $DST"
    '
else
  echo "[seed] no /home/sage/.sage bind mount detected in ${COMPOSE_FILE}; skipping seed"
fi

echo "[recreate] container ${SERVICE}"
podman rm -f "${SERVICE}" 2>/dev/null || true

echo "[up] ${SERVICE}"
"$PODMAN_COMPOSE" -f "$COMPOSE_FILE" up -d "$SERVICE"

echo "[verify] pycryptosat import in running container"
podman exec "${SERVICE}" bash -lc 'cd /sage && ./sage -python -c "import pycryptosat; print(pycryptosat.__version__)"' >/dev/null

echo "[ok] running image:"
podman inspect "${SERVICE}" --format '{{.ImageName}}'
