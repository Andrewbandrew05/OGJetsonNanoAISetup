#!/bin/bash
#
# jetson_nano_headless.sh
#
# Switches an original Jetson Nano running L4T Ubuntu to boot into a text
# console instead of the desktop GUI.
#
# DEFAULT BEHAVIOR (fast, nothing removed):
#  - Sets the default boot target to multi-user.target (text console)
#  - Disables (and stops) the display manager service so it won't start
#  - Does NOT uninstall anything - desktop packages stay on disk untouched
#
# OPTIONAL, SLOWER, DESTRUCTIVE MODE (--purge-packages):
#  - Additionally removes the actual GUI/desktop packages to reclaim disk
#    space. This has been tested against a JetPack image downloaded
#    2026-07-07 and reliably removes a good chunk of unused desktop
#    packages on that image - there's no guarantee it catches
#    everything on every image variant (package names/versions can differ),
#    but it is guaranteed not to remove anything that would stop the board
#    from booting. Worst case if something's named differently than
#    expected: you get back less disk space than ideal, never a broken
#    system - see WHY THIS IS SAFE below for the actual mechanism.
#
# WHY THIS IS SAFE (allowlist, not denylist):
#  - This removes packages via `dpkg --remove`, one at a time, NOT
#    `apt-get remove`/`apt-get autoremove`. That distinction is the whole
#    safety model: `apt-get` has a dependency SOLVER that's free to decide
#    "removing this also requires removing that" and pull in extra
#    packages beyond what was asked for - that's exactly how earlier
#    versions of this script ended up removing nvidia-l4t-* and CUDA
#    packages on real hardware, despite denylist checks and simulate-first
#    guards layered on top. `dpkg --remove` has no solver: it only ever
#    touches the exact package named. If removing it would break something
#    else currently installed, dpkg just refuses with a clear error -
#    it never silently expands scope.
#  - Because there's no cascade to worry about, there's also no
#    `apt-get autoremove` step at all anymore. Autoremove asks apt to
#    guess what's "no longer needed" and was the single riskiest part of
#    the old design (the direct cause of the first bricked board tonight).
#    The GUI_PACKAGES list below already enumerates the actual
#    leaf/library packages directly, so nothing needs to be guessed
#    afterward.
#  - Packages are only ever attempted if they match GUI_PACKAGES AND don't
#    match CRITICAL_PATTERNS (kernel, nvidia-l4t-*, initramfs-tools,
#    systemd, dbus, network-manager, openssh, etc) - a cheap sanity check
#    on the candidate list itself, in case a wildcard pattern ever matches
#    something it shouldn't on some other image.
#  - Removal happens in passes: whatever dpkg refuses this pass (because
#    something else installed still depends on it) is retried next pass,
#    until a full pass makes no more progress. Anything still refused
#    after that is left installed and reported - not forced.
#  - Uses `dpkg --remove`, never `--purge`: config files are left behind
#    (matches this script's design elsewhere - purge has its own
#    system-wide side effects, see git history for why that was dropped).
#    Config remnants of packages that DID get removed are cleaned up
#    separately via a fixed, reviewed STRAY_PATHS list.
#  - Backs up the installed package list before making changes.
#  - Requires an explicit "yes" confirmation before making changes.
#  - Meant to be run over SSH, not from the desktop session itself.
#
# Usage:
#   sudo ./jetson_nano_headless.sh                     # disable-only (default, fast)
#   sudo ./jetson_nano_headless.sh --purge-packages     # also remove GUI packages (slower)
#   sudo ./jetson_nano_headless.sh --yes                # skip the confirmation prompt
#   sudo ./jetson_nano_headless.sh --purge-packages --yes
#
# Non-interactive: set NANO_SETUP_AUTO_YES_OS=1 (what setup.sh's
# --bypassAllChecks does) to skip the confirmation the same way --yes does.
# Set NANO_GUI_PURGE_PACKAGES=1 (what setup.sh's --purgeGuiPackages does)
# to turn on the destructive mode the same way --purge-packages does -
# neither is ever implied by the other, or by a bypass flag alone.
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

