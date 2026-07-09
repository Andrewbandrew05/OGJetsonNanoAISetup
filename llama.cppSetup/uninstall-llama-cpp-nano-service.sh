#!/bin/bash
#
# uninstall-llama-cpp-nano-service.sh
#
# Undoes install-llama-cpp-nano-service.sh: stops/disables/removes the
# llama-cpp-server systemd service and the binaries/libraries it installed
# to /usr/local/bin and /usr/local/lib.
#
# The downloaded model (gemma-3-1b-it-GGUF, several GB) lives in
# ~/.cache/llama.cpp for whichever user the service ran as - removing that
# is a separate, explicit confirmation since it's a bigger and more
# clearly-irreversible deletion than the service itself.
#
# Usage:
#   sudo ./uninstall-llama-cpp-nano-service.sh
#   sudo ./uninstall-llama-cpp-nano-service.sh --yes   # skip confirmations
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

AUTO_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=1 ;;
  esac
done
if [[ "${NANO_SETUP_AUTO_YES:-0}" == "1" || "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
  AUTO_YES=1
fi

SERVICE_USER="${SUDO_USER:-$(whoami)}"
USER_HOME=$(eval echo "~${SERVICE_USER}")
MODEL_CACHE="${USER_HOME}/.cache/llama.cpp"

BINARIES=(llama-cli llama-server llama-bench llama-run llama-simple llama-simple-chat)
LIBS=(libllama.so libggml.so libggml-base.so libggml-cpu.so libggml-cuda.so)

echo "=== Uninstall llama.cpp ==="

FOUND_ANYTHING=0
[[ -f /etc/systemd/system/llama-cpp-server.service ]] && FOUND_ANYTHING=1
for b in "${BINARIES[@]}"; do [[ -f "/usr/local/bin/$b" ]] && FOUND_ANYTHING=1; done

if [[ $FOUND_ANYTHING -eq 0 ]]; then
  echo "[*] Nothing to uninstall - no llama-cpp-server.service or binaries found."
  exit 0
fi

echo "This will:"
echo "  - Stop and disable llama-cpp-server.service"
echo "  - Remove /etc/systemd/system/llama-cpp-server.service"
echo "  - Remove installed binaries: ${BINARIES[*]} (from /usr/local/bin)"
echo "  - Remove installed libraries: ${LIBS[*]} (from /usr/local/lib)"
echo
echo "It will NOT remove the downloaded model - that's asked separately below."
echo

if [[ $AUTO_YES -eq 1 ]]; then
  echo "Continue? Type 'yes' to proceed: yes (auto-accepted)"
else
  read -rp "Continue? Type 'yes' to proceed: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "[*] Stopping and disabling llama-cpp-server.service..."
systemctl stop llama-cpp-server.service 2>/dev/null || true
systemctl disable llama-cpp-server.service 2>/dev/null || true
rm -f /etc/systemd/system/llama-cpp-server.service
systemctl daemon-reload

echo "[*] Removing binaries and libraries..."
for b in "${BINARIES[@]}"; do
  if [[ -f "/usr/local/bin/$b" ]]; then
    rm -f "/usr/local/bin/$b"
    echo "    Removed /usr/local/bin/$b"
  fi
done
for l in "${LIBS[@]}"; do
  if [[ -f "/usr/local/lib/$l" ]]; then
    rm -f "/usr/local/lib/$l"
    echo "    Removed /usr/local/lib/$l"
  fi
done

echo
if [[ -d "$MODEL_CACHE" ]]; then
  CACHE_SIZE=$(du -sh "$MODEL_CACHE" 2>/dev/null | cut -f1)
  echo "Downloaded model cache found at ${MODEL_CACHE} (${CACHE_SIZE:-unknown size})."
  if [[ $AUTO_YES -eq 1 ]]; then
    echo "Remove it too? Type 'yes' to proceed: yes (auto-accepted)"
    REMOVE_CACHE="yes"
  else
    read -rp "Remove it too? Type 'yes' to delete, anything else to keep it: " REMOVE_CACHE
  fi
  if [[ "$REMOVE_CACHE" == "yes" ]]; then
    rm -rf "$MODEL_CACHE"
    echo "[*] Removed ${MODEL_CACHE}."
  else
    echo "[*] Left ${MODEL_CACHE} in place."
  fi
else
  echo "[*] No model cache found at ${MODEL_CACHE} - nothing to remove there."
fi

echo
echo "Note: the installer also appended a library-path export to"
echo "${USER_HOME}/.bashrc - this script doesn't touch that automatically"
echo "since the exact line varies by install; check and remove it by hand"
echo "if you want a completely clean .bashrc."

echo
echo "=== Done ==="
echo "llama.cpp has been uninstalled."
