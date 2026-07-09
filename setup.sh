#!/bin/bash
#
# setup.sh
#
# Single entry point for OGJetsonNanoAISetup. Either presents a menu of
# available scripts, or - if given install flags - runs a preconfigured
# package non-interactively. Run order is always:
#   1. Core system setup scripts (fixed internal order, see CORE_ORDER)
#   2. AI/service installers you selected (llama.cpp, whisper.cpp, piper,
#      backup+API)
#   3. System package update/upgrade - ALWAYS right before Tailscale, if
#      selected, regardless of menu order.
#   4. Tailscale - ALWAYS last, if selected, regardless of menu order. It
#      finishes by running `tailscale up`, which waits on a login URL, so
#      it's the one thing left on screen once everything else is done.
#
# Package flags (combinable - selecting the same script via more than one
# flag runs it once, not twice):
#   --installAll          Core system setup + llama.cpp + whisper.cpp +
#                          wyoming-piper + system package upgrade +
#                          Tailscale (upgrade then Tailscale always last,
#                          in that order). Does NOT include the backup API
#                          (needs your own remote storage details) - add
#                          --installBackupAPI too if you want it.
#   --installModels        llama.cpp + whisper.cpp + wyoming-piper only.
#   --installBackupAPI      restic backup + control API only. Needs
#                          NANO_BACKUP_* env vars to run non-interactively -
#                          see CoreSystemSetup/BackupAPISetup/README.md.
#
# If no install flag is given, you get the interactive menu (unchanged).
#
# Prompt-bypass flags:
#   --bypassAllChecks       Auto-accept every confirmation, including
#                          OS-level ones (GUI removal's purge confirmation)
#                          and apt/debconf/needrestart system dialogs.
#   --bypassInstallerChecks Auto-accept installer-level confirmations only
#                          (e.g. backup API's "press enter to continue").
#                          OS-level confirmations (GUI removal) still ask.
#
# GUI removal mode:
#   --purgeGuiPackages      Also purge the actual GUI/desktop packages to
#                          reclaim disk space (GUI removal's --purge-
#                          packages mode), instead of the default
#                          disable-only behavior. Slower, and independent
#                          of the bypass flags above - has to be passed
#                          explicitly either way.
#
# Usage (from a local clone):
#   chmod +x setup.sh
#   sudo ./setup.sh
#   sudo ./setup.sh --installAll --bypassAllChecks
#   sudo ./setup.sh --installAll --installBackupAPI --purgeGuiPackages --bypassAllChecks
#
# Usage (one-liner, clones the repo automatically if run standalone):
#   curl -fsSL https://raw.githubusercontent.com/Andrewbandrew05/OGJetsonNanoAISetup/main/setup.sh | sudo bash -s -- --installAll --installBackupAPI --purgeGuiPackages --bypassAllChecks
#
set -uo pipefail

REPO_URL="https://github.com/Andrewbandrew05/OGJetsonNanoAISetup.git"
REPO_DIR_NAME="OGJetsonNanoAISetup"

print_help() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --help/-h works without root, so check for it before the root requirement.
for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    print_help
    exit 0
  fi
done

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

# --- Parse flags ---
INSTALL_ALL=0
INSTALL_MODELS=0
INSTALL_BACKUP=0
BYPASS_ALL=0
BYPASS_INSTALLER=0
PURGE_GUI_PACKAGES=0

for arg in "$@"; do
  case "$arg" in
    --installAll) INSTALL_ALL=1 ;;
    --installModels) INSTALL_MODELS=1 ;;
    --installBackupAPI) INSTALL_BACKUP=1 ;;
    --bypassAllChecks) BYPASS_ALL=1 ;;
    --bypassInstallerChecks) BYPASS_INSTALLER=1 ;;
    --purgeGuiPackages) PURGE_GUI_PACKAGES=1 ;;
    *)
      echo "[!] Unknown flag: $arg (--help for usage)" >&2
      exit 1
      ;;
  esac
done

FLAG_MODE=$(( INSTALL_ALL || INSTALL_MODELS || INSTALL_BACKUP ))

# NANO_GUI_PURGE_PACKAGES - tells jetson_nano_headless.sh to also purge the
# actual GUI/desktop packages (its --purge-packages mode) instead of just
# disabling the display manager. Independent of the bypass flags above -
# ---purgeGuiPackages has to be passed explicitly to turn this on.
export NANO_GUI_PURGE_PACKAGES=$PURGE_GUI_PACKAGES

