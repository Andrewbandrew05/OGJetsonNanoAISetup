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
# By default, this ends by running `tailscale up` interactively - it prints
# a login URL and waits (blocks) until you open it and authenticate. That's
# intentional: it's meant to be the last step of an unattended setup.sh run,
# so it's the one thing left on screen when you come back.
#
# Before that, it waits for you to press Enter first. The auth link expires
# after a few minutes - if this runs unattended and nobody's watching right
# when it's generated, the link goes stale before anyone sees it. Pressing
# Enter is the signal that someone's actually here and ready to click it
# immediately, so the link only gets generated once that's true.
#
# To fully automate auth too (e.g. scripted provisioning), set:
#   TAILSCALE_AUTHKEY=tskey-...      pre-generated auth key, runs non-interactively
#   TAILSCALE_UP_ARGS="--ssh --advertise-exit-node"   extra flags passed to `tailscale up`
#   TAILSCALE_SKIP_UP=1               skip `tailscale up` entirely, just install+enable
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

if [[ "${TAILSCALE_SKIP_UP:-0}" == "1" ]]; then
  echo "TAILSCALE_SKIP_UP=1 set - not running 'tailscale up'."
  echo "Next step: authenticate this device by running:"
  echo "    sudo tailscale up"
  echo
  echo "Optional flags you may want:"
  echo "    sudo tailscale up --ssh                 # let Tailscale manage SSH access too"
  echo "    sudo tailscale up --advertise-exit-node # use this Nano as an exit node"
  exit 0
fi

# shellcheck disable=SC2206
UP_ARGS=(${TAILSCALE_UP_ARGS:-})

if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
  echo "[*] TAILSCALE_AUTHKEY set - authenticating non-interactively..."
  tailscale up --authkey="${TAILSCALE_AUTHKEY}" "${UP_ARGS[@]}"
else
  # The auth link tailscale up prints expires after a few minutes. If this
  # ran unattended (e.g. as the last step of setup.sh) and nobody was
  # watching right when it printed, the link goes stale before anyone
  # sees it - which is exactly what happened testing this script. Pausing
  # here means the link only gets generated once someone's actually
  # present and ready to click it immediately, regardless of how long the
  # rest of the run took to get here.
  printf '\n\nPlease hit the enter key to initialize tailscale login procedure. This part of the script requires timely action to prevent link expiration: '
  read -r _

  echo "Running 'tailscale up' now - open the login URL below in a browser to"
  echo "authenticate this device. This will wait here until login completes."
  echo
  tailscale up "${UP_ARGS[@]}"
fi

echo
echo "[*] Tailscale authenticated:"
tailscale status
