#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/sagequeue.py" doctor
python3 "$ROOT/sagequeue.py" tasks status --json
