#!/usr/bin/env bash
#
# uninstall-wyoming-piper.sh
#
# Undoes install-wyoming-piper.sh: stops/disables/removes the
# wyoming-piper systemd service and removes /opt/wyoming-piper (the piper
# binary, the wyoming-piper venv, and downloaded voice data - all
# together).
#
# Usage:
#   sudo ./uninstall-wyoming-piper.sh
#   sudo ./uninstall-wyoming-piper.sh --yes   # skip confirmation
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

PIPER_DIR="/opt/wyoming-piper"

echo "=== Uninstall wyoming-piper ==="

if [[ ! -f /etc/systemd/system/wyoming-piper.service && ! -d "$PIPER_DIR" ]]; then
  echo "[*] Nothing to uninstall - wyoming-piper.service and ${PIPER_DIR} not found."
  exit 0
fi

echo "This will:"
echo "  - Stop and disable wyoming-piper.service"
echo "  - Remove /etc/systemd/system/wyoming-piper.service"
echo "  - Remove ${PIPER_DIR} (piper binary, venv, and downloaded voice data)"
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

echo "[*] Stopping and disabling wyoming-piper.service..."
systemctl stop wyoming-piper.service 2>/dev/null || true
systemctl disable wyoming-piper.service 2>/dev/null || true
rm -f /etc/systemd/system/wyoming-piper.service
systemctl daemon-reload

echo "[*] Removing ${PIPER_DIR}..."
rm -rf "$PIPER_DIR"

echo
echo "=== Done ==="
echo "wyoming-piper has been uninstalled."
