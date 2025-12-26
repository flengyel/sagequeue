#!/usr/bin/env bash
set -euo pipefail

# Create/refresh a local virtual environment under .venv and install requirements.
#
# Usage:
#   ./venvfix.sh              # uses python3
#   ./venvfix.sh python3.12   # specify interpreter
#
# This repo reserves ./bin for project scripts. The venv lives in ./.venv.

PYTHON="${1:-python3}"
VENV_DIR="${VENV_DIR:-.venv}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }; }
require_cmd "$PYTHON"

# Relative to PROJECT_ROOT 
cd $PROJECT_ROOT

echo "Creating venv: ${VENV_DIR} (interpreter: ${PYTHON})"
rm -rf "${VENV_DIR}"
"${PYTHON}" -m venv "${VENV_DIR}"

# shellcheck disable=SC1090
source "${VENV_DIR}/bin/activate"

echo "Upgrading pip/setuptools/wheel..."
pip install --upgrade pip setuptools wheel

if [[ -f requirements.txt ]]; then
  echo "Installing requirements.txt..."
  pip install -r requirements.txt
else
  echo "requirements.txt not found; skipping."
fi

deactivate
echo "Done."
echo "Activate with: source ${VENV_DIR}/bin/activate"
