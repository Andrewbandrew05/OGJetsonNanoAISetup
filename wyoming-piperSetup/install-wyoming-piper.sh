#!/usr/bin/env bash
#
# install-wyoming-piper.sh
#
# Installs Piper TTS (CPU-only) as a Wyoming protocol systemd service.
#
# Why CPU-only: Piper's GPU acceleration path (CUDA-enabled ONNX Runtime)
# only exists for newer JetPack/CUDA builds (Orin-series Jetsons, JetPack 6+).
# The original Jetson Nano's CUDA 10.2 is too old for any current ONNX
# Runtime GPU execution provider, so CPU is the only realistic option on
# this hardware. Piper is CPU-efficient enough that this is still workable
# for short voice-assistant responses.
#
# Why the *old* piper binary, not the new pip package: the actively
# maintained Piper fork (OHF-Voice/piper1-gpl, pip install piper-tts)
# requires glibc 2.28+. Jetson Nano's Ubuntu 18.04 (Bionic) ships glibc
# 2.27 -- one version short. The original rhasspy/piper C++ binary release
# (archived Oct 2025, but still functional and still the backend
# wyoming-piper expects) was built years ago against an older glibc
# baseline and works fine here. See README.md for details.
#
# Why wyoming-piper is pinned to v1.6.3, not main: commit a9bedf7 ("Use
# piper1-gpl") removed the --piper <path> flag entirely and switched
# wyoming-piper to import piper1-gpl as a library instead of shelling out
# to an external binary - which drags the same glibc 2.28+ requirement
# back in. v1.6.3 is the last tag before that change; v2.0.0 is the first
# tag with it. Cloning main (unpinned) will build a service that
# immediately crash-loops with "unrecognized arguments: --piper ...".
#
# Default port: 10200 (real Wyoming protocol - this one IS ready for HA's
# Wyoming integration). Override with WYOMING_PIPER_PORT=10201, or via
# setup.sh: --piperPort=10201
#
# If wyoming-piper.service already exists, this asks before overwriting
# it. Under setup.sh's --bypassAllChecks/--bypassInstallerChecks, it does
# NOT overwrite automatically - it skips and exits 2 instead, which
# setup.sh surfaces as a distinct "already installed" result rather than
# retrying or silently clobbering an existing install. Rerun this script
# directly (without those flags) to be prompted for overwrite.
#
# Binding: defaults to 0.0.0.0 (reachable by anyone on your LAN). Pass
# --tailscale (or set WYOMING_PIPER_BIND_TAILSCALE=1) to bind only the
# Tailscale interface instead - falls back to 127.0.0.1 if tailscale0 never
# comes up, never silently to LAN-wide. Already installed and just want to
# flip modes without a full reinstall? Pass --rebind (with/without
# --tailscale), or use setup.sh --rebindTailscale/--rebindLan.

set -euo pipefail

BIND_TAILSCALE=0
REBIND_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --tailscale) BIND_TAILSCALE=1 ;;
    --rebind) REBIND_ONLY=1 ;;
  esac
done
[[ "${WYOMING_PIPER_BIND_TAILSCALE:-0}" == "1" ]] && BIND_TAILSCALE=1
[[ "${NANO_REBIND_ONLY:-0}" == "1" ]] && REBIND_ONLY=1

PIPER_DIR="/opt/wyoming-piper"
VOICE="en_US-lessac-medium"      # https://rhasspy.github.io/piper-samples/ for other voices
WYOMING_PORT="${WYOMING_PIPER_PORT:-10200}"
SERVICE_USER="${SUDO_USER:-$USER}"

BIND_DIR="/etc/nano-ai-bind"
MODE_FILE="${BIND_DIR}/piper.mode"
WRAPPER="${BIND_DIR}/piper-start.sh"
NEW_MODE="lan"
[[ $BIND_TAILSCALE -eq 1 ]] && NEW_MODE="tailscale"

if [[ $REBIND_ONLY -eq 1 ]]; then
  if [[ ! -f /etc/systemd/system/wyoming-piper.service ]]; then
    echo "[!] wyoming-piper.service isn't installed - nothing to rebind." >&2
    exit 1
  fi
  sudo mkdir -p "$BIND_DIR"
  echo "$NEW_MODE" | sudo tee "$MODE_FILE" > /dev/null
  echo "[*] Set wyoming-piper bind mode to: $NEW_MODE"
  sudo systemctl restart wyoming-piper.service
  echo "[*] Restarted wyoming-piper.service."
  exit 0
fi

if [[ -f /etc/systemd/system/wyoming-piper.service ]]; then
  if [[ "${NANO_SETUP_AUTO_YES:-0}" == "1" || "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
    echo "[!] wyoming-piper.service is already installed."
    echo "[!] Auto-accept flags are active, but overwriting an existing install"
    echo "    is too big a decision for a bypass flag to make silently -"
    echo "    skipping instead."
    echo "[!] wyoming-piper install FAILED: already installed - rerun this"
    echo "    script explicitly, without"
    echo "    --bypassAllChecks/--bypassInstallerChecks, to be prompted for"
    echo "    whether to overwrite it."
    exit 2
  fi
  read -rp "wyoming-piper already appears to be installed. Overwrite/reinstall? [y/N]: " OVERWRITE_CHOICE
  case "${OVERWRITE_CHOICE,,}" in
    y|yes) echo "[*] Proceeding with reinstall..." ;;
    *) echo "Leaving the existing install untouched. Nothing changed."; exit 0 ;;
  esac
fi

echo "==> [1/6] Installing Python 3.9 (required by wyoming-piper; Jetson ships 3.6/3.8 only)"
if ! command -v python3.9 >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y software-properties-common
  sudo add-apt-repository -y ppa:deadsnakes/ppa
  sudo apt update
  sudo apt install -y python3.9 python3.9-venv python3.9-distutils
