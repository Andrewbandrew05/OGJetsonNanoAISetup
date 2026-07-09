#!/usr/bin/env bash
#
# install-wyoming-whisper.sh
#
# Installs a small Wyoming-protocol bridge in front of the EXISTING
# whisper.cpp HTTP server (installed by whisper.cppSetup/install-whisper-cpp.sh).
#
# This does NOT install a second whisper model. whisper.cpp's own server
# exposes a plain REST endpoint (see whisper.cppSetup/README.md), not the
# Wyoming protocol Home Assistant's Wyoming integration expects - this
# bridge just forwards whatever audio HA streams to it straight to that
# already-running server's /inference endpoint and relays the
# transcription back, so there's exactly one whisper model/process on the
# box, never two.
#
# MUST run after whisper.cppSetup/install-whisper-cpp.sh - there is
# nothing to transcribe with otherwise. In setup.sh's --installAll and
# --installModels packages, this is wired in right after whisper.cpp
# automatically. The systemd unit below also declares
# After=/Wants=whisper-cpp-server.service as a second layer of ordering.
#
# Default port: 10300 (Wyoming protocol). Override with
# WYOMING_WHISPER_PORT=10301, or via setup.sh: --wyomingWhisperPort=10301
#
# Points at whisper.cpp's server using WHISPER_SERVER_PORT (the same env
# var whisper.cppSetup/install-whisper-cpp.sh reads) if set, else 8080 -
# so if you customized whisper.cpp's port, this picks it up automatically
# without needing to be told twice.
#
# Usage:
#   sudo ./install-wyoming-whisper.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

BRIDGE_DIR="/opt/wyoming-whisper"
SERVICE_USER="${SUDO_USER:-$USER}"
WYOMING_PORT="${WYOMING_WHISPER_PORT:-10300}"
WHISPER_PORT="${WHISPER_SERVER_PORT:-8080}"
WHISPER_URL="http://127.0.0.1:${WHISPER_PORT}/inference"

# If wyoming-whisper.service already exists, ask before overwriting it.
# Under setup.sh's --bypassAllChecks/--bypassInstallerChecks, this does
# NOT overwrite automatically - it skips and exits 2 instead, which
# setup.sh surfaces as a distinct "already installed" result rather than
# retrying or silently clobbering an existing install. Rerun this script
# directly (without those flags) to be prompted for overwrite.
if [[ -f /etc/systemd/system/wyoming-whisper.service ]]; then
  if [[ "${NANO_SETUP_AUTO_YES:-0}" == "1" || "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
    echo "[!] wyoming-whisper.service is already installed."
    echo "[!] Auto-accept flags are active, but overwriting an existing install"
    echo "    is too big a decision for a bypass flag to make silently -"
    echo "    skipping instead."
    echo "[!] Wyoming-whisper bridge install FAILED: already installed - rerun"
    echo "    this script explicitly, without"
    echo "    --bypassAllChecks/--bypassInstallerChecks, to be prompted for"
    echo "    whether to overwrite it."
    exit 2
  fi
  read -rp "Wyoming-whisper bridge already appears to be installed. Overwrite/reinstall? [y/N]: " OVERWRITE_CHOICE
  case "${OVERWRITE_CHOICE,,}" in
    y|yes) echo "[*] Proceeding with reinstall..." ;;
    *) echo "Leaving the existing install untouched. Nothing changed."; exit 0 ;;
  esac
fi

echo "=== Wyoming-Whisper Bridge Install ==="

echo "[*] Checking whether whisper.cpp's own server is up..."
if ! systemctl is-active --quiet whisper-cpp-server.service 2>/dev/null; then
  echo "[!] whisper-cpp-server.service isn't active yet."
  echo "    This bridge will still install and start, but can't transcribe"
  echo "    anything until whisper.cpp itself is running. If you haven't"
  echo "    already, run: sudo ./whisper.cppSetup/install-whisper-cpp.sh"
fi

echo "[*] Checking for Python 3.9 (shared with wyoming-piper)..."
if ! command -v python3.9 >/dev/null 2>&1; then
  echo "ERROR: python3.9 not found on PATH."
  echo "Run CoreSystemSetup/Python39Upgrade/python39_upgrade.sh first."
  exit 1
fi
python3.9 --version

echo "[*] Setting up ${BRIDGE_DIR}..."
mkdir -p "$BRIDGE_DIR"
chown "$SERVICE_USER":"$SERVICE_USER" "$BRIDGE_DIR"

echo "[*] Creating Python venv and installing dependencies (wyoming, requests)..."
sudo -u "$SERVICE_USER" python3.9 -m venv "${BRIDGE_DIR}/.venv"
"${BRIDGE_DIR}/.venv/bin/pip" install --upgrade pip
"${BRIDGE_DIR}/.venv/bin/pip" install wyoming requests

echo "[*] Installing bridge script..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "${SCRIPT_DIR}/wyoming_whisper_bridge.py" "${BRIDGE_DIR}/wyoming_whisper_bridge.py"
chown "$SERVICE_USER":"$SERVICE_USER" "${BRIDGE_DIR}/wyoming_whisper_bridge.py"

echo "[*] Installing systemd service..."
cat > /etc/systemd/system/wyoming-whisper.service <<EOF
[Unit]
Description=Wyoming protocol bridge for whisper.cpp
After=network.target whisper-cpp-server.service
Wants=whisper-cpp-server.service

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${BRIDGE_DIR}
ExecStart=${BRIDGE_DIR}/.venv/bin/python3 ${BRIDGE_DIR}/wyoming_whisper_bridge.py --uri tcp://0.0.0.0:${WYOMING_PORT} --whisper-url ${WHISPER_URL}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wyoming-whisper.service
sleep 2

echo
echo "=== Service status ==="
systemctl status wyoming-whisper.service --no-pager || true

echo
echo "=== Done ==="
echo "Wyoming STT bridge listening on tcp://0.0.0.0:${WYOMING_PORT}"
echo "Forwarding transcription requests to: ${WHISPER_URL}"
echo
echo "Add it in Home Assistant: Settings > Devices & Services > Add"
echo "Integration > Wyoming Protocol, host=<nano-ip>, port=${WYOMING_PORT}"
echo
echo "If it's not transcribing, check both services:"
echo "  sudo systemctl status whisper-cpp-server.service wyoming-whisper.service --no-pager"
echo "  sudo journalctl -u wyoming-whisper.service -n 50"
