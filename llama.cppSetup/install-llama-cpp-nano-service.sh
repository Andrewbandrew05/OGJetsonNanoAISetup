#!/bin/bash
# Installs kreier/llama.cpp-jetson.nano (precompiled CUDA build) and sets up
# llama-server as a systemd service that starts on boot and restarts on failure.
#
# Usage:
#   chmod +x install-llama-cpp-nano-service.sh
#   ./install-llama-cpp-nano-service.sh
#
# Run as your normal user (not root) — it will sudo internally where needed.
#
# Default port: 8081 (http://<nano-ip>:8081, OpenAI-compatible API + web UI).
# Override with: LLAMA_SERVICE_PORT=9000 ./install-llama-cpp-nano-service.sh
# Via setup.sh: --llamaPort=9000

set -euo pipefail

SERVICE_USER="${SUDO_USER:-$(whoami)}"
# Deliberately NOT 8080 by default, to avoid clashing with the whisper.cpp
# server already bound to 127.0.0.1:8080. Override with LLAMA_SERVICE_PORT.
SERVICE_PORT="${LLAMA_SERVICE_PORT:-8081}"
MODEL_HF="ggml-org/gemma-3-1b-it-GGUF"

echo "=== Step 1: Ensuring curl is installed ==="
# Not every JetPack image ships curl by default - don't assume it's there.
if ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y curl
fi

echo "=== Step 2: Installing llama.cpp binaries (gcc 8.5 CUDA build) ==="
curl -fsSL https://kreier.github.io/llama.cpp-jetson.nano/install.sh | bash

# Reload the current shell's rc so `llama-server`/`llama-cli` are on PATH
# for the rest of this script (systemd will get its own env below).
# shellcheck disable=SC1090
source "$HOME/.bashrc" || true

echo "=== Step 3: Confirming binaries installed ==="
if ! command -v llama-server >/dev/null 2>&1; then
    echo "ERROR: llama-server not found on PATH after install. Aborting."
    exit 1
fi
llama-server --version || true

echo "=== Step 4: Creating systemd service ==="
sudo tee /etc/systemd/system/llama-cpp-server.service > /dev/null << EOF
[Unit]
Description=llama.cpp CUDA server (Jetson Nano, gcc8.5 build)
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Environment="LD_LIBRARY_PATH=/usr/local/lib"
ExecStart=/usr/local/bin/llama-server -hf ${MODEL_HF} --n-gpu-layers 99 --host 0.0.0.0 --port ${SERVICE_PORT}
Restart=on-failure
RestartSec=5
# The very first run downloads + converts the model (can take several
# minutes on Jetson Nano). Give systemd a long leash so it doesn't kill
# the service mid-download and loop-crash.
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF

echo "=== Step 5: Enabling and starting the service ==="
sudo systemctl daemon-reload
sudo systemctl enable llama-cpp-server.service
sudo systemctl start llama-cpp-server.service

echo ""
echo "=== Done ==="
echo "Service installed as: llama-cpp-server.service"
echo "Listening on: http://0.0.0.0:${SERVICE_PORT}"
echo ""
echo "NOTE: first startup will take several minutes while the model downloads"
echo "and converts. Watch progress with:"
echo "  sudo journalctl -u llama-cpp-server.service -f"
echo ""
echo "Once running, open http://<jetson-ip>:${SERVICE_PORT} in a browser for the web UI."