fi
python3.9 --version

echo "==> [2/6] Setting up ${PIPER_DIR}"
sudo mkdir -p "$PIPER_DIR"
sudo chown "$SERVICE_USER":"$SERVICE_USER" "$PIPER_DIR"

echo "==> [3/6] Downloading Piper prebuilt binary (CPU, aarch64)"
cd "$PIPER_DIR"
if [ ! -x "$PIPER_DIR/piper/piper" ]; then
  wget -O piper.tar.gz https://github.com/rhasspy/piper/releases/latest/download/piper_linux_aarch64.tar.gz
  tar -xzf piper.tar.gz
  rm -f piper.tar.gz
fi
"$PIPER_DIR/piper/piper" --version || echo "  (no --version output -- binary may still be fine, will confirm via wyoming-piper next)"

echo "==> [4/6] Cloning wyoming-piper (pinned to v1.6.3) and setting up its venv with Python 3.9"
cd "$PIPER_DIR"
if [ ! -d "$PIPER_DIR/wyoming-piper/.git" ]; then
  git clone https://github.com/rhasspy/wyoming-piper.git
fi
cd wyoming-piper
git config --global --add safe.directory "$PIPER_DIR/wyoming-piper"
git fetch --tags
git checkout v1.6.3
# Wipe any venv from a previous run against a different (e.g. main/v2.x)
# checkout, so it gets rebuilt against v1.6.3's actual requirements rather
# than possibly keeping stray piper1-gpl/onnxruntime packages around.
rm -rf .venv
python3.9 script/setup

echo "==> [5/6] Checking wyoming-piper's actual CLI flags"
echo "    (confirming exact flag names before wiring up the service --"
echo "     if this differs from what's in the systemd unit below, adjust ExecStart accordingly)"
.venv/bin/python3 -m wyoming_piper --help || .venv/bin/wyoming-piper --help || true

mkdir -p "$PIPER_DIR/data"

# This whole script runs as root (invoked via sudo), so everything created
# under $PIPER_DIR from here on - piper/, wyoming-piper/, data/ - ends up
# root-owned, even though $PIPER_DIR itself was chowned to $SERVICE_USER
# back in step 2. The systemd service below runs as $SERVICE_USER, which
# can still read/execute root-owned files but can't write into a root-owned
# data/ directory - and it needs to, to download the voice model on first
# start. Re-chown everything now to match who actually needs to write here.
chown -R "$SERVICE_USER":"$SERVICE_USER" "$PIPER_DIR"

echo "==> [6/6] Installing bind-mode wrapper + systemd service"
sudo mkdir -p "$BIND_DIR"
echo "$NEW_MODE" | sudo tee "$MODE_FILE" > /dev/null

sudo tee "$WRAPPER" > /dev/null << 'WRAPEOF'
#!/bin/bash
set -e
MODE_FILE="/etc/nano-ai-bind/piper.mode"
MODE=$(cat "$MODE_FILE" 2>/dev/null || echo "lan")
BIND_HOST="0.0.0.0"
if [[ "$MODE" == "tailscale" ]]; then
  BIND_HOST=""
  for i in $(seq 1 30); do
    TS_IP=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
    if [[ -n "$TS_IP" ]]; then
      BIND_HOST="$TS_IP"
      break
    fi
    sleep 2
  done
  if [[ -z "$BIND_HOST" ]]; then
    echo "[piper] tailscale-only bind mode set, but tailscale0 never came up -"
    echo "[piper] falling back to 127.0.0.1 (never silently to LAN-wide)."
    BIND_HOST="127.0.0.1"
  fi
fi
echo "[piper] Binding to ${BIND_HOST}:__PIPER_PORT__"
exec __PIPER_DIR__/wyoming-piper/.venv/bin/python3 -m wyoming_piper --piper __PIPER_DIR__/piper/piper --voice __PIPER_VOICE__ --uri "tcp://${BIND_HOST}:__PIPER_PORT__" --data-dir __PIPER_DIR__/data --download-dir __PIPER_DIR__/data
WRAPEOF
sudo sed -i "s|__PIPER_PORT__|${WYOMING_PORT}|g; s|__PIPER_DIR__|${PIPER_DIR}|g; s|__PIPER_VOICE__|${VOICE}|g" "$WRAPPER"
sudo chmod +x "$WRAPPER"

sudo tee /etc/systemd/system/wyoming-piper.service > /dev/null << EOF
[Unit]
Description=Wyoming protocol Piper TTS server (CPU)
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${PIPER_DIR}/wyoming-piper
ExecStart=${WRAPPER}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now wyoming-piper.service
sleep 3

echo ""
echo "==> Service status:"
sudo systemctl status wyoming-piper.service --no-pager || true

if [[ "$NEW_MODE" == "tailscale" ]]; then
  echo "Bind mode: Tailscale-only (falls back to 127.0.0.1 if tailscale0 isn't up)"
else
  echo "Bind mode: LAN-wide (tcp://0.0.0.0:${WYOMING_PORT} - reachable by anyone on your LAN)"
fi
echo "Flip it later without a full reinstall: sudo ./install-wyoming-piper.sh --rebind [--tailscale]"
echo "or: sudo ./setup.sh --rebindTailscale / --rebindLan"

echo ""
echo "If the service failed to start, check 'journalctl -u wyoming-piper.service -n 50'"
echo "-- the most likely cause is the --piper/--voice flag names differing from what"
echo "the --help output above showed. Adjust the ExecStart line in"
echo "${WRAPPER} to match, then:"
echo "  sudo systemctl restart wyoming-piper.service"
