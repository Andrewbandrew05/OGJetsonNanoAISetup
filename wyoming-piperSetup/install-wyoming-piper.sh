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

set -euo pipefail

PIPER_DIR="/opt/wyoming-piper"
VOICE="en_US-lessac-medium"      # https://rhasspy.github.io/piper-samples/ for other voices
WYOMING_PORT="${WYOMING_PIPER_PORT:-10200}"
SERVICE_USER="${SUDO_USER:-$USER}"

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

echo "==> [6/6] Installing systemd service"
sudo tee /etc/systemd/system/wyoming-piper.service > /dev/null << EOF
[Unit]
Description=Wyoming protocol Piper TTS server (CPU)
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${PIPER_DIR}/wyoming-piper
ExecStart=${PIPER_DIR}/wyoming-piper/.venv/bin/python3 -m wyoming_piper --piper ${PIPER_DIR}/piper/piper --voice ${VOICE} --uri tcp://0.0.0.0:${WYOMING_PORT} --data-dir ${PIPER_DIR}/data --download-dir ${PIPER_DIR}/data
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

echo ""
echo "If the service failed to start, check 'journalctl -u wyoming-piper.service -n 50'"
echo "-- the most likely cause is the --piper/--voice flag names differing from what"
echo "the --help output above showed. Adjust the ExecStart line in"
echo "/etc/systemd/system/wyoming-piper.service to match, then:"
echo "  sudo systemctl daemon-reload && sudo systemctl restart wyoming-piper.service"
