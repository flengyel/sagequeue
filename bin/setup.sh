#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null
command -v podman >/dev/null
python3 "$ROOT/sagequeue.py" doctor
mkdir -p "$HOME/.local/bin"
chmod +x "$ROOT/bin/sagequeue"
ln -sfn "$ROOT/bin/sagequeue" "$HOME/.local/bin/sagequeue"
printf '%s\n' "Installed $HOME/.local/bin/sagequeue" 'Add ~/.local/bin to PATH if necessary.'
