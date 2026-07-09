#!/bin/bash
#
# system_upgrade.sh
#
# Runs a routine apt update + upgrade to bring already-installed packages
# up to date.
#
# Deliberately uses `apt-get upgrade`, not `dist-upgrade`/`full-upgrade`:
# plain `upgrade` only updates packages that are already installed, within
# their current dependency constraints, and never removes a package or
# pulls in a new one to satisfy a changed dependency chain. `dist-upgrade`
# can do both of those things, which is exactly the category of surprise
# this project has spent a lot of effort avoiding elsewhere (see
# CoreSystemSetup/GuiRemoval's comments) - not worth the risk here for a
# routine update step.
#
# Usage:
#   sudo ./system_upgrade.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "=== System Package Update/Upgrade ==="

echo "[*] Updating package lists..."
apt-get update -y

echo "[*] Upgrading installed packages..."
apt-get upgrade -y

echo
echo "=== Done ==="
echo "If a new kernel or core library was upgraded, a reboot may be needed"
echo "for it to fully take effect: sudo reboot"
