#!/usr/bin/env bash
set -euo pipefail

# Idempotent local setup for sagequeue on Ubuntu/WSL2 (rootless Podman + systemd --user).
# Runs the equivalent of "steps 0-7" from the documented start sequence:
#   0) sanity checks (systemd + podman)
#   1) create bind-mount directories (with .sagequeue-* names)
#   2) verify ${HOME}/Jupyter/rank_boundary_sat_v18.sage exists
#   3) run bin/fix-bind-mounts.sh (bind-mount permissions/ACLs)
#   4) ensure repo-local podman-compose exists at .venv/bin/podman-compose (via bin/venvfix.sh if needed)
#      (does not rely on PATH; does not write to /usr/local/bin)
#   5) bring up the container stack via repo-local podman-compose
#   6) ensure repo scripts are executable
#   7) enable systemd user lingering

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deterministic defaults: do not allow caller environment to override these.
SERVICE="sagemath"
COMPOSE_FILE="${REPO_ROOT}/podman-compose.yml"
PODMAN_COMPOSE="${REPO_ROOT}/.venv/bin/podman-compose"

NOTEBOOKS_HOST="${HOME}/Jupyter"
SAGE_SCRIPT_HOST="${NOTEBOOKS_HOST}/rank_boundary_sat_v18.sage"

# Bind-mount state directories (must match podman-compose.yml)
DIR_JUPYTER="${HOME}/.jupyter"
DIR_DOT_SAGE="${HOME}/.sagequeue-dot_sage"
DIR_LOCAL="${HOME}/.sagequeue-local"
DIR_CONFIG="${HOME}/.sagequeue-config"
DIR_CACHE="${HOME}/.sagequeue-cache"

# var subdirectory
DIR_VAR="${REPO_ROOT}/var"

# Deterministic toggles: do not allow env override.
FIX_PERMS="1"          # 1=run bin/fix-bind-mounts.sh
DO_COMPOSE_UP="1"      # 1=podman-compose up -d
DO_LINGER="1"          # 1=enable linger

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "[warn] $*" >&2; }
die()  { printf '%s\n' "[err]  $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

step() {
  log
  log "== $* =="
}

is_systemd_pid1() {
  local comm
  comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
  [[ "$comm" == "systemd" ]]
}

systemd_user_ok() {
  systemctl --user show-environment >/dev/null 2>&1
}

ensure_dir() {
  local d="$1"
  mkdir -p "$d"
}

ensure_mode_700() {
  local d="$1"
  # Only tighten; do not loosen.
  chmod 700 "$d" 2>/dev/null || true
}

ensure_executable() {
  local f="$1"
  [[ -e "$f" ]] || return 0
  chmod +x "$f" 2>/dev/null || true
}

ensure_podman_compose() {
  # Deterministic: always use repo-local podman-compose at ${PODMAN_COMPOSE}.
  # If missing, create .venv via bin/venvfix.sh (the only venv builder).
  if [[ -x "${PODMAN_COMPOSE}" ]]; then
    log "[ok] podman-compose present: ${PODMAN_COMPOSE}"
    return 0
  fi

  local venvfix="${REPO_ROOT}/bin/venvfix.sh"
  [[ -f "${venvfix}" ]] || die "Missing venv builder: ${venvfix}"
  ensure_executable "${venvfix}"
  log "[run] ${venvfix}"
  "${venvfix}"

  [[ -x "${PODMAN_COMPOSE}" ]] || die "venvfix.sh completed, but expected ${PODMAN_COMPOSE} was not found"
  log "[ok] podman-compose present: ${PODMAN_COMPOSE}"
}

enable_linger() {
  require_cmd loginctl

  local linger
  linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)"
  if [[ "$linger" == "yes" ]]; then
    log "[ok] linger already enabled for $USER"
    return 0
  fi

  log "[run] loginctl enable-linger $USER"
  if loginctl enable-linger "$USER" >/dev/null 2>&1; then
    log "[ok] linger enabled for $USER"
    return 0
  fi

  # Some setups require elevated privileges.
  require_cmd sudo
  sudo loginctl enable-linger "$USER"
  log "[ok] linger enabled for $USER (via sudo)"
}

step "0) Sanity checks (systemd + podman)"
require_cmd ps
require_cmd podman

if ! is_systemd_pid1; then
  warn "PID 1 is not systemd; systemctl --user may not work. (WSL2 requires systemd=true in /etc/wsl.conf)"
