#!/bin/bash
#
# uninstall-tailscale.sh
#
# Undoes tailscale_install.sh: logs this device out of your tailnet,
# stops/disables tailscaled, removes the tailscale package, and removes
# the apt repo the official install script added.
#
# Usage:
#   sudo ./uninstall-tailscale.sh
#   sudo ./uninstall-tailscale.sh --yes   # skip confirmation
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

echo "=== Uninstall Tailscale ==="

if ! command -v tailscale >/dev/null 2>&1; then
  echo "[*] Nothing to uninstall - tailscale isn't installed."
  exit 0
fi

echo "This will:"
echo "  - Log this device out of your tailnet"
echo "  - Stop and disable tailscaled"
echo "  - Remove the tailscale package"
echo "  - Remove the apt repo the official install script added"
echo
echo "Note: the backup + control API binds to the Tailscale interface and"
echo "falls back to 127.0.0.1 if it's gone - if that's installed, its API"
echo "will only be reachable locally afterward."
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

echo "[*] Logging out of the tailnet..."
tailscale logout 2>/dev/null || true

echo "[*] Stopping and disabling tailscaled..."
systemctl stop tailscaled 2>/dev/null || true
systemctl disable tailscaled 2>/dev/null || true

echo "[*] Removing the tailscale package..."
# Deliberately just this one named package, not apt-get autoremove
# afterward - see the note in CoreSystemSetup/Gcc9Upgrade/uninstall-gcc9.sh
# for why that's avoided throughout this project.
DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y tailscale || true

echo "[*] Removing the tailscale apt repo..."
rm -f /etc/apt/sources.list.d/tailscale.list
rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg

echo
echo "=== Done ==="
echo "Tailscale has been uninstalled."
