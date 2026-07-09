#!/bin/bash
#
# uninstall-jtop.sh
#
# Undoes jtop_install.sh: stops/disables/removes the jtop.service systemd
# unit (jetson-stats' pip installer creates this itself as a post-install
# side effect - pip has no hook to undo it, so `pip3 uninstall` alone
# leaves it registered and it crash-loops forever trying to exec a
# now-deleted /usr/local/bin/jtop), uninstalls the jetson-stats pip
# package, and removes the invoking user from the 'jtop' group.
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

JTOP_SERVICE_PRESENT=0
[[ -f /etc/systemd/system/jtop.service ]] && JTOP_SERVICE_PRESENT=1

if ! pip3 show jetson-stats >/dev/null 2>&1 && [[ $JTOP_SERVICE_PRESENT -eq 0 ]]; then
  echo "[*] Nothing to uninstall - jetson-stats isn't installed and no"
  echo "    leftover jtop.service was found."
  exit 0
fi

echo "This will:"
echo "  - Stop and disable jtop.service (jetson-stats' own background"
echo "    stats-collector daemon, registered by its pip install - not"
echo "    something this project's install script created directly)"
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

if [[ $JTOP_SERVICE_PRESENT -eq 1 ]]; then
  echo "[*] Stopping and disabling jtop.service..."
  systemctl stop jtop.service 2>/dev/null || true
  systemctl disable jtop.service 2>/dev/null || true
  rm -f /etc/systemd/system/jtop.service
  systemctl daemon-reload
fi

if pip3 show jetson-stats >/dev/null 2>&1; then
  echo "[*] Uninstalling jetson-stats..."
  pip3 uninstall -y jetson-stats
fi

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [[ -n "$TARGET_USER" ]] && getent group jtop > /dev/null 2>&1; then
  echo "[*] Removing '$TARGET_USER' from the 'jtop' group..."
  gpasswd -d "$TARGET_USER" jtop 2>/dev/null || deluser "$TARGET_USER" jtop 2>/dev/null || true
fi

echo
echo "=== Done ==="
echo "jtop has been uninstalled."
