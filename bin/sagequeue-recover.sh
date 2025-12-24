#!/usr/bin/env bash
set -euo pipefail

: "${RUNNING_DIR:?}"
: "${PENDING_DIR:?}"
: "${RUN_DIR:?}"

mkdir -p "$RUNNING_DIR" "$PENDING_DIR" "$RUN_DIR"

# Single-run global lock (safe with many workers + timer)
lockfile="$RUN_DIR/recover.lock"
exec 9>"$lockfile"
if ! flock -n 9; then
  exit 0
fi

shopt -s nullglob

n=0
for runjob in "$RUNNING_DIR"/*.env; do
  owner="$runjob.owner"
  orphan=0

  if [[ ! -f "$owner" ]]; then
    orphan=1
  else
    # shellcheck disable=SC1090
    source "$owner" || orphan=1
    if [[ -z "${OWNER_PID:-}" ]] || ! kill -0 "$OWNER_PID" 2>/dev/null; then
      orphan=1
    else
      args="$(ps -p "$OWNER_PID" -o args= 2>/dev/null || true)"
      if [[ "$args" != *"sagequeue-worker.sh"* ]]; then
        orphan=1
      fi
    fi
  fi

  if [[ "$orphan" -eq 1 ]]; then
    base="$(basename "$runjob")"
    rm -f "$owner" 2>/dev/null || true
    mv -f "$runjob" "$PENDING_DIR/$base" 2>/dev/null || true
    n=$((n+1))
  fi
done

echo "[recover] requeued orphaned jobs: $n"

