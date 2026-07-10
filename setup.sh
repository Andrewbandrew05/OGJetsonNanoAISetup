#!/bin/bash
#
# setup.sh
#
# Single entry point for OGJetsonNanoAISetup.
#
# Run it with NO arguments (sudo ./setup.sh) for an interactive installer:
# it prints this help text, a numbered menu of every available script, and
# a prompt where you can either:
#   - type numbers to run individual scripts (e.g. 1 3 4), or 'all' for
#     everything, or
#   - type flags to run one of the preconfigured packages below (e.g.
#     --installAll --bypassAllChecks), exactly as you would on the command
#     line.
#
# Run it WITH arguments (sudo ./setup.sh --installAll --bypassAllChecks)
# to skip the interactive prompt entirely and go straight to that
# preconfigured package - this is what you want for scripted/unattended
# use (curl | sudo bash, cron, etc).
#
# Run order is always:
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
#                          Wyoming-whisper bridge + wyoming-piper + system
#                          package upgrade + Tailscale (upgrade then
#                          Tailscale always last, in that order). Does NOT
#                          include the backup API (needs your own remote
#                          storage details) - add --installBackupAPI too
#                          if you want it.
#   --installModels        llama.cpp + whisper.cpp + Wyoming-whisper
#                          bridge + wyoming-piper only.
#   --installBackupAPI      restic backup + control API only. Needs
#                          NANO_BACKUP_* env vars to run non-interactively -
#                          see CoreSystemSetup/BackupAPISetup/README.md.
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
#   --purgeGuiPackages      Also remove the actual GUI/desktop packages to
#                          reclaim disk space (GUI removal's --purge-
#                          packages mode), instead of the default
#                          disable-only behavior. Slower, and independent
#                          of the bypass flags above - has to be passed
#                          explicitly either way.
#
# Binding (llama.cpp, wyoming-piper, the Wyoming-whisper bridge, and the
# backup+control API - the 4 services with a network-reachable port):
#   Default is LAN-wide (0.0.0.0) - reachable by anyone on your local
#   network. --tailscaleAll restricts all 4 to the Tailscale interface only
#   for THIS run's fresh installs (falls back to 127.0.0.1 if tailscale0
#   never comes up, never silently to LAN-wide). SECURITY NOTE: the backup
#   API can trigger a reboot and a backup run, guarded only by a bearer
#   token in a plaintext file - consider restricting at least that one to
#   Tailscale even if you leave the AI services LAN-wide.
#   --tailscaleAll          Fresh installs this run bind Tailscale-only
#                          instead of LAN-wide, for all 4 services above.
#   --rebindTailscale        Standalone mode (ignores install/package flags):
#   --rebindLan              flips the bind mode of every ALREADY-INSTALLED
#                          one of the 4 services above, without a full
#                          reinstall (no redownloading models/binaries, no
#                          new API token). Mutually exclusive with each
#                          other; skips any of the 4 that aren't installed.
#                          Same effect per-service: sudo ./<script>.sh
#                          --rebind [--tailscale]
#
# System upgrade config-file policy:
#   --forceNewConfigs       When the system package upgrade hits a config
#                          file that was locally modified (e.g. a Jetson-
#                          specific file JetPack's first-boot setup
#                          customized), take the package maintainer's new
#                          version instead of the default (keep the
#                          current one). See
#                          CoreSystemSetup/SystemUpgrade/README.md for the
#                          reasoning either way.
#
# Default ports (all externally-facing services):
#   llama.cpp           8081  http://<nano-ip>:8081  (OpenAI-compatible API + web UI)
#   whisper.cpp          8080  http://<nano-ip>:8080  (plain REST API - NOT Wyoming protocol)
#   Wyoming-whisper     10300  tcp://<nano-ip>:10300  (Wyoming protocol bridge in front of whisper.cpp)
#   wyoming-piper       10200  tcp://<nano-ip>:10200  (Wyoming protocol - HA-ready)
#   backup/control API   8843  http://<tailscale-ip>:8843  (falls back to 127.0.0.1 until Tailscale is up)
#
# Custom ports (each only takes effect for that service if it's actually
# being installed this run):
#   --llamaPort=9000
#   --whisperPort=9001
#   --wyomingWhisperPort=10301
#   --piperPort=10201
#   --backupApiPort=9002
#
# whisper.cpp model (only takes effect if whisper.cpp is actually being
# installed this run): defaults to small.en, or asks interactively (with
# tradeoff descriptions) if run with no args and no bypass flag. Set this
# to skip that prompt non-interactively:
#   --whisperModel=base.en   (tiny.en / base.en / small.en / medium.en)
#
# Usage (from a local clone):
#   chmod +x setup.sh
#   sudo ./setup.sh                        # interactive: numbers or flags, your choice
#   sudo ./setup.sh --installAll --bypassAllChecks
#   sudo ./setup.sh --installAll --installBackupAPI --purgeGuiPackages --bypassAllChecks
#
# Usage (one-liner, clones the repo automatically if run standalone):
#   curl -fsSL https://raw.githubusercontent.com/Andrewbandrew05/OGJetsonNanoAISetup/main/setup.sh | sudo bash -s -- --installAll --installBackupAPI --purgeGuiPackages --bypassAllChecks
#
set -uo pipefail

