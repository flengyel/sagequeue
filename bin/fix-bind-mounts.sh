#!/usr/bin/env bash
set -euo pipefail

# -------- Configuration --------
# Deterministic: container user/group are fixed by podman-compose.yml (user: "1000:1000")
C_UID="1000"
C_GID="1000"

# Deterministic: mount points must match podman-compose.yml
MOUNT_NOTEBOOKS="$HOME/Jupyter"
MOUNT_JUPYTER="$HOME/.jupyter"
MOUNT_DOT_SAGE="$HOME/.sagequeue-dot_sage"
MOUNT_LOCAL="$HOME/.sagequeue-local"
MOUNT_CONFIG="$HOME/.sagequeue-config"
MOUNT_CACHE="$HOME/.sagequeue-cache"

# Preferred names (script will fall back safely if these collide)
PREFERRED_GROUP="sage"
PREFERRED_USER="sage"

# 1 = create a host user at the mapped UID (purely cosmetic, for nicer ls -l)
# 0 = don't create user (files may show numeric UID, but permissions will still work)
CREATE_USER="1"

# Safer default perms (no world access).
DIR_MODE="2770"   # setgid + rwx for owner/group
FILE_MODE="660"   # rw for owner/group

# -------- Helpers --------
die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

if [[ $EUID -eq 0 ]]; then
  die "Run this as your normal user (not root). It will sudo when needed."
fi

require_cmd podman
require_cmd sudo
require_cmd awk
require_cmd getent
require_cmd id
require_cmd cut
require_cmd stat

if ! command -v setfacl >/dev/null 2>&1; then
  die "Missing 'setfacl'. Install it with: sudo apt-get update && sudo apt-get install -y acl"
fi

map_one() {
  local which="$1" target="$2"
  podman unshare awk -v target="$target" '
    $1 <= target && target < ($1+$3) { print $2 + (target-$1); found=1; exit }
    END { if (!found) exit 1 }
  ' "/proc/self/${which}_map"
}

# -------- Compute mapped host IDs --------
HUID="$(map_one uid "$C_UID")" || die "Could not map container uid $C_UID via podman unshare"
HGID="$(map_one gid "$C_GID")" || die "Could not map container gid $C_GID via podman unshare"

echo "Mapped IDs: container ${C_UID}:${C_GID} -> host ${HUID}:${HGID}"

# -------- Ensure mount dirs exist --------
mkdir -p \
  "$MOUNT_NOTEBOOKS" \
  "$MOUNT_JUPYTER" \
  "$MOUNT_DOT_SAGE" \
  "$MOUNT_LOCAL" \
  "$MOUNT_CONFIG" \
  "$MOUNT_CACHE"

# -------- Group handling --------
if getent group "$HGID" >/dev/null 2>&1; then
  GROUP="$(getent group "$HGID" | cut -d: -f1)"
  echo "Using existing group '$GROUP' (gid=$HGID)"
else
  GROUP="$PREFERRED_GROUP"
  if getent group "$GROUP" >/dev/null 2>&1; then
    existing_gid="$(getent group "$GROUP" | cut -d: -f3)"
    if [[ "$existing_gid" != "$HGID" ]]; then
      GROUP="${GROUP}-${HGID}"
      echo "Preferred group name in use with different gid; using '$GROUP'"
    fi
  fi
  echo "Creating group '$GROUP' with gid=$HGID"
  sudo groupadd -g "$HGID" "$GROUP"
fi

# -------- Optional user handling --------
if [[ "$CREATE_USER" == "1" ]]; then
  if getent passwd "$HUID" >/dev/null 2>&1; then
    existing_user="$(getent passwd "$HUID" | cut -d: -f1)"
    echo "UID $HUID already exists as user '$existing_user' (not creating '$PREFERRED_USER')"
  else
    HOST_SAGE_USER="$PREFERRED_USER"
    if getent passwd "$HOST_SAGE_USER" >/dev/null 2>&1; then
      existing_uid="$(getent passwd "$HOST_SAGE_USER" | cut -d: -f3)"
      if [[ "$existing_uid" != "$HUID" ]]; then
        HOST_SAGE_USER="${HOST_SAGE_USER}-${HUID}"
        echo "Preferred user name in use with different uid; using '$HOST_SAGE_USER'"
      fi
    fi
    echo "Creating user '$HOST_SAGE_USER' uid=$HUID gid=$HGID (nologin, no home dir)"
    sudo useradd -u "$HUID" -g "$HGID" -s /usr/sbin/nologin -M "$HOST_SAGE_USER"
  fi
fi

# -------- Add current user to group (for convenience) --------
if id -nG "$USER" | tr ' ' '\n' | grep -qx "$GROUP"; then
  echo "User '$USER' is already in group '$GROUP'"
else
  echo "Adding '$USER' to group '$GROUP' (takes effect in a new shell; 'newgrp $GROUP' works immediately)"
  sudo usermod -a -G "$GROUP" "$USER"
fi

# -------- Fix ownership + perms + ACLs --------
fix_one_dir() {
  local dir="$1"
  echo "Fixing: $dir"

  # Make sure container-mapped uid/gid own the tree
  sudo chown -R "$HUID:$HGID" "$dir"

  # Tight, consistent modes (no world access by default)
  sudo find "$dir" -type d -exec chmod "$DIR_MODE" {} +
  sudo find "$dir" -type f -exec chmod "$FILE_MODE" {} +

  # ACLs:
  # - ensure YOU always have rwX immediately (prevents lockout even before group refresh)
  # - ensure GROUP has rwX
  # - ensure defaults so new files/dirs keep group write
  sudo setfacl -R \
    -m "u:$USER:rwX" -m "g:$GROUP:rwX" \
    -m "d:u:$USER:rwX" -m "d:g:$GROUP:rwX" \
    "$dir"
}

fix_one_dir "$MOUNT_NOTEBOOKS"
fix_one_dir "$MOUNT_JUPYTER"
fix_one_dir "$MOUNT_DOT_SAGE"
fix_one_dir "$MOUNT_LOCAL"
fix_one_dir "$MOUNT_CONFIG"
fix_one_dir "$MOUNT_CACHE"

echo
echo "Done."
echo "Open a new terminal, or run: newgrp $GROUP"

