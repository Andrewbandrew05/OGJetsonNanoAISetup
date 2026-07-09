#!/bin/bash
#
# uninstall-jtop.sh
#
# Undoes jtop_install.sh: uninstalls the jetson-stats pip package and
# removes the invoking user from the 'jtop' group.
#
# Usage:
#   sudo ./uninstall-jtop.sh
#   sudo ./uninstall-jtop.sh --yes   # skip confirmation
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

echo "=== Uninstall jtop (jetson-stats) ==="

if ! pip3 show jetson-stats >/dev/null 2>&1; then
  echo "[*] Nothing to uninstall - jetson-stats isn't installed."
  exit 0
fi

echo "This will:"
echo "  - Uninstall the jetson-stats pip package"
echo "  - Remove $(logname 2>/dev/null || echo "${SUDO_USER:-the invoking user}") from the 'jtop' group"
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

echo "[*] Uninstalling jetson-stats..."
pip3 uninstall -y jetson-stats

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [[ -n "$TARGET_USER" ]] && getent group jtop > /dev/null 2>&1; then
  echo "[*] Removing '$TARGET_USER' from the 'jtop' group..."
  gpasswd -d "$TARGET_USER" jtop 2>/dev/null || deluser "$TARGET_USER" jtop 2>/dev/null || true
fi

echo
echo "=== Done ==="
echo "jtop has been uninstalled."
