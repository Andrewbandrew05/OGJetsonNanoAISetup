#!/bin/bash
#
# uninstall-python39.sh
#
# Undoes python39_upgrade.sh. CPython's source build has no `make
# uninstall` target (and the build directory it would need for that is
# already deleted by the install script), so this removes the known set
# of files a plain `make altinstall` for Python 3.9 creates - never
# touches the system's default python3, same as the install script never
# did.
#
# Usage:
#   sudo ./uninstall-python39.sh
#   sudo ./uninstall-python39.sh --yes   # skip confirmation
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

echo "=== Uninstall Python 3.9 (source altinstall) ==="

if ! command -v python3.9 >/dev/null 2>&1; then
  echo "[*] Nothing to uninstall - python3.9 isn't on PATH."
  exit 0
fi

# Known set of files/dirs `make altinstall` creates for a plain CPython
# 3.9 build with prefix=/usr/local. This deliberately does NOT touch
# /usr/bin/python3 or anything version-generic under /usr/local.
FILES=(
  /usr/local/bin/python3.9
  /usr/local/bin/python3.9-config
  /usr/local/bin/pip3.9
  /usr/local/bin/pydoc3.9
  /usr/local/bin/idle3.9
  /usr/local/bin/2to3-3.9
  /usr/local/lib/libpython3.9.a
  /usr/local/lib/pkgconfig/python-3.9.pc
  /usr/local/lib/pkgconfig/python-3.9-embed.pc
  /usr/local/share/man/man1/python3.9.1
)
DIRS=(
  /usr/local/lib/python3.9
  /usr/local/include/python3.9
  /usr/local/include/python3.9m
)

echo "This will remove Python 3.9's binaries, standard library, and headers"
echo "from /usr/local - anything wyoming-piper/wyoming-whisper installed"
echo "into their own venvs is untouched (venvs bundle their own copy), but"
echo "will stop working if you also remove those venvs since they reference"
echo "this interpreter to be recreated."
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

echo "[*] Removing files..."
for f in "${FILES[@]}"; do
  if [[ -e "$f" ]]; then
    rm -f "$f"
    echo "    Removed $f"
  fi
done

echo "[*] Removing directories..."
for d in "${DIRS[@]}"; do
  if [[ -e "$d" ]]; then
    rm -rf "$d"
    echo "    Removed $d"
  fi
done

echo
echo "=== Done ==="
if command -v python3.9 >/dev/null 2>&1; then
  echo "[!] python3.9 is still on PATH at $(command -v python3.9) - it may"
  echo "    have been installed to a different prefix than expected. Check"
  echo "    manually if you need it fully gone."
else
  echo "Python 3.9 has been uninstalled."
fi