REPO_URL="https://github.com/Andrewbandrew05/OGJetsonNanoAISetup.git"
REPO_DIR_NAME="OGJetsonNanoAISetup"

# Prints every leading comment line of this file (skipping the shebang),
# stopping at the first non-comment line - so this always reflects the
# header above without needing a hardcoded line range to keep in sync.
print_help() {
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
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

# --- Flag state + parser (shared by direct CLI args and the interactive
# prompt below - both end up calling parse_flag_token for each word) ---
INSTALL_ALL=0
INSTALL_MODELS=0
INSTALL_BACKUP=0
BYPASS_ALL=0
BYPASS_INSTALLER=0
PURGE_GUI_PACKAGES=0
FORCE_NEW_CONFIGS=0
TAILSCALE_ALL=0
REBIND_MODE=""
LLAMA_PORT=""
WHISPER_PORT=""
WHISPER_MODEL_FLAG=""
WYOMING_WHISPER_PORT_FLAG=""
PIPER_PORT=""
BACKUP_API_PORT=""

parse_flag_token() {
  local arg="$1"
  case "$arg" in
    --installAll) INSTALL_ALL=1 ;;
    --installModels) INSTALL_MODELS=1 ;;
    --installBackupAPI) INSTALL_BACKUP=1 ;;
    --bypassAllChecks) BYPASS_ALL=1 ;;
    --bypassInstallerChecks) BYPASS_INSTALLER=1 ;;
    --purgeGuiPackages) PURGE_GUI_PACKAGES=1 ;;
    --forceNewConfigs) FORCE_NEW_CONFIGS=1 ;;
    --tailscaleAll) TAILSCALE_ALL=1 ;;
    --rebindTailscale)
      if [[ -n "$REBIND_MODE" && "$REBIND_MODE" != "tailscale" ]]; then
        echo "[!] --rebindTailscale and --rebindLan are mutually exclusive." >&2
        exit 1
      fi
      REBIND_MODE="tailscale"
      ;;
    --rebindLan)
      if [[ -n "$REBIND_MODE" && "$REBIND_MODE" != "lan" ]]; then
        echo "[!] --rebindTailscale and --rebindLan are mutually exclusive." >&2
        exit 1
      fi
      REBIND_MODE="lan"
      ;;
    --llamaPort=*) LLAMA_PORT="${arg#*=}" ;;
    --whisperPort=*) WHISPER_PORT="${arg#*=}" ;;
    --whisperModel=*) WHISPER_MODEL_FLAG="${arg#*=}" ;;
    --wyomingWhisperPort=*) WYOMING_WHISPER_PORT_FLAG="${arg#*=}" ;;
    --piperPort=*) PIPER_PORT="${arg#*=}" ;;
    --backupApiPort=*) BACKUP_API_PORT="${arg#*=}" ;;
    -h|--help) print_help; exit 0 ;;
    *)
      echo "[!] Unknown flag: $arg (--help for usage)" >&2
      exit 1
      ;;
  esac
}

# --- Define available scripts (static - doesn't need the repo cloned yet) ---
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

OPTIONAL_KEYS=(llama whisper wyomingwhisper piper backup)
declare -A OPTIONAL_LABEL=(
  [llama]="Install llama.cpp (LLM inference server, port 8081 by default)"
  [whisper]="Install whisper.cpp (speech-to-text, plain REST API on port 8080 by default - NOT Wyoming protocol)"
  [wyomingwhisper]="Install Wyoming-whisper bridge (wraps whisper.cpp for HA, Wyoming protocol, port 10300 by default - no second model)"
  [piper]="Install wyoming-piper (text-to-speech, Wyoming protocol, port 10200 by default)"
  [backup]="Install backup + control API (restic + Home Assistant endpoints, port 8843 by default)"
)
declare -A OPTIONAL_PATH=(
  [llama]="llama.cppSetup/install-llama-cpp-nano-service.sh"
  [whisper]="whisper.cppSetup/install-whisper-cpp.sh"
  [wyomingwhisper]="wyoming-whisperSetup/install-wyoming-whisper.sh"
  [piper]="wyoming-piperSetup/install-wyoming-piper.sh"
  [backup]="CoreSystemSetup/BackupAPISetup/backup_api_install.sh"
)
# whisper.cpp before its Wyoming bridge - the bridge forwards to whisper.cpp's
# own server and has nothing to transcribe with otherwise.
OPTIONAL_ORDER=(llama whisper wyomingwhisper piper backup)

