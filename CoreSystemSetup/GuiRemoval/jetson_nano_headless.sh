#!/bin/bash
#
# jetson_nano_headless.sh
#
# Strips the GUI/desktop environment off an original Jetson Nano running
# L4T Ubuntu, sets the system to boot to a text console permanently, and
# removes packages/files that are no longer needed as a result.
#
# SAFE BY DESIGN:
#  - Does NOT touch nvidia-l4t-* packages (GPU/CUDA/multimedia drivers).
#    Removing those can break CUDA support or the ability to reflash.
#  - Backs up the installed package list before purging anything.
#  - Requires an explicit "yes" confirmation before making changes.
#  - Meant to be run over SSH, not from the desktop session itself.
#
# Usage:
#   chmod +x jetson_nano_headless.sh
#   sudo ./jetson_nano_headless.sh
#   sudo ./jetson_nano_headless.sh --yes   # skip the confirmation prompt
#
# Non-interactive: set NANO_SETUP_AUTO_YES_OS=1 (what setup.sh's
# --bypassAllChecks does) to skip the confirmation the same way --yes does.
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
if [[ "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
  AUTO_YES=1
fi

LOGFILE="/var/log/jetson_headless_$(date +%Y%m%d_%H%M%S).log"
BACKUP_LIST="/root/pkg_list_before_headless_$(date +%Y%m%d_%H%M%S).txt"

echo "=== Jetson Nano Headless Converter ==="
echo "This will:"
echo "  1. Set the boot target to text console (multi-user.target) permanently"
echo "  2. Purge desktop/GUI packages (gdm3, lightdm, gnome/unity, xorg, etc.)"
echo "  3. Autoremove now-unused dependencies"
echo "  4. Clean apt caches and orphaned config/log files from those packages"
echo
echo "It will NOT remove nvidia-l4t-* packages (CUDA/GPU/driver stack)."
echo "A full package list backup will be saved to: $BACKUP_LIST"
echo "A log of everything done will be saved to: $LOGFILE"
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

exec > >(tee -a "$LOGFILE") 2>&1

echo "[*] Backing up current package list..."
dpkg -l > "$BACKUP_LIST"

echo "[*] Setting default boot target to multi-user (text console)..."
systemctl set-default multi-user.target

# List of GUI/desktop-related package name patterns to purge.
# Uses wildcard matching via apt-get; nvidia-l4t-* is explicitly excluded
# by never matching that pattern here.
GUI_PACKAGES=(
  "ubuntu-desktop*"
  "ubuntu-session*"
  "gnome-*"
  "gdm3*"
  "gdm*"
  "lightdm*"
  "unity*"
  "compiz*"
  "xserver-xorg*"
  "xorg*"
  "x11-*"
  "libx11-*"
  "libxfont*"
  "xinit*"
  "xdg-desktop-portal*"
  "plymouth-theme*"
  "nautilus*"
  "gnome-terminal*"
  "gnome-shell*"
  "gnome-control-center*"
  "network-manager-gnome*"
  "totem*"
  "rhythmbox*"
  "libreoffice*"
  "gnome-software*"
  "software-properties-gtk*"
  "yelp*"
  "empathy*"
  "shotwell*"
  "thunderbird*"
  "transmission-gtk*"
  "cheese*"
  "gnome-screenshot*"
  "evince*"
)

echo "[*] Resolving which of the above are actually installed..."
INSTALLED_MATCHES=()
for pattern in "${GUI_PACKAGES[@]}"; do
  matches=$(dpkg-query -W -f='${Package}\n' "$pattern" 2>/dev/null || true)
  if [[ -n "$matches" ]]; then
    while IFS= read -r pkg; do
      # Safety net: never touch nvidia-l4t packages even if a pattern
      # somehow matched them.
      if [[ "$pkg" != nvidia-l4t-* ]]; then
        INSTALLED_MATCHES+=("$pkg")
      fi
    done <<< "$matches"
  fi
done

if [[ ${#INSTALLED_MATCHES[@]} -eq 0 ]]; then
  echo "[*] No matching GUI packages found installed. Skipping purge step."
else
  echo "[*] The following packages will be purged:"
  printf '    %s\n' "${INSTALLED_MATCHES[@]}"
  echo "[*] Purging..."
  apt-get purge -y "${INSTALLED_MATCHES[@]}" || {
    echo "[!] Some packages failed to purge individually; retrying one-by-one..."
    for pkg in "${INSTALLED_MATCHES[@]}"; do
      apt-get purge -y "$pkg" || echo "    [!] Failed to purge $pkg, skipping."
    done
  }
fi

echo "[*] Removing orphaned dependencies..."
apt-get autoremove -y --purge

echo "[*] Cleaning apt cache..."
apt-get autoclean -y
apt-get clean

echo "[*] Removing leftover config/log directories for removed GUI components..."
# These are safe to remove once the corresponding packages are gone;
# apt purge normally handles /etc configs, this catches strays.
STRAY_PATHS=(
  "/etc/X11"
  "/etc/gdm3"
  "/etc/lightdm"
  "/usr/share/gnome"
  "/usr/share/unity"
  "/var/log/gdm3"
  "/var/log/lightdm"
  "/root/.cache/gnome*"
  "/root/.config/gnome*"
)
for path in "${STRAY_PATHS[@]}"; do
  if compgen -G "$path" > /dev/null 2>&1; then
    echo "    Removing $path"
    rm -rf $path
  fi
done

echo "[*] Rebuilding initramfs (in case boot hooks referenced removed packages)..."
update-initramfs -u || echo "    [!] update-initramfs reported an issue, review log."

echo
echo "=== Done ==="
echo "Package list backup: $BACKUP_LIST"
echo "Full log: $LOGFILE"
echo
echo "Reboot now to boot into text-console mode: sudo reboot"
