#!/bin/bash
#
# uninstall-ssh-harden.sh
#
# Undoes ssh_harden.sh: restores /etc/ssh/sshd_config from the OLDEST
# timestamped backup ssh_harden.sh created (sshd_config.bak.YYYYMMDD_HHMMSS),
# not just the most recent one - the oldest backup is the true
# pre-hardening state, since re-running ssh_harden.sh again would just
# create another backup of the already-hardened config.
#
# Restoring an older config that (re-)enables password authentication is
# not a lockout risk the way the original hardening script's own actions
# were - adding an auth method back can't lock you out, only removing one
# can - so this doesn't need the same "do you have a key first" check
# ssh_harden.sh does.
#
# Usage:
#   sudo ./uninstall-ssh-harden.sh
#   sudo ./uninstall-ssh-harden.sh --yes   # skip confirmation
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

SSHD_CONFIG="/etc/ssh/sshd_config"

echo "=== Uninstall SSH Hardening ==="

shopt -s nullglob
BACKUPS=(/etc/ssh/sshd_config.bak.*)
shopt -u nullglob

if [[ ${#BACKUPS[@]} -eq 0 ]]; then
  echo "[*] No sshd_config backup found (ssh_harden.sh.bak.*) - nothing to restore."
  echo "    Either SSH hardening was never run, or the backup was already"
  echo "    removed. Edit ${SSHD_CONFIG} by hand if you want to change auth"
  echo "    settings."
  exit 0
fi

OLDEST_BACKUP=$(printf '%s\n' "${BACKUPS[@]}" | sort | head -1)

echo "This will:"
echo "  - Restore ${SSHD_CONFIG} from ${OLDEST_BACKUP}"
echo "    (the oldest backup found - the state before hardening was ever applied)"
echo "  - Validate the restored config with sshd -t before restarting SSH"
echo
echo "This will likely re-enable password authentication if it was on"
echo "before hardening. Restoring an old config that re-enables an auth"
echo "method can't lock you out - only removing one can - so this is safe"
echo "even non-interactively."
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

CURRENT_BACKUP="/etc/ssh/sshd_config.before-uninstall.$(date +%Y%m%d_%H%M%S)"
echo "[*] Backing up current (hardened) config to ${CURRENT_BACKUP} first, just in case..."
cp "$SSHD_CONFIG" "$CURRENT_BACKUP"

echo "[*] Restoring ${OLDEST_BACKUP}..."
cp "$OLDEST_BACKUP" "$SSHD_CONFIG"

echo "[*] Validating restored config..."
if ! sshd -t; then
  echo "[!] sshd -t reported an error in the restored config. Reverting to" >&2
  echo "    the hardened version and aborting." >&2
  cp "$CURRENT_BACKUP" "$SSHD_CONFIG"
  exit 1
fi

echo "[*] Restarting SSH..."
systemctl restart ssh || systemctl restart sshd

echo
echo "=== Done ==="
echo "SSH config restored from: ${OLDEST_BACKUP}"
echo "Pre-restore (hardened) config saved at: ${CURRENT_BACKUP}"
echo
echo "As always when touching SSH config: test a fresh login in another"
echo "terminal before closing this session."