# How many times to attempt each script before giving up on it (1 = no
# retry). Overridable via env var for anyone who wants tighter/looser
# tolerance than the default.
NANO_SETUP_SCRIPT_ATTEMPTS="${NANO_SETUP_SCRIPT_ATTEMPTS:-2}"
NANO_SETUP_RETRY_DELAY="${NANO_SETUP_RETRY_DELAY:-15}"

# NANO_SETUP_AUTO_YES     - auto-accept installer-level confirmations
# NANO_SETUP_AUTO_YES_OS  - auto-accept OS-level (destructive/system) confirmations
NANO_SETUP_AUTO_YES=0
NANO_SETUP_AUTO_YES_OS=0
if [[ $BYPASS_ALL -eq 1 ]]; then
  NANO_SETUP_AUTO_YES=1
  NANO_SETUP_AUTO_YES_OS=1
elif [[ $BYPASS_INSTALLER -eq 1 ]]; then
  NANO_SETUP_AUTO_YES=1
fi
export NANO_SETUP_AUTO_YES NANO_SETUP_AUTO_YES_OS

if [[ $NANO_SETUP_AUTO_YES_OS -eq 1 ]]; then
  # Keep apt/dpkg/needrestart from popping up interactive dialogs
  # (config file conflicts, "restart services?" prompts) during a
  # walk-away run.
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
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
CORE_KEYS=(gui python39 gcc9 swap jtop sshharden)
declare -A CORE_LABEL=(
  [gui]="Boot to console instead of GUI (disables display manager; packages kept unless run manually with --purge-packages)"
  [python39]="Install Python 3.9 (source build - deadsnakes PPA no longer covers Bionic, needed for wyoming-piper)"
  [gcc9]="Install gcc-9/g++-9 (ubuntu-toolchain-r/test PPA, needed for whisper.cpp)"
  [swap]="Create 4GB swap file"
  [jtop]="Install jtop (jetson-stats)"
  [sshharden]="Harden SSH (key-only login - do this last of the core steps)"
)
declare -A CORE_PATH=(
  [gui]="CoreSystemSetup/GuiRemoval/jetson_nano_headless.sh"
  [python39]="CoreSystemSetup/Python39Upgrade/python39_upgrade.sh"
  [gcc9]="CoreSystemSetup/Gcc9Upgrade/gcc9_upgrade.sh"
  [swap]="CoreSystemSetup/SwapFileCreation/swap_setup.sh"
  [jtop]="CoreSystemSetup/JtopInstallation/jtop_install.sh"
  [sshharden]="CoreSystemSetup/SSHHardener/ssh_harden.sh"
)
# Fixed run order for core items regardless of selection order. GUI removal
# runs first among these; the Python 3.9 and gcc-9 builds run right after
# it (so they're ready before wyoming-piper/whisper.cpp need them); SSH
# hardening runs last since it changes login behavior.
CORE_ORDER=(gui python39 gcc9 swap jtop sshharden)

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
  [backup]="CoreSystemSetup/BackupAPISetup/backup_api_install.sh"
)
OPTIONAL_ORDER=(llama whisper piper backup)

SYSUPGRADE_PATH="CoreSystemSetup/SystemUpgrade/system_upgrade.sh"
TAILSCALE_PATH="CoreSystemSetup/TaiscaleSetup/tailscale_install.sh"

# --- Build the menu (only shown if no install flag was given) ---
ALL_KEYS=("${CORE_KEYS[@]}" "${OPTIONAL_KEYS[@]}" sysupgrade tailscale)
declare -A ALL_LABEL
for k in "${CORE_KEYS[@]}"; do ALL_LABEL[$k]="[core] ${CORE_LABEL[$k]}"; done
for k in "${OPTIONAL_KEYS[@]}"; do ALL_LABEL[$k]="[install] ${OPTIONAL_LABEL[$k]}"; done
ALL_LABEL[sysupgrade]="[core] System package update/upgrade (always runs right before Tailscale, if selected)"
ALL_LABEL[tailscale]="[core] Install Tailscale (always runs last, if selected)"

# --- Build the selection set. A bash associative array is a set, so
# selecting the same script via more than one flag (or flag + menu) is a
# no-op the second time - nothing runs twice. ---
declare -A SELECTED

