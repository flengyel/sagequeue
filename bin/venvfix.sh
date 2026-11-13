#!/usr/bin/env bash
set -euo pipefail
SQ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo 'Usage: bin/venvfix.sh [python-executable]'
    echo "Create or repair this repository's .venv and install requirements.txt."
}
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }
SQ_PYTHON="${1:-python3}"
command -v "$SQ_PYTHON" >/dev/null || { echo "Python is unavailable: $SQ_PYTHON" >&2; exit 1; }
"$SQ_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else "SageQueue requires Python 3.10 or newer.")'

SQ_VENV_PYTHON="$SQ_ROOT/.venv/bin/python"
if [[ ! -x "$SQ_VENV_PYTHON" ]] || ! "$SQ_VENV_PYTHON" -c \
    'import pathlib,sys; sys.exit(pathlib.Path(sys.prefix).resolve() != pathlib.Path(sys.argv[1]).resolve() or sys.prefix == sys.base_prefix)' \
    "$SQ_ROOT/.venv"; then
    if ! "$SQ_PYTHON" -m venv "$SQ_ROOT/.venv"; then
        echo 'Cannot create .venv. On Debian/Ubuntu, install python3-venv, then rerun setup.' >&2
        exit 1
    fi
fi
"$SQ_VENV_PYTHON" -m pip --version >/dev/null || {
    echo 'pip is missing from .venv; install python3-venv and repair the environment.' >&2
    exit 1
}
"$SQ_VENV_PYTHON" -m pip --disable-pip-version-check install -r "$SQ_ROOT/requirements.txt"
"$SQ_VENV_PYTHON" -m pip --disable-pip-version-check check
echo "SageQueue host environment: $SQ_ROOT/.venv (activation is not required)."
