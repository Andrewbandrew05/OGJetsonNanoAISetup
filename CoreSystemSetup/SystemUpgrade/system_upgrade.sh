#!/bin/bash
#
# system_upgrade.sh
#
# Runs a routine apt update + upgrade to bring already-installed packages
# up to date.
#
# Deliberately uses `apt-get upgrade`, not `dist-upgrade`/`full-upgrade`:
# plain `upgrade` only updates packages that are already installed, within
# their current dependency constraints, and never removes a package or
# pulls in a new one to satisfy a changed dependency chain. `dist-upgrade`
# can do both of those things, which is exactly the category of surprise
# this project has spent a lot of effort avoiding elsewhere (see
# CoreSystemSetup/GuiRemoval's comments) - not worth the risk here for a
# routine update step.
#
# Config-file conflicts (e.g. a package shipping an updated
# /etc/whatever.conf when the installed one has local changes) are a
# SEPARATE thing from DEBIAN_FRONTEND=noninteractive - dpkg asks about
# those itself, via its own --force-conf* options, regardless of
# DEBIAN_FRONTEND. Without handling them, apt-get upgrade can hang
# mid-run waiting for input that never comes on an unattended box.
#
# Default is to keep the currently-installed version on a genuine
# conflict (--force-confold, matches dpkg's own stated default), since on
# a Jetson a "locally modified" config file (e.g.
# /etc/ld.so.conf.d/nvidia-tegra.conf) is often something JetPack's own
# first-boot setup customized for this specific board. That said, this is
# a genuine judgment call, not a clear-cut safety issue either way -
# vendor-generated files like that one are also plausibly meant to track
# whatever the currently-installed package version expects, in which case
# taking the new version is the more correct choice. Pass --force-new-configs
# (or set NANO_SYSUPGRADE_FORCE_NEW=1) to always take the package
# maintainer's version instead.
#
# Usage:
#   sudo ./system_upgrade.sh                       # keep local config on conflict (default)
#   sudo ./system_upgrade.sh --force-new-configs    # take the new package version on conflict
#
# Non-interactive: setup.sh's --forceNewConfigs sets NANO_SYSUPGRADE_FORCE_NEW=1
# to get the same effect as --force-new-configs.
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

FORCE_NEW=0
for arg in "$@"; do
  case "$arg" in
    --force-new-configs) FORCE_NEW=1 ;;
  esac
done
if [[ "${NANO_SYSUPGRADE_FORCE_NEW:-0}" == "1" ]]; then
  FORCE_NEW=1
fi

if [[ $FORCE_NEW -eq 1 ]]; then
  CONFFILE_POLICY="--force-confnew"
else
  CONFFILE_POLICY="--force-confold"
fi

export DEBIAN_FRONTEND=noninteractive

echo "=== System Package Update/Upgrade ==="
echo "[*] Config file conflict policy: ${CONFFILE_POLICY}"

echo "[*] Updating package lists..."
apt-get update -y

echo "[*] Upgrading installed packages..."
apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="${CONFFILE_POLICY}"

echo
echo "=== Done ==="
echo "If a new kernel or core library was upgraded, a reboot may be needed"
echo "for it to fully take effect: sudo reboot"
