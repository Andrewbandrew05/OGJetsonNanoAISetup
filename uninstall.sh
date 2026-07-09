#!/bin/bash
#
# uninstall.sh
#
# Single entry point for undoing what setup.sh's scripts did.
#
# Run it with NO arguments (sudo ./uninstall.sh) for an interactive
# uninstaller: it prints this help text, a numbered menu of every
# component that can be uninstalled, and a prompt where you can either
# type numbers to target specific ones, or type flags to run a
# preconfigured combination exactly as you would on the command line.
#
# Run it WITH arguments (sudo ./uninstall.sh --uninstallAll) to skip the
# interactive prompt entirely.
#
# Every individual uninstall-*.sh script also works completely standalone
# (sudo ./uninstall-whatever.sh), same as the install scripts do.
#
# Component flags (combinable):
#   --uninstallAll           Everything below, in a sensible teardown order.
#   --uninstallGui            Undo GUI removal - re-enables the display
#                            manager and boot target, and (if a previous
#                            --purge-packages run removed packages) offers
#                            to reinstall them from the backup package list.
#   --uninstallPython39       Remove the Python 3.9 source altinstall.
#   --uninstallGcc9           Remove gcc-9/g++-9 and their PPA.
#   --uninstallSwap           Remove the swap file.
#   --uninstallJtop           Remove jtop (jetson-stats).
#   --uninstallSshHarden      Restore sshd_config from its pre-hardening backup.
#   --uninstallLlama          Remove llama.cpp and its systemd service.
#   --uninstallWhisper        Remove whisper.cpp and its systemd service.
#   --uninstallWyomingWhisper Remove the Wyoming-whisper bridge.
#   --uninstallPiper          Remove wyoming-piper and its systemd service.
#   --uninstallBackupAPI      Remove the backup + control API (does NOT
#                            touch your remote backup target/repository).
#   --uninstallTailscale      Log out and remove Tailscale.
#
# Prompt-bypass flag:
#   --bypassAllChecks  Auto-accept every confirmation, in every
#                     uninstall-*.sh script this runs (same env vars
#                     setup.sh's --bypassAllChecks sets).
#
# Usage:
#   chmod +x uninstall.sh
#   sudo ./uninstall.sh                          # interactive: numbers or flags
#   sudo ./uninstall.sh --uninstallAll
#   sudo ./uninstall.sh --uninstallLlama --uninstallWhisper
#
set -uo pipefail

print_help() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
}

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

UNINSTALL_ALL=0
BYPASS_ALL=0
declare -A WANT

parse_flag_token() {
  local arg="$1"
  case "$arg" in
    --uninstallAll) UNINSTALL_ALL=1 ;;
    --uninstallGui) WANT[gui]=1 ;;
    --uninstallPython39) WANT[python39]=1 ;;
    --uninstallGcc9) WANT[gcc9]=1 ;;
    --uninstallSwap) WANT[swap]=1 ;;
    --uninstallJtop) WANT[jtop]=1 ;;
    --uninstallSshHarden) WANT[sshharden]=1 ;;
    --uninstallLlama) WANT[llama]=1 ;;
    --uninstallWhisper) WANT[whisper]=1 ;;
    --uninstallWyomingWhisper) WANT[wyomingwhisper]=1 ;;
    --uninstallPiper) WANT[piper]=1 ;;
    --uninstallBackupAPI) WANT[backup]=1 ;;
    --uninstallTailscale) WANT[tailscale]=1 ;;
    --bypassAllChecks) BYPASS_ALL=1 ;;
    -h|--help) print_help; exit 0 ;;
    *)
      echo "[!] Unknown flag: $arg (--help for usage)" >&2
      exit 1
      ;;
  esac
}