else
  log "[ok] PID 1 is systemd"
fi

if ! podman ps >/dev/null 2>&1; then
  warn "podman ps failed. Rootless Podman may not be usable under this user/session."
  podman ps || true
  die "Fix podman before continuing."
else
  log "[ok] podman ps works"
fi

if systemd_user_ok; then
  log "[ok] systemctl --user is usable"
else
  warn "systemctl --user is not usable in this session. Queue services will not work until this is fixed."
fi

step "1) Create required directories"

DIRS_TO_CREATE=(
  "$NOTEBOOKS_HOST"
  "$DIR_JUPYTER"
  "$DIR_DOT_SAGE"
  "$DIR_LOCAL"
  "$DIR_CONFIG"
  "$DIR_CACHE"
  "$DIR_VAR"          # repo runtime state (var/<JOBSET>/...)
)

for d in "${DIRS_TO_CREATE[@]}"; do
  ensure_dir "$d"
done

SECURE_DIRS=(
  "$DIR_DOT_SAGE"
  "$DIR_LOCAL"
  "$DIR_CONFIG"
  "$DIR_CACHE"
)

for d in "${SECURE_DIRS[@]}"; do
  ensure_mode_700 "$d"
done

log "[ok] directories ensured:"
for d in "${DIRS_TO_CREATE[@]}"; do
  log "  ${d}"
done

step "2) Verify Sage script exists in ${NOTEBOOKS_HOST}"
[[ -f "$SAGE_SCRIPT_HOST" ]] || die "Missing expected Sage script: ${SAGE_SCRIPT_HOST}"
log "[ok] found ${SAGE_SCRIPT_HOST}"

step "3) Fix bind-mount permissions (ACLs) (FIX_PERMS=${FIX_PERMS})"
if [[ "$FIX_PERMS" == "1" ]]; then
  local_fix="${REPO_ROOT}/bin/fix-bind-mounts.sh"
  [[ -f "$local_fix" ]] || die "Expected ${local_fix} (you moved it to bin/)"
  ensure_executable "$local_fix"
  log "[run] ${local_fix}"
  "$local_fix"
  log "[ok] bind-mount permissions fixed"
else
  warn "skipping permission fix (FIX_PERMS=0)"
fi

step "4) Ensure podman-compose (repo venv)"
ensure_podman_compose

step "5) Bring up container stack (DO_COMPOSE_UP=${DO_COMPOSE_UP})"
if [[ "$DO_COMPOSE_UP" == "1" ]]; then
  [[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: ${COMPOSE_FILE}"
  log "[run] ${PODMAN_COMPOSE} -f ${COMPOSE_FILE} up -d ${SERVICE}"
  "${PODMAN_COMPOSE}" -f "$COMPOSE_FILE" up -d "$SERVICE"
  # Verify the notebook mount is visible
  log "[run] verify mounted Sage script inside container"
  script_base="$(basename "$SAGE_SCRIPT_HOST")"
  podman exec "$SERVICE" test -f "/home/sage/notebooks/${script_base}" \
    || die "Container does not see the script at /home/sage/notebooks/${script_base}"
  log "[ok] container is up and sees the script"
else
  warn "skipping compose up (DO_COMPOSE_UP=0)"
fi

step "6) Ensure repo scripts are executable"
# bin scripts
if compgen -G "${REPO_ROOT}/bin/*.sh" >/dev/null; then
  chmod +x "${REPO_ROOT}/bin/"*.sh 2>/dev/null || true
fi
# top-level helpers if present
ensure_executable "${REPO_ROOT}/man-up.sh"
ensure_executable "${REPO_ROOT}/man-down.sh"
ensure_executable "${REPO_ROOT}/run-bash.sh"

log "[ok] executable bits applied (where supported)"

step "7) Enable linger (DO_LINGER=${DO_LINGER})"
if [[ "$DO_LINGER" == "1" ]]; then
  if command -v loginctl >/dev/null 2>&1; then
    enable_linger || warn "could not enable linger; run manually: loginctl enable-linger $USER"
  else
    warn "loginctl not found; cannot enable linger in this environment"
  fi
else
  warn "skipping linger enable (DO_LINGER=0)"
fi

log
log "Setup complete."
log "Next:"
log "  make CONFIG=config/shrikhande_r3.mk enable"
log "  make CONFIG=config/shrikhande_r3.mk enqueue-stride"

