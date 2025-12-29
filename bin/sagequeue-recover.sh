#!/usr/bin/env bash
set -euo pipefail

: "${RUNNING_DIR:?}"
: "${PENDING_DIR:?}"
: "${RUN_DIR:?}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }; }
require_cmd flock
require_cmd ps

mkdir -p "$RUNNING_DIR" "$PENDING_DIR" "$RUN_DIR"

# Single-run global lock (safe with many workers + timer)
lockfile="$RUN_DIR/recover.lock"
exec 9>"$lockfile"
if ! flock -n 9; then
  exit 0
fi

shopt -s nullglob

read_owner_pid() {
( set -euo pipefail
  local owner="$1"
  local pid=""
  # Only accept OWNER_PID=<int> from the owner file; do not source.
  pid="$(grep -E '^OWNER_PID=[0-9]+$' "$owner" 2>/dev/null | head -n 1 | cut -d= -f2 || true)"
  [[ -n "$pid" ]] || exit 1
  printf '%s\n' "$pid"
)
}

n=0
for runjob in "$RUNNING_DIR"/*.env; do
  owner="$runjob.owner"
  orphan=0
  reason=""

  if [[ ! -f "$owner" ]]; then
    orphan=1
    reason="missing owner file"
  else
    OWNER_PID=""
    if OWNER_PID="$(read_owner_pid "$owner" 2>/dev/null)"; then
      if ! kill -0 "$OWNER_PID" 2>/dev/null; then
        orphan=1
        reason="OWNER_PID not alive"
      else
        args="$(ps -p "$OWNER_PID" -o args= 2>/dev/null || true)"
        if [[ "$args" != *"sagequeue-worker.sh"* ]]; then
          orphan=1
          reason="OWNER_PID is not a sagequeue-worker.sh process"
        fi
      fi
    else
      orphan=1
      reason="missing/invalid OWNER_PID in owner file"
    fi
  fi

  if [[ "$orphan" -eq 1 ]]; then
    base="$(basename "$runjob")"
    rm -f "$owner" 2>/dev/null || true

    if mv -f "$runjob" "$PENDING_DIR/$base" 2>/dev/null; then
      n=$((n+1))
      [[ -n "$reason" ]] || reason="unknown"
      echo "[recover] requeued: $base reason=$reason"
    else
      [[ -n "$reason" ]] || reason="unknown"
      echo "[recover] WARN: could not move back to pending: $base reason=$reason" >&2
    fi
  fi
done

echo "[recover] requeued orphaned jobs: $n"

