#!/bin/bash
#
# uninstall-gui-removal.sh
#
# Undoes jetson_nano_headless.sh, for either mode it might have run in:
#
#  1. Always: resets the default boot target back to graphical.target and
#     re-enables the display manager service(s) so the GUI comes back on
#     next boot. (Doesn't force-start the GUI in the current session -
#     this is meant to be run over SSH same as the original script.)
#  2. If --purge-packages was used, offers to reinstall whatever got
#     removed: reads the OLDEST /root/pkg_list_before_headless_*.txt
#     backup (the truest "before any of this ran" snapshot, in case GUI
#     removal was run more than once), diffs it against what's currently
#     installed, and offers to apt-get install whatever's missing that
#     was there originally. If disable-only mode was used, nothing will
#     be missing and this step is a no-op - it doesn't need to know which
#     mode actually ran, it just checks reality.
#
# Usage:
#   sudo ./uninstall-gui-removal.sh
#   sudo ./uninstall-gui-removal.sh --yes   # skip confirmations
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

echo "=== Uninstall GUI Removal ==="
echo "This will:"
echo "  1. Set the default boot target back to graphical.target"
echo "  2. Re-enable the display manager service(s) (won't force-start the"
echo "     GUI in this session - takes effect on next boot)"
echo "  3. Check whether any packages were purged by a previous"
echo "     --purge-packages run, and offer to reinstall them"
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

echo "[*] Setting default boot target back to graphical.target..."
systemctl set-default graphical.target

echo "[*] Re-enabling display manager service(s) for next boot..."
DISPLAY_MANAGERS=(gdm3 gdm lightdm sddm xdm slim lxdm)
for dm in "${DISPLAY_MANAGERS[@]}"; do
  if systemctl list-unit-files "${dm}.service" --no-legend 2>/dev/null | grep -q .; then
    systemctl enable "${dm}.service" 2>/dev/null || true
    echo "    Enabled ${dm}.service"
  fi
done
systemctl enable display-manager.service 2>/dev/null || true

echo
echo "[*] Checking for packages removed by a previous --purge-packages run..."
shopt -s nullglob
BACKUP_LISTS=(/root/pkg_list_before_headless_*.txt)
shopt -u nullglob

if [[ ${#BACKUP_LISTS[@]} -eq 0 ]]; then
  echo "[*] No /root/pkg_list_before_headless_*.txt backup found - either"
  echo "    GUI removal was never run, or the backup was already deleted."
  echo "    Nothing to check for package restoration."
else
  OLDEST_LIST=$(printf '%s\n' "${BACKUP_LISTS[@]}" | sort | head -1)
  echo "[*] Using oldest backup found: ${OLDEST_LIST}"
  echo "    (the state closest to before any of this project's scripts ran,"
  echo "    in case GUI removal was run more than once)"

  ORIGINAL_PACKAGES=$(awk '$1=="ii"{print $2}' "$OLDEST_LIST" | sort -u)
  CURRENT_PACKAGES=$(dpkg -l | awk '$1=="ii"{print $2}' | sort -u)
  MISSING_PACKAGES=$(comm -23 <(echo "$ORIGINAL_PACKAGES") <(echo "$CURRENT_PACKAGES"))

  if [[ -z "$MISSING_PACKAGES" ]]; then
    echo "[*] Nothing is missing compared to the backup - either disable-only"
    echo "    mode was used (nothing was ever removed), or everything's"
    echo "    already back. No package reinstallation needed."
  else
    MISSING_COUNT=$(echo "$MISSING_PACKAGES" | grep -c .)
    echo
    echo "Found ${MISSING_COUNT} package(s) that were installed before but"
    echo "aren't now (removed by an earlier --purge-packages run):"
    echo "$MISSING_PACKAGES" | sed 's/^/    /'
    echo
    echo "Reinstalling brings back the desktop packages (and the disk space"
    echo "they use). Some packages may no longer be available if apt's"
    echo "sources have changed since - those will just fail individually,"
    echo "the rest will still install."
    echo

    if [[ $AUTO_YES -eq 1 ]]; then
      echo "Reinstall these ${MISSING_COUNT} package(s)? Type 'yes' to proceed: yes (auto-accepted)"
      DO_REINSTALL="yes"
    else
      read -rp "Reinstall these ${MISSING_COUNT} package(s)? Type 'yes' to proceed, anything else to skip: " DO_REINSTALL
    fi

    if [[ "$DO_REINSTALL" == "yes" ]]; then
      echo "[*] Updating package lists..."
      apt-get update -y || true
      echo "[*] Reinstalling..."
      # shellcheck disable=SC2086
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING_PACKAGES; then
        echo "[!] Some packages failed to install as a batch; retrying one by" >&2
        echo "    one so the ones that CAN be reinstalled still are..." >&2
        while IFS= read -r pkg; do
          [[ -z "$pkg" ]] && continue
          DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || echo "    [!] Failed to reinstall $pkg, skipping."
        done <<< "$MISSING_PACKAGES"
      fi
    else
      echo "[*] Skipped package reinstallation."
    fi
  fi
fi

echo
echo "=== Done ==="
echo "Reboot to boot back into the GUI: sudo reboot"
