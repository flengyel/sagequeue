#!/usr/bin/env bash
set -euo pipefail

WORKER_ID="${1:-0}"

: "${PROJECT_ROOT:?}"
: "${SERVICE:?}"
: "${CONTAINER_WORKDIR:?}"
: "${SAGE_BIN:?}"
: "${SCRIPT:?}"
: "${STRIDE:?}"
: "${LOG_PREFIX:?}"
: "${SAGE_BASE_ARGS:?}"

: "${PENDING_DIR:?}"
: "${RUNNING_DIR:?}"
: "${DONE_DIR:?}"
: "${FAILED_DIR:?}"
: "${LOG_DIR:?}"

# Host path for stop gating (NOT the container path)
: "${STOP_FILE_HOST:?}"

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }; }
require_cmd podman
require_cmd find
require_cmd tee

if ! [[ "$WORKER_ID" =~ ^[0-9]+$ ]]; then
  echo "[config error] WORKER_ID must be an integer (got: $WORKER_ID)" >&2
  exit 2
fi

# Invariant: base args must not carry partitioning. Worker injects both.
if [[ "$SAGE_BASE_ARGS" == *"--stride"* || "$SAGE_BASE_ARGS" == *"--offset"* ]]; then
  echo "[config error] SAGE_BASE_ARGS must not include --stride or --offset." >&2
  exit 2
fi

mkdir -p "$PENDING_DIR" "$RUNNING_DIR" "$DONE_DIR" "$FAILED_DIR" "$LOG_DIR"

shutdown=0
trap 'shutdown=1' TERM INT

read_job_offset() {
  local f="$1"
  local off=""
  off="$(grep -E '^OFFSET=' "$f" 2>/dev/null | head -n 1 | cut -d= -f2 | tr -d $'\r' || true)"
  [[ "$off" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$off"
}

# One-shot recovery before the loop (safe if also run by other workers; recover uses flock)
"${PROJECT_ROOT}/bin/sagequeue-recover.sh" >/dev/null 2>&1 || true

while true; do
  [[ "$shutdown" -eq 0 ]] || exit 0

  # Stop file prevents *new* job claims; Sage itself handles stop_file while running.
  if [[ -f "${STOP_FILE_HOST}" ]]; then
    sleep "${SLEEP_EMPTY:-2}"
    continue
  fi

  job="$(find "$PENDING_DIR" -maxdepth 1 -type f -name '*.env' -print -quit 2>/dev/null || true)"
  if [[ -z "$job" ]]; then
    sleep "${SLEEP_EMPTY:-2}"
    continue
  fi

  base="$(basename "$job")"
  runjob="$RUNNING_DIR/$base"

  # Atomic claim
  if ! mv "$job" "$runjob" 2>/dev/null; then
    continue
  fi

  owner="$runjob.owner"
  {
    echo "OWNER_PID=$$"
    echo "OWNER_WORKER_ID=$WORKER_ID"
    echo "OWNER_TS=$(date -Is 2>/dev/null || date)"
  } > "$owner"

  OFFSET=""
  if ! OFFSET="$(read_job_offset "$runjob")"; then
    rm -f "$owner" 2>/dev/null || true
    mv -f "$runjob" "$FAILED_DIR/$base"
    continue
  fi

  logfile="$LOG_DIR/${LOG_PREFIX}_off${OFFSET}.log"
  echo "[worker $WORKER_ID] start offset=$OFFSET job=$base at $(date -Is 2>/dev/null || date)" | tee -a "$logfile"

  # Ensure the container is up. If this fails, treat it as a job failure (do not orphan running jobs).
  if ! "${PROJECT_ROOT}/bin/sagequeue-ensure-container.sh"; then
    rc=$?
    rm -f "$owner" 2>/dev/null || true
    echo "[worker $WORKER_ID] failed offset=$OFFSET rc=$rc reason=ensure-container at $(date -Is 2>/dev/null || date)" | tee -a "$logfile"
    mv -f "$runjob" "$FAILED_DIR/$base"
    continue
  fi

  set +e
  podman exec "$SERVICE" bash -c \
    "set -euo pipefail; cd '$CONTAINER_WORKDIR' && $SAGE_BIN '$SCRIPT' $SAGE_BASE_ARGS --stride '$STRIDE' --offset '$OFFSET'" \
    </dev/null 2>&1 | tee -a "$logfile"
  rc=$?
  set -e

  rm -f "$owner" 2>/dev/null || true

  if [[ "$rc" -eq 0 ]]; then
    echo "[worker $WORKER_ID] done offset=$OFFSET rc=$rc at $(date -Is 2>/dev/null || date)" | tee -a "$logfile"
    mv -f "$runjob" "$DONE_DIR/$base"
  else
    echo "[worker $WORKER_ID] failed offset=$OFFSET rc=$rc at $(date -Is 2>/dev/null || date)" | tee -a "$logfile"
    mv -f "$runjob" "$FAILED_DIR/$base"
  fi
done

