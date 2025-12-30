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

ts_now() { date -Is 2>/dev/null || date; }

n=0
scanned=0

for runjob in "$RUNNING_DIR"/*.env; do
  scanned=$((scanned+1))

  owner="$runjob.owner"
  orphan=0
  reason=""
  OWNER_PID=""   # reset per job to avoid leaking a previous value

  if [[ ! -f "$owner" ]]; then
    orphan=1
    reason="missing_owner_file"
  else
    if OWNER_PID="$(read_owner_pid "$owner" 2>/dev/null)"; then
      if ! kill -0 "$OWNER_PID" 2>/dev/null; then
        orphan=1
        reason="owner_pid_dead"
      else
        args="$(ps -p "$OWNER_PID" -o args= 2>/dev/null || true)"
        if [[ "$args" != *"sagequeue-worker.sh"* ]]; then
          orphan=1
          reason="owner_pid_not_worker"
        fi
      fi
    else
      orphan=1
      reason="missing_or_invalid_owner_pid"
    fi
  fi

  if [[ "$orphan" -eq 1 ]]; then
    base="$(basename "$runjob")"
    rm -f "$owner" 2>/dev/null || true

    ts="$(ts_now)"
    [[ -n "$reason" ]] || reason="unknown"

    if mv -f "$runjob" "$PENDING_DIR/$base" 2>/dev/null; then
      n=$((n+1))
      echo "[recover] ts=$ts action=requeue job=$base reason=$reason owner_pid=${OWNER_PID:-}"
    else
      echo "[recover] ts=$ts action=warn job=$base reason=$reason owner_pid=${OWNER_PID:-} error=move_failed" >&2
    fi
  fi
done

ts="$(ts_now)"
echo "[recover] ts=$ts action=summary scanned=$scanned requeued=$n"