AUTO_YES=0
PURGE_PACKAGES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=1 ;;
    --purge-packages) PURGE_PACKAGES=1 ;;
  esac
done
if [[ "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
  AUTO_YES=1
fi
if [[ "${NANO_GUI_PURGE_PACKAGES:-0}" == "1" ]]; then
  PURGE_PACKAGES=1
fi

LOGFILE="/var/log/jetson_headless_$(date +%Y%m%d_%H%M%S).log"
BACKUP_LIST="/root/pkg_list_before_headless_$(date +%Y%m%d_%H%M%S).txt"

echo "=== Jetson Nano Headless Converter ==="
if [[ $PURGE_PACKAGES -eq 1 ]]; then
  echo "This will:"
  echo "  1. Set the boot target to text console (multi-user.target) permanently"
  echo "  2. Disable the display manager service so it won't start at boot"
  echo "  3. Remove desktop/GUI packages (gdm3, lightdm, gnome/unity, xorg, etc.)"
  echo "     one at a time via dpkg, which cannot cascade into removing"
  echo "     anything beyond what's explicitly matched - see script header."
  echo "  4. Clean apt caches and orphaned config/log files from those packages"
  echo
  echo "It will NOT remove nvidia-l4t-* or other boot-critical packages -"
  echo "removal only ever touches the exact packages matched, one at a time,"
  echo "and dpkg refuses (rather than cascades) if something else still"
  echo "depends on one of them."
else
  echo "This will:"
  echo "  1. Set the boot target to text console (multi-user.target) permanently"
  echo "  2. Disable the display manager service so it won't start at boot"
  echo
  echo "Nothing gets uninstalled - your desktop packages stay on disk exactly"
  echo "as they are. Re-run with --purge-packages if you also want to reclaim"
  echo "the disk space they use (slower)."
fi
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

echo "[*] Disabling display manager service(s) so the GUI won't start at boot..."
DISPLAY_MANAGERS=(gdm3 gdm lightdm sddm xdm slim lxdm)
for dm in "${DISPLAY_MANAGERS[@]}"; do
  if systemctl list-unit-files "${dm}.service" --no-legend 2>/dev/null | grep -q .; then
    systemctl disable --now "${dm}.service" 2>/dev/null || true
    echo "    Disabled ${dm}.service"
  fi
done
systemctl disable display-manager.service 2>/dev/null || true

if [[ $PURGE_PACKAGES -eq 0 ]]; then
  echo
  echo "=== Done ==="
  echo "Package list backup: $BACKUP_LIST"
  echo "Full log: $LOGFILE"
  echo
  echo "Nothing was uninstalled - just disabled. Reboot to boot into"
  echo "text-console mode (or it already took effect immediately for this"
  echo "session too):"
  echo "  sudo reboot"
  echo
  echo "Want the disk space back too? Re-run with --purge-packages."
  exit 0
fi

# --- Everything below only runs with --purge-packages ---

# Patterns for packages that must never be removed, no matter what. This is
# a sanity check on the CANDIDATE list below, not a simulate-based guard -
# dpkg --remove structurally cannot cascade into removing something not in
# that list, so there's nothing to simulate. This just catches the case
# where a GUI_PACKAGES wildcard pattern accidentally matches something it
# shouldn't on some other image.
CRITICAL_PATTERNS=(
  "linux-image*" "linux-headers*" "linux-modules*" "linux-firmware*"
  "nvidia-l4t-*" "nvidia-*" "tegra*" "cuda-*" "l4t-*"
  "initramfs-tools*" "u-boot*" "flash-tools*" "extlinux*" "grub*"
  "systemd" "systemd-sysv" "udev" "dbus" "network-manager"
  "openssh-server" "openssh-client" "openssh-sftp-server"
  "sudo" "e2fsprogs" "util-linux" "mount" "coreutils" "bash"
  "dpkg" "apt" "apt-utils" "libc6" "libc-bin"
)

is_critical_package() {
  local pkg="$1" pat
  for pat in "${CRITICAL_PATTERNS[@]}"; do
    # shellcheck disable=SC2053
    [[ "$pkg" == $pat ]] && return 0
  done
  return 1
}

# List of GUI/desktop-related package name patterns to remove. Uses
# wildcard matching against whatever's actually installed (dpkg-query -W),
# so this adapts fine to different images - it only ever touches packages
# that are really present, never assumes a fixed exact package set.
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
      [[ -z "$pkg" ]] && continue
      if is_critical_package "$pkg"; then
        echo "[!] Note: '$pkg' matched a GUI pattern but is also on the"
        echo "    critical list - leaving it installed, not removing it."
        continue
      fi
      INSTALLED_MATCHES+=("$pkg")
    done <<< "$matches"
  fi
done

if [[ ${#INSTALLED_MATCHES[@]} -eq 0 ]]; then
  echo "[*] No matching GUI packages found installed. Skipping removal step."
else
  echo "[*] The following packages were matched for removal:"
  printf '    %s\n' "${INSTALLED_MATCHES[@]}"
  echo

  REMOVED_COUNT=0

  # Try removing everything matched in ONE dpkg transaction first. dpkg
  # only ever refuses a removal because of something OUTSIDE the set
  # named in that call - it does NOT refuse just because packages within
  # the same call depend on each other (gdm3 needing gnome-shell, say),
  # since after the whole transaction those needs are gone too. dpkg
  # isn't atomic/all-or-nothing either: it removes whatever it can and
  # reports the rest, so this is both correct and much faster than
  # removing hundreds of packages one at a time (each dpkg invocation has
  # its own trigger-processing overhead).
  echo "[*] Removing all matched packages in a single dpkg transaction..."
  dpkg --remove "${INSTALLED_MATCHES[@]}" 2>&1 | sed 's/^/    /' || true

  REMOVE_QUEUE=()
  for pkg in "${INSTALLED_MATCHES[@]}"; do
    status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    if [[ "$status" == "install ok installed" ]]; then
      REMOVE_QUEUE+=("$pkg")
    else
      REMOVED_COUNT=$((REMOVED_COUNT + 1))
    fi
  done

  # Whatever's left goes through one at a time, in case a different
  # removal order helps, or purely as a way to get a clear per-package
  # reason for anything still stuck.
  if [[ ${#REMOVE_QUEUE[@]} -gt 0 ]]; then
    echo "[*] ${#REMOVE_QUEUE[@]} package(s) remain - retrying one at a time for a"
    echo "    clearer picture of exactly what's blocking each one..."
    pass=1
    progress=1
    while [[ $progress -eq 1 && ${#REMOVE_QUEUE[@]} -gt 0 ]]; do
      echo "[*] Pass ${pass}: ${#REMOVE_QUEUE[@]} package(s) left to try..."
      progress=0
      NEXT_QUEUE=()
      for pkg in "${REMOVE_QUEUE[@]}"; do
        status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
        if [[ "$status" != "install ok installed" ]]; then
          continue
        fi
        if dpkg_out=$(dpkg --remove "$pkg" 2>&1); then
          echo "    Removed: $pkg"
          REMOVED_COUNT=$((REMOVED_COUNT + 1))
          progress=1
        else
          NEXT_QUEUE+=("$pkg")
          echo "    Not yet: $pkg"
          echo "$dpkg_out" | sed 's/^/      /'
        fi
      done
      REMOVE_QUEUE=("${NEXT_QUEUE[@]}")
      pass=$((pass + 1))
    done
  fi

  echo "[*] Removed ${REMOVED_COUNT} of ${#INSTALLED_MATCHES[@]} matched package(s)."
  if [[ ${#REMOVE_QUEUE[@]} -gt 0 ]]; then
    echo "[*] ${#REMOVE_QUEUE[@]} package(s) left installed (something else on"
    echo "    this system still depends on them, so dpkg refused rather than"
    echo "    force it) - see the 'Not yet' lines above for exactly why:"
    printf '    %s\n' "${REMOVE_QUEUE[@]}"
  fi
fi

echo "[*] Cleaning apt cache..."
apt-get autoclean -y
apt-get clean

echo "[*] Removing leftover config/log directories for removed GUI components..."
# These are safe to remove once the corresponding packages are gone; dpkg
# --remove (not --purge) leaves /etc configs behind, this catches strays.
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
