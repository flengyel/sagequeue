#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null
command -v podman >/dev/null
command -v setfacl >/dev/null || { echo 'Install the host acl package first.' >&2; exit 1; }
command -v getfacl >/dev/null || { echo 'Install the host acl package first.' >&2; exit 1; }
bash "$ROOT/bin/venvfix.sh"
"$ROOT/.venv/bin/python" "$ROOT/sagequeue.py" doctor
mkdir -p "$HOME/.local/bin"
chmod +x "$ROOT/bin/sagequeue"
ln -sfn "$ROOT/bin/sagequeue" "$HOME/.local/bin/sagequeue"
printf '%s\n' "Installed $HOME/.local/bin/sagequeue" 'Add ~/.local/bin to PATH if necessary.'