if [[ $FLAG_MODE -eq 1 ]]; then
  echo "=== OG Jetson Nano AI Setup (non-interactive package mode) ==="
  if [[ $INSTALL_ALL -eq 1 ]]; then
    echo "[*] --installAll: core system setup + AI models + system upgrade + Tailscale"
    for k in "${CORE_KEYS[@]}"; do SELECTED[$k]=1; done
    SELECTED[llama]=1; SELECTED[whisper]=1; SELECTED[piper]=1
    SELECTED[sysupgrade]=1
    SELECTED[tailscale]=1
  fi
  if [[ $INSTALL_MODELS -eq 1 ]]; then
    echo "[*] --installModels: llama.cpp + whisper.cpp + wyoming-piper"
    SELECTED[llama]=1; SELECTED[whisper]=1; SELECTED[piper]=1
  fi
  if [[ $INSTALL_BACKUP -eq 1 ]]; then
    echo "[*] --installBackupAPI: backup + control API"
    SELECTED[backup]=1
  fi
  echo
else
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
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
  echo "Nothing selected. Exiting."
  exit 0
fi

# --- Build final run order: core (fixed order) -> installs -> system
# upgrade -> tailscale. System upgrade and Tailscale are always last, in
# that order, regardless of where they appear in the menu/selection. ---
RUN_ORDER=()
for k in "${CORE_ORDER[@]}"; do
  [[ -n "${SELECTED[$k]:-}" ]] && RUN_ORDER+=("$k")
done
for k in "${OPTIONAL_ORDER[@]}"; do
  [[ -n "${SELECTED[$k]:-}" ]] && RUN_ORDER+=("$k")
done
[[ -n "${SELECTED[sysupgrade]:-}" ]] && RUN_ORDER+=("sysupgrade")
[[ -n "${SELECTED[tailscale]:-}" ]] && RUN_ORDER+=("tailscale")

echo
echo "Planned run order:"
n=1
for k in "${RUN_ORDER[@]}"; do
  if [[ "$k" == "tailscale" ]]; then
    echo "  $n. Tailscale install (ends by waiting on 'tailscale up' login)"
  elif [[ "$k" == "sysupgrade" ]]; then
    echo "  $n. System package update/upgrade"
  elif [[ -n "${CORE_PATH[$k]:-}" ]]; then
    echo "  $n. ${CORE_LABEL[$k]}"
  else
    echo "  $n. ${OPTIONAL_LABEL[$k]}"
  fi
  ((n++))
done
echo

if [[ $NANO_SETUP_AUTO_YES -eq 1 ]]; then
  echo "[*] Bypass flag set - auto-accepting, proceeding without confirmation."
else
  read -rp "Proceed? Type 'yes' to continue: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# --- Execute ---
declare -A RESULT
for k in "${RUN_ORDER[@]}"; do
  if [[ "$k" == "tailscale" ]]; then
    path="$TAILSCALE_PATH"
    label="Tailscale install"
  elif [[ "$k" == "sysupgrade" ]]; then
    path="$SYSUPGRADE_PATH"
    label="System package update/upgrade"
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

  # Every script here is idempotent (checks what's already done before
  # redoing it), so a failure is cheap to just retry - and several of
  # tonight's "failures" turned out to be nothing but a transient network
  # blip during a curl/git/apt call, fixed by a plain rerun with zero
  # changes. Retry a bounded number of times before giving up, rather than
  # moving on after the first hiccup during an unattended run.
  attempt=1
  status="FAILED"
  while [[ $attempt -le $NANO_SETUP_SCRIPT_ATTEMPTS ]]; do
    if [[ $attempt -gt 1 ]]; then
      echo "[*] Retry ${attempt}/${NANO_SETUP_SCRIPT_ATTEMPTS} for: $label (waiting ${NANO_SETUP_RETRY_DELAY}s first)"
      sleep "$NANO_SETUP_RETRY_DELAY"
    fi
    if bash "$full_path"; then
      status="OK"
      break
    fi
    ((attempt++))
  done

  RESULT["$label"]="$status"
  if [[ "$status" == "FAILED" ]]; then
    echo "[!] $label failed after ${NANO_SETUP_SCRIPT_ATTEMPTS} attempt(s). Continuing with remaining steps." >&2
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
