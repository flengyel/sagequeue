#!/usr/bin/env bash
set -euo pipefail

# sagequeue-diag.sh
# Diagnostic snapshot: queue state + systemd units + container + running solver processes.
#
# Usage:
#   bin/sagequeue-diag.sh
#
# It reads the active environment file written by `make ... env`:
#   ~/.config/sagequeue/sagequeue.env

ENV_FILE="${ENV_FILE:-$HOME/.config/sagequeue/sagequeue.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[err] missing env file: $ENV_FILE" >&2
  echo "Run: make CONFIG=config/<jobset>.mk env" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

now="$(date -Is 2>/dev/null || date)"

echo "=== sagequeue diag ==="
echo "time=$now"
echo

echo "== config =="
echo "PROJECT_ROOT=$PROJECT_ROOT"
echo "JOBSET=$JOBSET"
echo "STRIDE=$STRIDE"
echo "SERVICE=$SERVICE"
echo "COMPOSE_FILE=$COMPOSE_FILE"
echo "SCRIPT=$SCRIPT"
echo "STOP_FILE_CONT=$STOP_FILE_CONT"
echo "STOP_FILE_HOST=$STOP_FILE_HOST"
echo

count_dir() {
  local d="$1"
  if [[ -d "$d" ]]; then
    find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

echo "== queue counts =="
p="$(count_dir "$PENDING_DIR")"
r="$(count_dir "$RUNNING_DIR")"
d="$(count_dir "$DONE_DIR")"
f="$(count_dir "$FAILED_DIR")"
t="$((p+r+d+f))"
echo "jobset=$JOBSET pending=$p running=$r done=$d failed=$f total=$t"
echo

list_jobs() {
  local label="$1"
  local dir="$2"
  echo "-- $label ($dir) --"
  if [[ ! -d "$dir" ]]; then
    echo "[missing]"
    echo
    return 0
  fi
  shopt -s nullglob
  local files=("$dir"/*.env)
  if (( ${#files[@]} == 0 )); then
    echo "[empty]"
    echo
    return 0
  fi
  for fpath in "${files[@]}"; do
    off="$(grep -m1 -E '^OFFSET=' "$fpath" 2>/dev/null | cut -d= -f2 || true)"
    enq="$(grep -m1 -E '^ENQUEUED_AT=' "$fpath" 2>/dev/null | cut -d= -f2- || true)"
    printf "%s offset=%s enqueued=%s\n" "$(basename "$fpath")" "${off:-?}" "${enq:-?}"
  done
  echo
}

echo "== queue listing =="
list_jobs "pending" "$PENDING_DIR"
list_jobs "running" "$RUNNING_DIR"
list_jobs "failed" "$FAILED_DIR"

echo "== systemd (user) =="
systemctl --user --no-pager --plain list-units 'sagequeue*' 2>/dev/null || true
echo

echo "== container =="
podman ps --filter "name=${SERVICE}" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null || true
podman inspect "${SERVICE}" --format 'image={{.ImageName}} created={{.Created}}' 2>/dev/null || true
podman stats --no-stream "${SERVICE}" 2>/dev/null || true
echo

echo "== solver processes (inside container) =="
pat="$(basename "$SCRIPT").py"
podman exec "${SERVICE}" bash -lc "pgrep -af '$pat' | sed -n '1,40p'" 2>/dev/null || true
echo

echo "== last log lines (per offset) =="
if [[ -d "$LOG_DIR" ]]; then
  shopt -s nullglob
  logs=("$LOG_DIR"/*.log)
  if (( ${#logs[@]} == 0 )); then
    echo "[no logs]"
  else
    for lp in "${logs[@]}"; do
      echo "--- $(basename "$lp")"
      tail -n 3 "$lp" || true
    done
  fi
else
  echo "[missing log dir]"
fi
