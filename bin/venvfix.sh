#!/usr/bin/env bash
set -euo pipefail

# Authoritative venv builder. Called once from bin/setup.sh.
# Must NOT depend on PROJECT_ROOT being set externally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

PYTHON="${1:-python3}"
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

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

echo "Upgrading pip/setuptools/wheel..."
pip install --upgrade pip setuptools wheel

echo "Installing requirements.txt..."
pip install -r "$REQ"

[[ -x "${VENV_DIR}/bin/podman-compose" ]] || { echo "Expected ${VENV_DIR}/bin/podman-compose after install; venv is unusable" >&2; exit 1; }

deactivate
echo "Done."
echo "Activate with: source ${VENV_DIR}/bin/activate"

