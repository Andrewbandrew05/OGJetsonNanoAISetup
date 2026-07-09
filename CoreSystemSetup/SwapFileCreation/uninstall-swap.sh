#!/bin/bash
#
# uninstall-swap.sh
#
# Undoes swap_setup.sh: turns off and removes /swapfile, and removes its
# entry from /etc/fstab so it doesn't try to activate again on next boot.
#
# Usage:
#   sudo ./uninstall-swap.sh
#   sudo ./uninstall-swap.sh --yes   # skip confirmation
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

SWAPFILE="/swapfile"

echo "=== Uninstall Swap File ==="

if [[ ! -f "$SWAPFILE" ]]; then
  echo "[*] Nothing to uninstall - ${SWAPFILE} doesn't exist."
  exit 0
fi

echo "This will:"
echo "  - Turn off swap on ${SWAPFILE} (if active)"
echo "  - Delete ${SWAPFILE}"
echo "  - Remove its entry from /etc/fstab"
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

if swapon --show | grep -q "$SWAPFILE"; then
  echo "[*] Turning off swap..."
  swapoff "$SWAPFILE"
fi

echo "[*] Removing ${SWAPFILE}..."
rm -f "$SWAPFILE"

echo "[*] Removing its /etc/fstab entry..."
sed -i "\|^${SWAPFILE} |d" /etc/fstab

echo
echo "=== Done ==="
echo "Swap file removed."
free -h
