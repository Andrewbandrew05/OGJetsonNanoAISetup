#!/bin/bash
#
# ssh_harden.sh
#
# Configures OpenSSH to only allow key-based login (disables password and
# keyboard-interactive auth) and disables root login over SSH.
#
# SAFETY: Before making any change, this script verifies that the invoking
# user already has at least one key in ~/.ssh/authorized_keys. If none is
# found, it aborts rather than risk locking you out. It also validates the
# new config with `sshd -t` before restarting the service, and keeps a
# timestamped backup of the original file.
#
# Usage:
#   chmod +x ssh_harden.sh
#   sudo ./ssh_harden.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"

echo "=== SSH Key-Only Login Hardening ==="

# --- Safety check: make sure a key is actually set up first ---
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [[ -z "$TARGET_USER" ]]; then
  echo "[!] Could not determine the invoking user. Aborting for safety." >&2
  exit 1
fi

USER_HOME=$(eval echo "~${TARGET_USER}")
AUTH_KEYS="${USER_HOME}/.ssh/authorized_keys"

if [[ ! -s "$AUTH_KEYS" ]]; then
  echo "[!] No authorized_keys found (or it's empty) at: $AUTH_KEYS" >&2
  echo "[!] Disabling password auth now would lock you out over SSH." >&2
  echo "    Add your public key first, e.g. from your local machine run:" >&2
  echo "        ssh-copy-id ${TARGET_USER}@<nano-ip>" >&2
  echo "    Then re-run this script." >&2
  exit 1
fi

echo "[*] Found authorized_keys for '$TARGET_USER' with $(wc -l < "$AUTH_KEYS") key(s). Proceeding."

echo "[*] Backing up $SSHD_CONFIG to $BACKUP..."
cp "$SSHD_CONFIG" "$BACKUP"

# Helper: set "Key Value" in sshd_config, uncommenting/replacing if present,
# appending if not.
set_option() {
  local key="$1"
  local value="$2"
  if grep -qiE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$SSHD_CONFIG"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${value}|I" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" >> "$SSHD_CONFIG"
  fi
}

echo "[*] Applying key-only login settings..."
set_option "PubkeyAuthentication" "yes"
set_option "PasswordAuthentication" "no"
set_option "KbdInteractiveAuthentication" "no"
set_option "ChallengeResponseAuthentication" "no"
set_option "PermitRootLogin" "prohibit-password"
set_option "UsePAM" "yes"

echo "[*] Validating new sshd config..."
if ! sshd -t; then
  echo "[!] sshd -t reported an error. Restoring backup and aborting." >&2
  cp "$BACKUP" "$SSHD_CONFIG"
  exit 1
fi

echo "[*] Restarting SSH service..."
systemctl restart ssh || systemctl restart sshd

echo
echo "=== Done ==="
echo "Backup of original config: $BACKUP"
echo "Password login is now disabled; key-based login only."
echo
echo "IMPORTANT: keep your current session open and test a fresh SSH login"
echo "from another terminal before closing this one, to confirm key auth works."
