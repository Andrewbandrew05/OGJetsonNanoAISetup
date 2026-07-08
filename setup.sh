#!/bin/bash
#
# setup.sh
#
# Single entry point for OGJetsonNanoAISetup. Presents a menu of available
# scripts, then runs them in a safe order:
#   1. Core system setup scripts (fixed internal order, see CORE_ORDER)
#   2. AI/service installers you selected (llama.cpp, whisper.cpp, piper,
#      backup+API)
#   3. Tailscale - ALWAYS last, if selected, regardless of menu order
#
# Usage (from a local clone):
#   chmod +x setup.sh
#   sudo ./setup.sh
#
# Usage (one-liner, clones the repo automatically if run standalone):
#   curl -fsSL https://raw.githubusercontent.com/Andrewbandrew05/OGJetsonNanoAISetup/main/setup.sh | sudo bash
#
set -uo pipefail

REPO_URL="https://github.com/Andrewbandrew05/OGJetsonNanoAISetup.git"
REPO_DIR_NAME="OGJetsonNanoAISetup"

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

# --- Locate the repo, or clone it if running standalone (e.g. via curl|bash) ---
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd || echo "")"

if [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/CoreSystemSetup" ]]; then
  REPO_ROOT="$SCRIPT_DIR"
else
  echo "[*] Running standalone - cloning $REPO_URL ..."
  apt-get update -y && apt-get install -y git
  TARGET_USER="${SUDO_USER:-root}"
  TARGET_HOME=$(eval echo "~${TARGET_USER}")
  if [[ ! -d "${TARGET_HOME}/${REPO_DIR_NAME}" ]]; then
    sudo -u "$TARGET_USER" git clone "$REPO_URL" "${TARGET_HOME}/${REPO_DIR_NAME}"
  fi
  REPO_ROOT="${TARGET_HOME}/${REPO_DIR_NAME}"
fi

cd "$REPO_ROOT"
echo "[*] Using repo at: $REPO_ROOT"
echo

# --- Define available scripts ---
# Keys, display labels, and paths (relative to repo root) for core items.
CORE_KEYS=(swap jtop gui sshharden)
declare -A CORE_LABEL=(
  [swap]="Create 4GB swap file"
  [jtop]="Install jtop (jetson-stats)"
  [gui]="Strip out GUI / desktop (permanent, boots to console)"
  [sshharden]="Harden SSH (key-only login - do this last of the core steps)"
)
declare -A CORE_PATH=(
  [swap]="CoreSystemSetup/SwapFileCreation/swap_setup.sh"
  [jtop]="CoreSystemSetup/JtopInstallation/jtop_install.sh"
  [gui]="CoreSystemSetup/GuiRemoval/jetson_nano_headless.sh"
  [sshharden]="CoreSystemSetup/SSHHardener/ssh_harden.sh"
)
# Fixed run order for core items regardless of selection order. SSH
# hardening runs last among these since it changes login behavior.
CORE_ORDER=(swap jtop gui sshharden)

OPTIONAL_KEYS=(llama whisper piper backup)
declare -A OPTIONAL_LABEL=(
  [llama]="Install llama.cpp (LLM inference server)"
  [whisper]="Install whisper.cpp (speech-to-text)"
  [piper]="Install wyoming-piper (text-to-speech)"
  [backup]="Install backup + control API (restic + Home Assistant endpoints)"
)
declare -A OPTIONAL_PATH=(
  [llama]="llama.cppSetup/install-llama-cpp-nano-service.sh"
  [whisper]="whisper.cppSetup/install-whisper-cpp.sh"
  [piper]="wyoming-piperSetup/install-wyoming-piper.sh"
  [backup]="BackupSetup/backup_api_install.sh"
)
OPTIONAL_ORDER=(llama whisper piper backup)

TAILSCALE_PATH="CoreSystemSetup/TaiscaleSetup/tailscale_install.sh"

# --- Build the menu ---
ALL_KEYS=("${CORE_KEYS[@]}" "${OPTIONAL_KEYS[@]}" tailscale)
declare -A ALL_LABEL
for k in "${CORE_KEYS[@]}"; do ALL_LABEL[$k]="[core] ${CORE_LABEL[$k]}"; done
for k in "${OPTIONAL_KEYS[@]}"; do ALL_LABEL[$k]="[install] ${OPTIONAL_LABEL[$k]}"; done
ALL_LABEL[tailscale]="[core] Install Tailscale (always runs last, if selected)"

echo "=== OG Jetson Nano AI Setup ==="
echo "Select which scripts to run. Core scripts run first (in a fixed safe"
echo "order), then installs, then Tailscale absolute last if selected."
echo
i=1
declare -A INDEX_TO_KEY
for k in "${ALL_KEYS[@]}"; do
  printf "  %2d) %s\n" "$i" "${ALL_LABEL[$k]}"
  INDEX_TO_KEY[$i]="$k"
  ((i++))
done
echo
echo "Enter numbers separated by spaces (e.g. 1 3 4 6), or 'all' for everything:"
read -rp "> " SELECTION

declare -A SELECTED
if [[ "$SELECTION" == "all" ]]; then
  for k in "${ALL_KEYS[@]}"; do SELECTED[$k]=1; done
else
  for n in $SELECTION; do
    if [[ -n "${INDEX_TO_KEY[$n]:-}" ]]; then
      SELECTED[${INDEX_TO_KEY[$n]}]=1
    else
      echo "[!] Ignoring invalid selection: $n"
    fi
  done
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  echo "Nothing selected. Exiting."
  exit 0
fi

# --- Build final run order: core (fixed order) -> installs -> tailscale ---
RUN_ORDER=()
for k in "${CORE_ORDER[@]}"; do
  [[ -n "${SELECTED[$k]:-}" ]] && RUN_ORDER+=("$k")
done
for k in "${OPTIONAL_ORDER[@]}"; do
  [[ -n "${SELECTED[$k]:-}" ]] && RUN_ORDER+=("$k")
done
[[ -n "${SELECTED[tailscale]:-}" ]] && RUN_ORDER+=("tailscale")

echo
echo "Planned run order:"
n=1
for k in "${RUN_ORDER[@]}"; do
  if [[ "$k" == "tailscale" ]]; then
    echo "  $n. Tailscale install"
  elif [[ -n "${CORE_PATH[$k]:-}" ]]; then
    echo "  $n. ${CORE_LABEL[$k]}"
  else
    echo "  $n. ${OPTIONAL_LABEL[$k]}"
  fi
  ((n++))
done
echo
read -rp "Proceed? Type 'yes' to continue: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

# --- Execute ---
declare -A RESULT
for k in "${RUN_ORDER[@]}"; do
  if [[ "$k" == "tailscale" ]]; then
    path="$TAILSCALE_PATH"
    label="Tailscale install"
  elif [[ -n "${CORE_PATH[$k]:-}" ]]; then
    path="${CORE_PATH[$k]}"
    label="${CORE_LABEL[$k]}"
  else
    path="${OPTIONAL_PATH[$k]}"
    label="${OPTIONAL_LABEL[$k]}"
  fi

  full_path="${REPO_ROOT}/${path}"
  echo
  echo "=============================================="
  echo ">>> Running: $label"
  echo ">>> Script:  $path"
  echo "=============================================="

  if [[ ! -f "$full_path" ]]; then
    echo "[!] Script not found at $full_path - skipping." >&2
    RESULT["$label"]="MISSING"
    continue
  fi

  chmod +x "$full_path" 2>/dev/null || true
  if bash "$full_path"; then
    RESULT["$label"]="OK"
  else
    echo "[!] $label exited with an error. Continuing with remaining steps." >&2
    RESULT["$label"]="FAILED"
  fi
done

echo
echo "=== Summary ==="
for label in "${!RESULT[@]}"; do
  printf "  %-70s %s\n" "$label" "${RESULT[$label]}"
done
echo
echo "If SSH hardening ran, test a fresh login in another terminal before"
echo "closing this session. If GUI removal ran, reboot when convenient:"
echo "  sudo reboot"
