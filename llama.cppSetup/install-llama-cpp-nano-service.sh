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
#
# Default model: Qwen2.5-1.5B-Instruct - noticeably more reliable at
# instruction-following and tool-calling than the original 1B Gemma default,
# while still fitting comfortably in ~1GB and running at a similar speed on
# this hardware. Override with: LLAMA_MODEL_HF=some-org/some-model-GGUF
#
# The server reports itself via --alias as a clean name derived from
# MODEL_HF (e.g. "Qwen2.5-1.5B-Instruct" instead of the full local cache
# file path) in /v1/models and completion responses - this is computed
# automatically from whatever MODEL_HF is set to, so it always matches
# without needing a separate manual update if you change models.
#
# If llama-cpp-server.service already exists, this asks before overwriting
# it (rebuilding means redownloading the CUDA binaries and re-fetching the
# model). Under setup.sh's --bypassAllChecks/--bypassInstallerChecks, it
# does NOT overwrite automatically - it skips and exits 2 instead, which
# setup.sh surfaces as a distinct "already installed" result rather than
# retrying or silently clobbering an existing install. Rerun this script
# directly (without those flags) to be prompted for overwrite.
#
# Binding: defaults to 0.0.0.0 (reachable by anyone on your LAN). Pass
# --tailscale (or set LLAMA_BIND_TAILSCALE=1) to bind only the Tailscale
# interface instead - falls back to 127.0.0.1 if tailscale0 never comes up,
# never silently to LAN-wide. Already installed and just want to flip
# between the two without a full reinstall (which redownloads the model)?
# Pass --rebind alongside --tailscale or on its own - see
# --rebind's own comment below, or use setup.sh --rebindTailscale/--rebindLan.

set -euo pipefail

BIND_TAILSCALE=0
REBIND_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --tailscale) BIND_TAILSCALE=1 ;;
    --rebind) REBIND_ONLY=1 ;;
  esac
done
[[ "${LLAMA_BIND_TAILSCALE:-0}" == "1" ]] && BIND_TAILSCALE=1
[[ "${NANO_REBIND_ONLY:-0}" == "1" ]] && REBIND_ONLY=1

SERVICE_USER="${SUDO_USER:-$(whoami)}"
# Deliberately NOT 8080 by default, to avoid clashing with the whisper.cpp
# server already bound to 127.0.0.1:8080. Override with LLAMA_SERVICE_PORT.
SERVICE_PORT="${LLAMA_SERVICE_PORT:-8081}"
MODEL_HF="${LLAMA_MODEL_HF:-Qwen/Qwen2.5-1.5B-Instruct-GGUF}"
# Clean display name for llama-server's --alias flag, so /v1/models and
# completion responses report e.g. "Qwen2.5-1.5B-Instruct" instead of the
# full local cache file path - derived from MODEL_HF so it automatically
# tracks whatever model is actually configured, current or future.
MODEL_ALIAS="${MODEL_HF##*/}"
MODEL_ALIAS="${MODEL_ALIAS%-GGUF}"
MODEL_ALIAS="${MODEL_ALIAS%-gguf}"

BIND_DIR="/etc/nano-ai-bind"
MODE_FILE="${BIND_DIR}/llama.mode"
WRAPPER="${BIND_DIR}/llama-start.sh"
NEW_MODE="lan"
[[ $BIND_TAILSCALE -eq 1 ]] && NEW_MODE="tailscale"

# --rebind: already installed and just want to flip LAN-wide <-> Tailscale-
# only? Skip the entire reinstall/overwrite-prompt flow below - just rewrite
# the mode file the wrapper script reads and restart the service.
if [[ $REBIND_ONLY -eq 1 ]]; then
  if [[ ! -f /etc/systemd/system/llama-cpp-server.service ]]; then
    echo "[!] llama-cpp-server.service isn't installed - nothing to rebind." >&2
    exit 1
  fi
  sudo mkdir -p "$BIND_DIR"
  echo "$NEW_MODE" | sudo tee "$MODE_FILE" > /dev/null
  echo "[*] Set llama.cpp bind mode to: $NEW_MODE"
  sudo systemctl restart llama-cpp-server.service
  echo "[*] Restarted llama-cpp-server.service."
  exit 0