SYSUPGRADE_PATH="CoreSystemSetup/SystemUpgrade/system_upgrade.sh"
TAILSCALE_PATH="CoreSystemSetup/TaiscaleSetup/tailscale_install.sh"

ALL_KEYS=("${CORE_KEYS[@]}" "${OPTIONAL_KEYS[@]}" sysupgrade tailscale)
declare -A ALL_LABEL
for k in "${CORE_KEYS[@]}"; do ALL_LABEL[$k]="${CORE_LABEL[$k]}"; done
for k in "${OPTIONAL_KEYS[@]}"; do ALL_LABEL[$k]="${OPTIONAL_LABEL[$k]}"; done
ALL_LABEL[sysupgrade]="System package update/upgrade (always runs right before Tailscale, if selected)"
ALL_LABEL[tailscale]="Install Tailscale (always runs last, if selected)"

# Prints the numbered menu grouped by category, for the interactive prompt.
print_menu() {
  local i=1
  echo "Core system setup:"
  for k in "${CORE_KEYS[@]}"; do
    printf "  %2d) %s\n" "$i" "${CORE_LABEL[$k]}"
    INDEX_TO_KEY[$i]="$k"
    ((i++))
  done
  echo
  echo "AI / service installs:"
  for k in "${OPTIONAL_KEYS[@]}"; do
    printf "  %2d) %s\n" "$i" "${OPTIONAL_LABEL[$k]}"
    INDEX_TO_KEY[$i]="$k"
    ((i++))
  done
  echo
  echo "Always-last steps (if selected):"
  for k in sysupgrade tailscale; do
    printf "  %2d) %s\n" "$i" "${ALL_LABEL[$k]}"
    INDEX_TO_KEY[$i]="$k"
    ((i++))
  done
}

# --- Decide interactive vs direct mode ---
declare -A SELECTED
declare -A INDEX_TO_KEY
RUN_MODE=""

