#!/bin/bash
#
# swap_setup.sh
#
# Creates a 4GB persistent swap file on a Jetson Nano.
#
# Usage:
#   chmod +x swap_setup.sh
#   sudo ./swap_setup.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

SWAPFILE="/swapfile"
SWAPSIZE_GB=4

echo "=== Jetson Nano Swap File Setup ==="

if swapon --show | grep -q "$SWAPFILE"; then
  echo "[*] $SWAPFILE is already active as swap. Skipping swap creation."
elif [[ -f "$SWAPFILE" ]]; then
  echo "[!] $SWAPFILE already exists but isn't active. Activating it..."
  chmod 600 "$SWAPFILE"
  swapon "$SWAPFILE"
else
  echo "[*] Creating ${SWAPSIZE_GB}GB swap file at $SWAPFILE..."
  # fallocate is fast but not always supported on the Nano's filesystem;
  # fall back to dd if it fails.
  if ! fallocate -l "${SWAPSIZE_GB}G" "$SWAPFILE" 2>/dev/null; then
    echo "    fallocate unavailable, using dd instead (slower)..."
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAPSIZE_GB * 1024)) status=progress
  fi

  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"

  # Persist across reboots
  if ! grep -q "^${SWAPFILE} " /etc/fstab; then
    echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
    echo "[*] Added $SWAPFILE entry to /etc/fstab."
  fi
fi

echo "[*] Current swap status:"
swapon --show
free -h

echo
echo "=== Done ==="
echo "Swap file: $SWAPFILE (${SWAPSIZE_GB}GB), persistent via /etc/fstab"
