#!/usr/bin/env bash
#
# uninstall-whisper-cpp.sh
#
# Undoes install-whisper-cpp.sh: stops/disables/removes the
# whisper-cpp-server systemd service and removes /opt/whisper.cpp (source,
# build, and the downloaded model - all together, there's no separate
# cache location to think about here).
#
# Usage:
#   sudo ./uninstall-whisper-cpp.sh
#   sudo ./uninstall-whisper-cpp.sh --yes   # skip confirmation
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

WHISPER_DIR="/opt/whisper.cpp"

echo "=== Uninstall whisper.cpp ==="

if [[ ! -f /etc/systemd/system/whisper-cpp-server.service && ! -d "$WHISPER_DIR" ]]; then
  echo "[*] Nothing to uninstall - whisper-cpp-server.service and ${WHISPER_DIR} not found."
  exit 0
fi

echo "This will:"
echo "  - Stop and disable whisper-cpp-server.service"
echo "  - Remove /etc/systemd/system/whisper-cpp-server.service"
echo "  - Remove ${WHISPER_DIR} (source, build, and the downloaded model)"
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

echo "[*] Stopping and disabling whisper-cpp-server.service..."
systemctl stop whisper-cpp-server.service 2>/dev/null || true
systemctl disable whisper-cpp-server.service 2>/dev/null || true
rm -f /etc/systemd/system/whisper-cpp-server.service
systemctl daemon-reload

echo "[*] Removing ${WHISPER_DIR}..."
rm -rf "$WHISPER_DIR"

echo
echo "=== Done ==="
echo "whisper.cpp has been uninstalled."
echo
echo "Note: if the Wyoming-whisper bridge (wyoming-whisperSetup) is also"
echo "installed, it depends on this server and won't have anything to"
echo "forward requests to anymore - uninstall it too if you're removing this."