if [[ $# -gt 0 ]]; then
  # Direct mode: args were given on the command line, so skip straight to
  # running them - no interactive prompt.
  for arg in "$@"; do
    parse_flag_token "$arg"
  done
  RUN_MODE="flags"
else
  # Interactive mode: no args at all. Show the full picture up front, then
  # accept either numbers or a flag string at one prompt.
  print_help
  echo
  echo "=== OG Jetson Nano AI Setup ==="
  echo
  print_menu
  echo
  echo "Type numbers to run individual scripts (e.g. 1 3 4), or 'all' for"
  echo "everything, OR type flags to run a preconfigured package exactly as"
  echo "you would on the command line (e.g. --installAll --bypassAllChecks):"
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
      for k in "${ALL_KEYS[@]}"; do SELECTED[$k]=1; done
    else
      for n in $RESPONSE; do
        if [[ -n "${INDEX_TO_KEY[$n]:-}" ]]; then
          SELECTED[${INDEX_TO_KEY[$n]}]=1
        else
          echo "[!] Ignoring invalid selection: $n"
        fi
      done
    fi
  fi
fi

FLAG_MODE=$(( INSTALL_ALL || INSTALL_MODELS || INSTALL_BACKUP ))

# NANO_GUI_PURGE_PACKAGES - tells jetson_nano_headless.sh to also remove
# the actual GUI/desktop packages (its --purge-packages mode) instead of
# just disabling the display manager. Independent of the bypass flags
# above - --purgeGuiPackages has to be passed explicitly to turn this on.
export NANO_GUI_PURGE_PACKAGES=$PURGE_GUI_PACKAGES

# NANO_SYSUPGRADE_FORCE_NEW - tells system_upgrade.sh to take the package
# maintainer's version on a config file conflict instead of the default
# (keep the current one).
export NANO_SYSUPGRADE_FORCE_NEW=$FORCE_NEW_CONFIGS

# --tailscaleAll - fresh installs this run bind Tailscale-only instead of
# LAN-wide, for the 4 services that support it. Has no effect on services
# already installed - see --rebindTailscale/--rebindLan for that.
if [[ $TAILSCALE_ALL -eq 1 ]]; then
  export LLAMA_BIND_TAILSCALE=1
  export WYOMING_PIPER_BIND_TAILSCALE=1
  export WYOMING_WHISPER_BIND_TAILSCALE=1
  export NANO_BACKUP_BIND_TAILSCALE=1
fi

# Custom ports - only exported if actually given, so each script's own
# default (documented in its own header comment) applies otherwise.
[[ -n "$LLAMA_PORT" ]] && export LLAMA_SERVICE_PORT="$LLAMA_PORT"
[[ -n "$WHISPER_PORT" ]] && export WHISPER_SERVER_PORT="$WHISPER_PORT"
[[ -n "$WHISPER_MODEL_FLAG" ]] && export WHISPER_MODEL="$WHISPER_MODEL_FLAG"
[[ -n "$WYOMING_WHISPER_PORT_FLAG" ]] && export WYOMING_WHISPER_PORT="$WYOMING_WHISPER_PORT_FLAG"
[[ -n "$PIPER_PORT" ]] && export WYOMING_PIPER_PORT="$PIPER_PORT"
[[ -n "$BACKUP_API_PORT" ]] && export NANO_BACKUP_API_PORT="$BACKUP_API_PORT"

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

# --- Standalone rebind mode: flip the bind mode (LAN-wide <-> Tailscale-
# only) of every already-installed service that supports it, without a
# full reinstall. Ignores install/package flags entirely - exits before
# reaching the normal SELECTED/RUN_ORDER logic below. ---
if [[ -n "$REBIND_MODE" ]]; then
  declare -A REBIND_UNIT=(
    [llama]="llama-cpp-server.service"
    [piper]="wyoming-piper.service"
    [wyomingwhisper]="wyoming-whisper.service"
    [backup]="nano-ai-api.service"
  )
  echo "[*] Rebind mode: setting every already-installed supported service to '${REBIND_MODE}'."
  echo
  REBIND_ARGS=(--rebind)
  [[ "$REBIND_MODE" == "tailscale" ]] && REBIND_ARGS+=(--tailscale)
  for k in llama piper wyomingwhisper backup; do
    unit="${REBIND_UNIT[$k]}"
    path="${OPTIONAL_PATH[$k]}"
    full_path="${REPO_ROOT}/${path}"
    if [[ ! -f "/etc/systemd/system/${unit}" ]]; then
      echo "  [skip] ${k}: not installed (${unit} not found)"
      continue
    fi
    echo "  [*] ${k}: rebinding..."
    chmod +x "$full_path" 2>/dev/null || true
    if bash "$full_path" "${REBIND_ARGS[@]}"; then
      echo "  [ok] ${k}: rebound to ${REBIND_MODE}"
    else
      echo "  [!] ${k}: rebind failed - see output above" >&2
    fi
    echo
  done
  echo "Done."
  exit 0
fi

# --- Build the selection set from flags, if that's the mode we're in. (A
# bash associative array is a set, so selecting the same script via more
# than one flag is a no-op the second time - nothing runs twice.) ---
if [[ "$RUN_MODE" == "flags" ]]; then
  if [[ $INSTALL_ALL -eq 1 ]]; then
    echo "[*] --installAll: core system setup + AI models + system upgrade + Tailscale"
    for k in "${CORE_KEYS[@]}"; do SELECTED[$k]=1; done
    SELECTED[llama]=1; SELECTED[whisper]=1; SELECTED[wyomingwhisper]=1; SELECTED[piper]=1
    SELECTED[sysupgrade]=1
    SELECTED[tailscale]=1
  fi
  if [[ $INSTALL_MODELS -eq 1 ]]; then
    echo "[*] --installModels: llama.cpp + whisper.cpp + Wyoming-whisper bridge + wyoming-piper"
    SELECTED[llama]=1; SELECTED[whisper]=1; SELECTED[wyomingwhisper]=1; SELECTED[piper]=1
  fi
  if [[ $INSTALL_BACKUP -eq 1 ]]; then
    echo "[*] --installBackupAPI: backup + control API"
    SELECTED[backup]=1
  fi
  echo
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
    bash "$full_path"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      status="OK"
      break
    elif [[ $rc -eq 2 ]]; then
      # Exit code 2 is this project's convention for "already installed,
      # and an auto-accept flag declined to overwrite it automatically" -
      # see the 5 service installers (llama/whisper/piper/wyoming-whisper/
      # backup). Not a transient failure, so retrying won't change
      # anything - stop here instead of burning through attempts.
      status="ALREADY INSTALLED - rerun without --bypassAllChecks/--bypassInstallerChecks to be prompted for overwrite"
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