fi

if [[ -f /etc/systemd/system/llama-cpp-server.service ]]; then
  if [[ "${NANO_SETUP_AUTO_YES:-0}" == "1" || "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
    echo "[!] llama-cpp-server.service is already installed."
    echo "[!] Auto-accept flags are active, but overwriting an existing install"
    echo "    (redownloading binaries, re-fetching the model) is too big a"
    echo "    decision for a bypass flag to make silently - skipping instead."
    echo "[!] llama.cpp install FAILED: already installed - rerun this script"
    echo "    explicitly, without --bypassAllChecks/--bypassInstallerChecks, to"
    echo "    be prompted for whether to overwrite it."
    exit 2
  fi
  read -rp "llama.cpp already appears to be installed. Overwrite/reinstall? [y/N]: " OVERWRITE_CHOICE
  case "${OVERWRITE_CHOICE,,}" in
    y|yes) echo "[*] Proceeding with reinstall..." ;;
    *) echo "Leaving the existing install untouched. Nothing changed."; exit 0 ;;
  esac
fi

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

echo "=== Step 4: Creating bind-mode wrapper + systemd service ==="
sudo mkdir -p "$BIND_DIR"
echo "$NEW_MODE" | sudo tee "$MODE_FILE" > /dev/null

sudo tee "$WRAPPER" > /dev/null << 'WRAPEOF'
#!/bin/bash
set -e
MODE_FILE="/etc/nano-ai-bind/llama.mode"
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
    echo "[llama] tailscale-only bind mode set, but tailscale0 never came up -"
    echo "[llama] falling back to 127.0.0.1 (never silently to LAN-wide)."
    BIND_HOST="127.0.0.1"
  fi
fi
echo "[llama] Binding to ${BIND_HOST}:__LLAMA_PORT__"
# --jinja is required for any client that sends a "tools" param (e.g. Home
# Assistant's Extended OpenAI Conversation, for function-calling/device
# control) - without it llama-server rejects those requests outright with
# a 500 ("tools param requires --jinja flag") before generating anything.
exec /usr/local/bin/llama-server -hf __LLAMA_MODEL_HF__ --alias "__LLAMA_MODEL_ALIAS__" --n-gpu-layers 99 --jinja --host "$BIND_HOST" --port __LLAMA_PORT__
WRAPEOF
sudo sed -i "s|__LLAMA_PORT__|${SERVICE_PORT}|g; s|__LLAMA_MODEL_HF__|${MODEL_HF}|g; s|__LLAMA_MODEL_ALIAS__|${MODEL_ALIAS}|g" "$WRAPPER"
sudo chmod +x "$WRAPPER"

sudo tee /etc/systemd/system/llama-cpp-server.service > /dev/null << EOF
[Unit]
Description=llama.cpp CUDA server (Jetson Nano, gcc8.5 build)
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Environment="LD_LIBRARY_PATH=/usr/local/lib"
ExecStart=${WRAPPER}
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
echo "Model: ${MODEL_HF} (reports itself as \"${MODEL_ALIAS}\" via --alias)"
if [[ "$NEW_MODE" == "tailscale" ]]; then
  echo "Bind mode: Tailscale-only (falls back to 127.0.0.1 if tailscale0 isn't up)"
else
  echo "Bind mode: LAN-wide (http://0.0.0.0:${SERVICE_PORT} - reachable by anyone on your LAN)"
fi
echo "Flip it later without a full reinstall: sudo ./install-llama-cpp-nano-service.sh --rebind [--tailscale]"
echo "or: sudo ./setup.sh --rebindTailscale / --rebindLan"
echo ""
echo "NOTE: first startup will take several minutes while the model downloads"
echo "and converts. Watch progress with:"
echo "  sudo journalctl -u llama-cpp-server.service -f"
echo ""
echo "Once running, open http://<jetson-ip>:${SERVICE_PORT} in a browser for the web UI."
