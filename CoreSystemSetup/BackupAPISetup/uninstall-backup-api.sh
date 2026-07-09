#!/bin/bash
#
# uninstall-backup-api.sh
#
# Undoes backup_api_install.sh: stops/disables/removes all three systemd
# units it created (nano-ai-api.service, nano-ai-backup.service,
# nano-ai-backup.timer) and removes /opt/nano-ai-backup and
# /etc/nano-ai-backup.
#
# IMPORTANT: this does NOT touch your remote backup target (the restic
# repository on your NAS or S3 bucket) - your actual backups stay exactly
# where they are. This only removes the local API/service/config on this
# Nano. If you want the remote backups gone too, that's a separate,
# deliberate action on the remote side - not something this script does
# for you.
#
# The dedicated backup SSH key (/root/.ssh/id_ed25519_backup) and its
# Host alias in /root/.ssh/config are asked about separately, since
# removing the local private key doesn't revoke it on the remote side -
# you'd still want to remove it from the remote's authorized_keys
# yourself if you want it fully revoked.
#
# Usage:
#   sudo ./uninstall-backup-api.sh
#   sudo ./uninstall-backup-api.sh --yes   # skip confirmations
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

AUTO_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=1 ;;
  esac
done
if [[ "${NANO_SETUP_AUTO_YES:-0}" == "1" || "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
  AUTO_YES=1
fi

INSTALL_DIR="/opt/nano-ai-backup"
CONF_DIR="/etc/nano-ai-backup"
KEYFILE="/root/.ssh/id_ed25519_backup"

echo "=== Uninstall Backup + Control API ==="

if [[ ! -f /etc/systemd/system/nano-ai-api.service && ! -d "$INSTALL_DIR" && ! -d "$CONF_DIR" ]]; then
  echo "[*] Nothing to uninstall - no backup API service or config found."
  exit 0
fi

echo "This will:"
echo "  - Stop and disable nano-ai-api.service, nano-ai-backup.service,"
echo "    and nano-ai-backup.timer"
echo "  - Remove those three unit files"
echo "  - Remove ${INSTALL_DIR} and ${CONF_DIR} (including the restic"
echo "    password and API token - see the note below)"
echo
echo "It will NOT touch your remote backup target - your actual backups"
echo "stay exactly where they are on your NAS/S3 bucket. Only the local"
echo "API/service/config on this Nano is removed."
echo
echo "IMPORTANT: ${CONF_DIR}/restic.env contains the encryption password"
echo "for your remote backups. Once this is deleted, if you didn't save"
echo "that password somewhere else, those backups become permanently"
echo "undecryptable. Make sure you have it saved before continuing if you"
echo "might ever want to restore from them."
echo

if [[ $AUTO_YES -eq 1 ]]; then
  echo "Continue? Type 'yes' to proceed: yes (auto-accepted)"
else
  read -rp "Continue? Type 'yes' to proceed: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "[*] Stopping and disabling services..."
for unit in nano-ai-api.service nano-ai-backup.service nano-ai-backup.timer; do
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
  rm -f "/etc/systemd/system/$unit"
done
systemctl daemon-reload

echo "[*] Removing ${INSTALL_DIR} and ${CONF_DIR}..."
rm -rf "$INSTALL_DIR" "$CONF_DIR"

echo
if [[ -f "$KEYFILE" ]]; then
  echo "Dedicated backup SSH key found at ${KEYFILE}."
  echo "Removing it only affects THIS machine - it does NOT revoke the key"
  echo "on the remote host. If you want it fully revoked, also remove the"
  echo "matching public key from the remote's ~/.ssh/authorized_keys."
  if [[ $AUTO_YES -eq 1 ]]; then
    echo "Remove the local key too? Type 'yes' to proceed: yes (auto-accepted)"
    REMOVE_KEY="yes"
  else
    read -rp "Remove the local key too? Type 'yes' to delete, anything else to keep it: " REMOVE_KEY
  fi
  if [[ "$REMOVE_KEY" == "yes" ]]; then
    rm -f "$KEYFILE" "${KEYFILE}.pub"
    sed -i '/^Host nano-backup-target$/,/^$/d' /root/.ssh/config 2>/dev/null || true
    echo "[*] Removed ${KEYFILE} and its Host alias from /root/.ssh/config."
  else
    echo "[*] Left the SSH key and Host alias in place."
  fi
else
  echo "[*] No dedicated backup SSH key found - nothing to remove there."
fi

echo
echo "=== Done ==="
echo "Backup + control API has been uninstalled from this Nano. Your"
echo "remote backups (if any) are untouched."
