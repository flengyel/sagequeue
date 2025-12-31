#!/usr/bin/env bash
set -euo pipefail

: "${RUNNING_DIR:?}"
: "${PENDING_DIR:?}"
: "${FAILED_DIR:?}"
: "${RUN_DIR:?}"

MAX_FAILED_RETRIES=3

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }; }
require_cmd flock
require_cmd ps
require_cmd awk
require_cmd mktemp

mkdir -p "$RUNNING_DIR" "$PENDING_DIR" "$FAILED_DIR" "$RUN_DIR"

# Single-run global lock (safe with many workers + timer)
lockfile="$RUN_DIR/recover.lock"
exec 9>"$lockfile"
if ! flock -n 9; then
  exit 0
fi

shopt -s nullglob

ts_now() { date -Is 2>/dev/null || date; }

read_owner_pid() {
( set -euo pipefail
  local owner="$1"
  local pid=""
  pid="$(grep -E '^OWNER_PID=[0-9]+$' "$owner" 2>/dev/null | head -n 1 | cut -d= -f2 || true)"
  [[ -n "$pid" ]] || exit 1
  printf '%s\n' "$pid"
)
}

read_attempts() {
  local f="$1"
  local a=""
  a="$(grep -E '^ATTEMPTS=[0-9]+$' "$f" 2>/dev/null | head -n 1 | cut -d= -f2 || true)"
  [[ -n "$a" ]] || a="0"
  printf '%s\n' "$a"
}

write_retry_meta() {
  local f="$1" attempts="$2" ts="$3"
  local tmp
  tmp="$(mktemp "${f}.tmp.XXXX")"
  awk -v attempts="$attempts" -v ts="$ts" '
    BEGIN{haveA=0; haveT=0}
    /^ATTEMPTS=/      {print "ATTEMPTS=" attempts; haveA=1; next}
    /^LAST_RETRY_TS=/ {print "LAST_RETRY_TS=" ts; haveT=1; next}
    {print}
    END{
      if(!haveA) print "ATTEMPTS=" attempts
      if(!haveT) print "LAST_RETRY_TS=" ts
    }
  ' "$f" >"$tmp"
  mv -f "$tmp" "$f"
}

# --- Phase 1: orphan recovery (running -> pending) ---

scanned_running=0
requeued_orphans=0

for runjob in "$RUNNING_DIR"/*.env; do
  scanned_running=$((scanned_running+1))

  owner="$runjob.owner"
  orphan=0
  reason=""
  OWNER_PID=""

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
    if mv -f "$runjob" "$PENDING_DIR/$base" 2>/dev/null; then
      requeued_orphans=$((requeued_orphans+1))
      echo "[recover] ts=$ts action=requeue_orphan job=$base reason=$reason owner_pid=${OWNER_PID:-}"
    else
      echo "[recover] ts=$ts action=warn job=$base reason=$reason owner_pid=${OWNER_PID:-} error=move_failed" >&2
    fi
  fi
done

# --- Phase 2: automatic retry (failed -> pending) ---

# --- Phase 2: automatic retry (failed -> pending) ---

scanned_failed=0
retried_failed=0
skipped_failed=0
held_failed=0

for failjob in "$FAILED_DIR"/*.env; do
  scanned_failed=$((scanned_failed+1))
  base="$(basename "$failjob")"

  # If the job is malformed, do not loop forever; leave it in failed/ but log it.
  off="$(grep -E '^OFFSET=[0-9]+$' "$failjob" 2>/dev/null | head -n 1 | cut -d= -f2 || true)"
  if [[ -z "$off" ]]; then
    ts="$(ts_now)"
    skipped_failed=$((skipped_failed+1))
    echo "[recover] ts=$ts action=skip_failed job=$base reason=invalid_job_no_offset"
    continue
  fi

  a="$(read_attempts "$failjob")"
  if (( a >= MAX_FAILED_RETRIES )); then
    ts="$(ts_now)"
    held_failed=$((held_failed+1))
    echo "[recover] ts=$ts action=hold_failed job=$base attempts=$a reason=max_failed_retries_reached"
    continue
  fi

  a=$((a+1))
  ts="$(ts_now)"
  write_retry_meta "$failjob" "$a" "$ts"

  if mv -f "$failjob" "$PENDING_DIR/$base" 2>/dev/null; then
    retried_failed=$((retried_failed+1))
    echo "[recover] ts=$ts action=retry_failed job=$base attempts=$a"
  else
    echo "[recover] ts=$ts action=warn job=$base attempts=$a error=move_failed" >&2
  fi
done


ts="$(ts_now)"
echo "[recover] ts=$ts action=summary scanned_running=$scanned_running requeued_orphans=$requeued_orphans scanned_failed=$scanned_failed retried_failed=$retried_failed skipped_failed=$skipped_failed held_failed=$held_failed"

