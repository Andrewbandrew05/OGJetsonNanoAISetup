#!/bin/bash
#
# tailscale_install.sh
#
# Installs Tailscale on a Jetson Nano (aarch64) via the official install
# script, enables the service, and starts the login flow.
#
# Usage:
#   chmod +x tailscale_install.sh
#   sudo ./tailscale_install.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "=== Tailscale Install ==="

echo "[*] Installing prerequisites..."
apt-get update -y
apt-get install -y curl

echo "[*] Running official Tailscale install script..."
curl -fsSL https://tailscale.com/install.sh | sh

echo "[*] Enabling and starting the tailscaled service..."
systemctl enable --now tailscaled

echo
echo "=== Tailscale installed ==="
echo "Next step: authenticate this device by running:"
echo "    sudo tailscale up"
echo
echo "This will print a URL — open it in a browser to log in and add this"
echo "Nano to your tailnet. Optional flags you may want:"
echo "    sudo tailscale up --ssh                 # let Tailscale manage SSH access too"
echo "    sudo tailscale up --advertise-exit-node # use this Nano as an exit node"
