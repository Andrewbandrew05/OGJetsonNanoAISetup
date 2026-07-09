#!/bin/bash
#
# gcc9_upgrade.sh
#
# Installs gcc-9/g++-9 on the Jetson Nano (Ubuntu 18.04 Bionic) via the
# ubuntu-toolchain-r/test PPA. Bionic's own default repos only go up to
# gcc-8, but whisper.cpp's CUDA build specifically needs gcc-9 -
# ggml-quants.c uses NEON multi-vector load intrinsics
# (vld1q_s8_x4/vld1q_u8_x4) that were only added to GCC's ARM NEON headers
# in GCC 9, and gcc-7 (Bionic's default) or gcc-8 don't have them.
#
# Idempotent: skips the install entirely if gcc-9 and g++-9 are already
# present.
#
# Usage:
#   sudo ./gcc9_upgrade.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

echo "=== gcc-9 / g++-9 Install ==="

if command -v gcc-9 >/dev/null 2>&1 && command -v g++-9 >/dev/null 2>&1; then
  echo "[*] gcc-9/g++-9 already present, skipping."
  gcc-9 --version
  exit 0
fi

echo "[*] Adding ubuntu-toolchain-r/test PPA (Bionic's default repos top out at gcc-8)..."
apt-get update -y
apt-get install -y software-properties-common
add-apt-repository -y ppa:ubuntu-toolchain-r/test
apt-get update -y

echo "[*] Installing gcc-9/g++-9..."
apt-get install -y gcc-9 g++-9

echo
echo "=== Done ==="
gcc-9 --version
g++-9 --version
