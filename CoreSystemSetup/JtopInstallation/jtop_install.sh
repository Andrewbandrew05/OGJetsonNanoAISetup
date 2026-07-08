#!/bin/bash
#
# jtop_install.sh
#
# Installs jtop (jetson-stats) on a Jetson Nano.
#
# Usage:
#   chmod +x jtop_install.sh
#   sudo ./jtop_install.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "=== jtop (jetson-stats) Install ==="

echo "[*] Installing prerequisites..."
apt-get update -y
apt-get install -y python3-pip

echo "[*] Installing jetson-stats (jtop)..."
pip3 install -U jetson-stats

# jtop needs the invoking (non-root) user in the 'jtop' group to run without sudo.
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [[ -n "$TARGET_USER" ]]; then
  if getent group jtop > /dev/null 2>&1; then
    usermod -aG jtop "$TARGET_USER"
    echo "[*] Added user '$TARGET_USER' to the 'jtop' group."
  fi
fi

echo
echo "=== Done ==="
echo "Log out/in or reboot for group membership to take effect, then run: jtop"
