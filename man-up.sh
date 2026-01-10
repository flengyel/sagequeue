#!/usr/bin/env bash
set -euo pipefail

# Bring the SageMath container *up* (man-up, man pages…).
# Default behavior: start detached, print a Windows-friendly URL, then follow logs.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILE="${SCRIPT_DIR}/podman-compose.yml"

CONTAINER_NAME="${CONTAINER_NAME:-sagemath}"
PORT="${PORT:-8888}"

usage() {
  cat <<'USAGE'
Usage: ./man-up.sh [--follow] [--open]

  --no-follow   Start the stack but do not follow logs (returns immediately).
  --open        Try to open http://localhost:8888 in the default Windows browser.

Environment:
  CONTAINER_NAME   default: sagemath
  PORT             default: 8888
USAGE
}

FOLLOW=0
OPEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --follow|-f) FOLLOW=1 ;;
    --open|-o)      OPEN=1 ;;
    --help|-h)      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 127
  }
}

require_cmd podman

# Prefer the repo-local venv podman-compose if it exists (so you don't have to 'source bin/activate').
if [[ -x "${SCRIPT_DIR}/.venv/bin/podman-compose" ]]; then
  PODMAN_COMPOSE="${SCRIPT_DIR}/.venv/bin/podman-compose"
else
  require_cmd podman-compose
  PODMAN_COMPOSE="podman-compose"
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

# Sanity check: rootless podman must be able to create /run/user/$UID/... on WSL2.
if ! podman ps >/dev/null 2>&1; then
  echo "podman is not usable as this user." >&2
  echo "If you're on WSL2 and see /run/user/<uid> permission errors," >&2
  echo "enable systemd in /etc/wsl.conf ([boot] systemd=true) and restart WSL." >&2
  podman ps || true
  exit 1
fi

# Create bind-mount directories expected by podman-compose.yml (safe if they already exist).
mkdir -p "$HOME/Jupyter" "$HOME/.jupyter"

# Start / update the stack.
"$PODMAN_COMPOSE" -f "${COMPOSE_FILE}" up -d

echo

# Best-effort token extraction (wait up to ~30s for Jupyter to print it)
TOKEN=""
for _ in {1..30}; do
  TOKEN="$(podman logs --tail 2000 "${CONTAINER_NAME}" 2>&1 \
            | grep -Eo 'token=[0-9a-f]+' \
            | tail -n 1 || true)"
  [[ -n "${TOKEN}" ]] && break
  sleep 1
done

if [[ -n "${TOKEN}" ]]; then
  echo "Token (if needed): ${TOKEN}"
  echo "URL (with token): http://localhost:${PORT}/tree?${TOKEN}"
else
  echo "Token (if needed): podman logs --tail 2000 ${CONTAINER_NAME} 2>&1 | grep -Eo 'token=[0-9a-f]+' | tail -n 1"
fi


if [[ "${OPEN}" == "1" ]]; then
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Start-Process 'http://localhost:${PORT}'" >/dev/null 2>&1 || true
  fi
fi


if [[ "${FOLLOW}" == "1" ]]; then
  exec podman logs -f "${CONTAINER_NAME}"
fi