# --- Component keys, labels, and paths (relative to repo root). Teardown
# order: services first, then core system stuff, GUI restoration last
# (slowest/most involved one). Order doesn't matter for correctness here
# the way install order did - nothing below depends on anything else
# already being uninstalled. ---
ALL_KEYS=(llama whisper wyomingwhisper piper backup tailscale sshharden jtop swap gcc9 python39 gui)
declare -A LABEL=(
  [llama]="Remove llama.cpp"
  [whisper]="Remove whisper.cpp"
  [wyomingwhisper]="Remove Wyoming-whisper bridge"
  [piper]="Remove wyoming-piper"
  [backup]="Remove backup + control API (does NOT touch your remote backup target)"
  [tailscale]="Log out and remove Tailscale"
  [sshharden]="Restore SSH config from pre-hardening backup"
  [jtop]="Remove jtop (jetson-stats)"
  [swap]="Remove swap file"
  [gcc9]="Remove gcc-9/g++-9"
  [python39]="Remove Python 3.9 (source altinstall)"
  [gui]="Undo GUI removal (re-enable display manager; offer to reinstall purged packages)"
)
declare -A PATH_MAP=(
  [llama]="llama.cppSetup/uninstall-llama-cpp-nano-service.sh"
  [whisper]="whisper.cppSetup/uninstall-whisper-cpp.sh"
  [wyomingwhisper]="wyoming-whisperSetup/uninstall-wyoming-whisper.sh"
  [piper]="wyoming-piperSetup/uninstall-wyoming-piper.sh"
  [backup]="CoreSystemSetup/BackupAPISetup/uninstall-backup-api.sh"
  [tailscale]="CoreSystemSetup/TaiscaleSetup/uninstall-tailscale.sh"
  [sshharden]="CoreSystemSetup/SSHHardener/uninstall-ssh-harden.sh"
  [jtop]="CoreSystemSetup/JtopInstallation/uninstall-jtop.sh"
  [swap]="CoreSystemSetup/SwapFileCreation/uninstall-swap.sh"
  [gcc9]="CoreSystemSetup/Gcc9Upgrade/uninstall-gcc9.sh"
  [python39]="CoreSystemSetup/Python39Upgrade/uninstall-python39.sh"
  [gui]="CoreSystemSetup/GuiRemoval/uninstall-gui-removal.sh"
)

print_menu() {
  local i=1
  for k in "${ALL_KEYS[@]}"; do
    printf "  %2d) %s\n" "$i" "${LABEL[$k]}"
    INDEX_TO_KEY[$i]="$k"
    ((i++))
  done
}

declare -A INDEX_TO_KEY
RUN_MODE=""

if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    parse_flag_token "$arg"
  done
  RUN_MODE="flags"
else
  print_help
  echo
  echo "=== OGJetsonNanoAISetup Uninstaller ==="
  echo
  print_menu
  echo
  echo "Type numbers to uninstall specific components (e.g. 1 3 4), or"
  echo "'all' for everything, OR type flags exactly as you would on the"
  echo "command line (e.g. --uninstallLlama --uninstallWhisper):"
  read -rp "> " RESPONSE

  if [[ -z "${RESPONSE// }" ]]; then
    echo "Nothing entered. Exiting."
    exit 0
  fi

  IS_FLAGS=0
  for tok in $RESPONSE; do
    [[ "$tok" == --* ]] && IS_FLAGS=1
  done

  if [[ $IS_FLAGS -eq 1 ]]; then
    for tok in $RESPONSE; do
      parse_flag_token "$tok"
    done
    RUN_MODE="flags"
  else
    RUN_MODE="numbers"
    if [[ "$RESPONSE" == "all" ]]; then
      UNINSTALL_ALL=1
    else
      for n in $RESPONSE; do
        if [[ -n "${INDEX_TO_KEY[$n]:-}" ]]; then
          WANT[${INDEX_TO_KEY[$n]}]=1
        else
          echo "[!] Ignoring invalid selection: $n"
        fi
      done
    fi
  fi
fi

if [[ $UNINSTALL_ALL -eq 1 ]]; then
  for k in "${ALL_KEYS[@]}"; do WANT[$k]=1; done
fi

if [[ ${#WANT[@]} -eq 0 ]]; then
  echo "Nothing selected. Exiting."
  exit 0
fi

export NANO_SETUP_AUTO_YES=$BYPASS_ALL
export NANO_SETUP_AUTO_YES_OS=$BYPASS_ALL
if [[ $BYPASS_ALL -eq 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
fi

# --- Locate the repo ---
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" 2>/dev/null && pwd || echo "")"
if [[ -z "$SCRIPT_DIR" || ! -d "$SCRIPT_DIR/CoreSystemSetup" ]]; then
  echo "[!] Couldn't locate the repo (run this from inside a clone of it)." >&2
  exit 1
fi
REPO_ROOT="$SCRIPT_DIR"
cd "$REPO_ROOT"

echo
echo "Planned uninstall order:"
n=1
RUN_ORDER=()
for k in "${ALL_KEYS[@]}"; do
  if [[ -n "${WANT[$k]:-}" ]]; then
    RUN_ORDER+=("$k")
    echo "  $n. ${LABEL[$k]}"
    ((n++))
  fi
done
echo

if [[ $BYPASS_ALL -eq 1 ]]; then
  echo "[*] --bypassAllChecks set - auto-accepting, proceeding without confirmation."
  echo "    (Individual scripts may still print their own destructive-action"
  echo "    warnings - read the output.)"
else
  read -rp "Proceed? Type 'yes' to continue: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

declare -A RESULT
for k in "${RUN_ORDER[@]}"; do
  path="${PATH_MAP[$k]}"
  label="${LABEL[$k]}"
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
echo "If SSH hardening was undone, test a fresh login in another terminal"
echo "before closing this session. If GUI removal was undone, reboot when"
echo "convenient: sudo reboot"
