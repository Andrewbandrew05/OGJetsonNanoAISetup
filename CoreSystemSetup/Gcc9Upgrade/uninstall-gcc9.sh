#!/bin/bash
#
# uninstall-gcc9.sh
#
# Undoes gcc9_upgrade.sh: removes gcc-9/g++-9 via apt, and removes the
# ubuntu-toolchain-r/test PPA that provided them.
#
# Usage:
#   sudo ./uninstall-gcc9.sh
#   sudo ./uninstall-gcc9.sh --yes   # skip confirmation
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

echo "=== Uninstall gcc-9 / g++-9 ==="

if ! command -v gcc-9 >/dev/null 2>&1 && ! command -v g++-9 >/dev/null 2>&1; then
  echo "[*] Nothing to uninstall - gcc-9/g++-9 aren't installed."
  exit 0
fi

echo "This will:"
echo "  - Remove gcc-9 and g++-9 via apt"
echo "  - Remove the ubuntu-toolchain-r/test PPA that provided them"
echo
echo "Note: whisper.cpp was built with this compiler - it'll keep running"
echo "fine (the binary doesn't need gcc-9 present at runtime), but you"
echo "won't be able to rebuild it without reinstalling gcc-9 first."
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

echo "[*] Removing gcc-9/g++-9..."
# Deliberately just these two named packages, not apt-get autoremove
# afterward - autoremove hands control to apt's dependency solver to
# decide what else looks "no longer needed" system-wide, which is exactly
# the mechanism that cascaded into removing boot-critical packages
# elsewhere in this project (see CoreSystemSetup/GuiRemoval's comments).
# Not worth that risk here for reclaiming a small amount of disk space.
DEBIAN_FRONTEND=noninteractive apt-get remove -y gcc-9 g++-9 || true

echo "[*] Removing the ubuntu-toolchain-r/test PPA..."
if command -v add-apt-repository >/dev/null 2>&1; then
  add-apt-repository --remove -y ppa:ubuntu-toolchain-r/test || true
fi

echo
echo "=== Done ==="
echo "gcc-9/g++-9 have been uninstalled."
