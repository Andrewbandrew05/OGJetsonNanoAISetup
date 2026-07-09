#!/usr/bin/env bash
#
# uninstall-wyoming-whisper.sh
#
# Undoes install-wyoming-whisper.sh: stops/disables/removes the
# wyoming-whisper systemd service and removes /opt/wyoming-whisper. Does
# NOT touch whisper.cpp itself - this only removes the bridge in front of
# it.
#
# Usage:
#   sudo ./uninstall-wyoming-whisper.sh
#   sudo ./uninstall-wyoming-whisper.sh --yes   # skip confirmation
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

BRIDGE_DIR="/opt/wyoming-whisper"

echo "=== Uninstall Wyoming-Whisper Bridge ==="

if [[ ! -f /etc/systemd/system/wyoming-whisper.service && ! -d "$BRIDGE_DIR" ]]; then
  echo "[*] Nothing to uninstall - wyoming-whisper.service and ${BRIDGE_DIR} not found."
  exit 0
fi

echo "This will:"
echo "  - Stop and disable wyoming-whisper.service"
echo "  - Remove /etc/systemd/system/wyoming-whisper.service"
echo "  - Remove ${BRIDGE_DIR} (the bridge's venv and script)"
echo
echo "whisper.cpp itself is untouched - only the Wyoming bridge in front of"
echo "it is removed."
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

echo "[*] Stopping and disabling wyoming-whisper.service..."
systemctl stop wyoming-whisper.service 2>/dev/null || true
systemctl disable wyoming-whisper.service 2>/dev/null || true
rm -f /etc/systemd/system/wyoming-whisper.service
systemctl daemon-reload

echo "[*] Removing bind-mode files..."
rm -f /etc/nano-ai-bind/wyomingwhisper.mode /etc/nano-ai-bind/wyomingwhisper-start.sh
rmdir --ignore-fail-on-non-empty /etc/nano-ai-bind 2>/dev/null || true

echo "[*] Removing ${BRIDGE_DIR}..."
rm -rf "$BRIDGE_DIR"

echo
echo "=== Done ==="
echo "Wyoming-whisper bridge has been uninstalled."
