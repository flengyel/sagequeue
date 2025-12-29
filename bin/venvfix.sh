#!/usr/bin/env bash
set -euo pipefail

# Authoritative venv builder. Called once from bin/setup.sh.
# Must NOT depend on PROJECT_ROOT being set externally.
# Deterministic: fixed interpreter python3, fixed venv dir ./.venv. No overrides.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

usage() {
  cat <<EOF
Usage: ${0##*/} [--help]

Creates a fresh repo-local venv at: ${PROJECT_ROOT}/.venv
Interpreter is fixed: python3
EOF
}

case "${1:-}" in
  "" ) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

PYTHON="python3"
VENV_DIR=".venv"  # deterministic; do not allow env override

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }
}
require_cmd "$PYTHON"

REQ="${PROJECT_ROOT}/requirements.txt"
[[ -f "$REQ" ]] || { echo "Missing required file: $REQ" >&2; exit 1; }

echo "Creating venv: ${VENV_DIR} (interpreter: ${PYTHON})"
rm -rf "$VENV_DIR"
"$PYTHON" -m venv "$VENV_DIR"

VENV_PY="${VENV_DIR}/bin/python"
[[ -x "$VENV_PY" ]] || { echo "Expected ${VENV_PY} after venv create; venv is unusable" >&2; exit 1; }

# Fail fast with a precise message if pip is missing inside the venv (common when python3-venv is missing).
if ! "$VENV_PY" -m pip --version >/dev/null 2>&1; then
  echo "pip is missing inside the venv (.venv)." >&2
  echo "On Ubuntu/Debian install: sudo apt-get install -y python3-venv" >&2
  exit 1
fi

echo "Upgrading pip/setuptools/wheel..."
"$VENV_PY" -m pip install --upgrade pip setuptools wheel

echo "Installing requirements.txt..."
"$VENV_PY" -m pip install -r "$REQ"

# Verify required toolchain is present in the venv
"$VENV_PY" -c "import setuptools" >/dev/null 2>&1 || { echo "setuptools missing in venv; venv is unusable" >&2; exit 1; }
"$VENV_PY" -c "import wheel" >/dev/null 2>&1 || { echo "wheel missing in venv; venv is unusable" >&2; exit 1; }

[[ -x "${VENV_DIR}/bin/podman-compose" ]] || { echo "Expected ${VENV_DIR}/bin/podman-compose after install; venv is unusable" >&2; exit 1; }

echo "Done."
echo "Activate with: source ${VENV_DIR}/bin/activate"

