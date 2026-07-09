#!/bin/bash
#
# python39_upgrade.sh
#
# Builds and installs Python 3.9 from source on the Jetson Nano (Ubuntu
# 18.04 Bionic), via `make altinstall` so it never touches the system's
# default python3.
#
# Why from source: wyoming-piper's installer used to grab python3.9 from
# the deadsnakes PPA, but that PPA no longer publishes builds for Bionic -
# there's no distro package left to install. Compiling from python.org is
# the reliable path now.
#
# `altinstall` (not `install`) means:
#   - Installs as /usr/local/bin/python3.9 only - never overwrites/symlinks
#     over /usr/bin/python3, so the Jetson's existing Python 3.6/3.8 stay
#     exactly as they are.
#   - venv/ensurepip/distutils are already part of this build (they're only
#     split into separate apt packages on Debian/Ubuntu's own python3.9
#     packaging, not in an upstream source build), so nothing else needs
#     installing for wyoming-piper's venv setup to work.
#
# Idempotent: skips the whole build if python3.9 is already on PATH.
# Deliberately skips --enable-optimizations (PGO): that reruns Python's own
# test suite during the build for a modest speedup, which roughly doubles
# build time and is more likely to hit a flaky test on constrained/embedded
# hardware - not worth it for an unattended background build.
#
# Usage:
#   sudo ./python39_upgrade.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

PYTHON_VERSION="3.9.18"
SRC_DIR="/usr/src"
BUILD_DIR="${SRC_DIR}/Python-${PYTHON_VERSION}"

echo "=== Python ${PYTHON_VERSION} Install (source build) ==="

if command -v python3.9 >/dev/null 2>&1; then
  echo "[*] python3.9 already present ($(command -v python3.9)), skipping build."
  python3.9 --version
  exit 0
fi

echo "[*] Installing build dependencies..."
apt-get update -y
apt-get install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
  libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev \
  libbz2-dev wget

echo "[*] Downloading Python ${PYTHON_VERSION} source..."
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"
if [[ ! -f "Python-${PYTHON_VERSION}.tgz" ]]; then
  wget -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"
fi
rm -rf "$BUILD_DIR"
tar xzf "Python-${PYTHON_VERSION}.tgz"
cd "$BUILD_DIR"

echo "[*] Configuring..."
./configure --prefix=/usr/local

echo "[*] Building (this takes a while on Jetson Nano - be patient)..."
make -j"$(nproc)"

echo "[*] Installing via altinstall (won't touch the system's default python3)..."
make altinstall

echo "[*] Cleaning up build directory..."
cd /
rm -rf "$BUILD_DIR"

echo
echo "=== Done ==="
python3.9 --version
echo "Installed at: $(command -v python3.9)"
