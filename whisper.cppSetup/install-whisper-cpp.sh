#!/usr/bin/env bash
#
# install-whisper-cpp.sh
#
# Builds whisper.cpp v1.5.4 with CUDA (cuBLAS) support on an original
# Jetson Nano (Maxwell GPU, compute capability 5.3, CUDA 10.2) and installs
# it as a systemd service.
#
# Target: JetPack 4.6.x, Ubuntu 18.04 (Bionic), CUDA 10.2, aarch64.
# Will NOT work as-is on Jetson Orin/Xavier (different compute capability --
# change CUDA_ARCH below) or newer JetPack/CUDA versions (the patches in this
# script work around bugs specific to old GCC/CUDA combos and may not be
# needed, or may need adjusting, on newer systems).
#
# See README.md in this repo for a full explanation of why each patch below
# is necessary.
#
# Default port: 8080 (plain HTTP REST API, NOT the Wyoming protocol - see
# README.md). Override with WHISPER_SERVER_PORT=9000, or via setup.sh:
# --whisperPort=9000
#
# Model: defaults to tiny.en. small.en technically loads and runs fine
# under CUDA on its own, but real-world testing with the full stack
# running together (llama.cpp + wyoming-piper + function-calling overhead)
# showed it's too slow in practice - tiny.en is the one that actually
# feels responsive end-to-end. small.en is still available for anyone who
# wants to trade speed for accuracy and has the headroom for it. If
# WHISPER_MODEL is set (or via setup.sh: --whisperModel=...), that model is
# used directly with no prompt - e.g. WHISPER_MODEL=small.en. If it's unset
# AND an auto-accept flag is active (--bypassAllChecks/
# --bypassInstallerChecks), tiny.en is used automatically rather than
# hanging on a prompt during an unattended run. Otherwise (plain
# interactive run, nothing set), this asks which model to use and explains
# the tradeoffs - press Enter for the tiny.en default, or pick another.
#
# If whisper-cpp-server.service already exists, this asks before
# overwriting it (rebuilding takes several minutes on Jetson Nano). Under
# setup.sh's --bypassAllChecks/--bypassInstallerChecks, it does NOT
# overwrite automatically - it skips and exits 2 instead, which setup.sh
# surfaces as a distinct "already installed" result rather than retrying
# or silently clobbering an existing install. Rerun this script directly
# (without those flags) to be prompted for overwrite.

set -euo pipefail

WHISPER_DIR="/opt/whisper.cpp"
WHISPER_VERSION="v1.5.4"
CUDA_ARCH="sm_53"          # Jetson Nano (original). Orin Nano = sm_87, Xavier = sm_72.
SERVICE_USER="${SUDO_USER:-$USER}"
SERVER_PORT="${WHISPER_SERVER_PORT:-8080}"

if [[ -f /etc/systemd/system/whisper-cpp-server.service ]]; then
  if [[ "${NANO_SETUP_AUTO_YES:-0}" == "1" || "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
    echo "[!] whisper-cpp-server.service is already installed."
    echo "[!] Auto-accept flags are active, but overwriting an existing install"
    echo "    (a several-minute rebuild) is too big a decision for a bypass flag"
    echo "    to make silently - skipping instead."
    echo "[!] whisper.cpp install FAILED: already installed - rerun this script"
    echo "    explicitly, without --bypassAllChecks/--bypassInstallerChecks, to"
    echo "    be prompted for whether to overwrite it."
    exit 2
  fi
  read -rp "whisper.cpp already appears to be installed. Overwrite/reinstall? [y/N]: " OVERWRITE_CHOICE
  case "${OVERWRITE_CHOICE,,}" in
    y|yes) echo "[*] Proceeding with reinstall..." ;;
    *) echo "Leaving the existing install untouched. Nothing changed."; exit 0 ;;
  esac
fi

# --- Model selection -------------------------------------------------------
if [[ -n "${WHISPER_MODEL:-}" ]]; then
  MODEL="$WHISPER_MODEL"
  echo "[*] Using model: ${MODEL} (from WHISPER_MODEL)"
elif [[ "${NANO_SETUP_AUTO_YES:-0}" == "1" || "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
  # Auto-accept flags are active and no explicit model was requested - use
  # the recommended default rather than hanging on a prompt during an
  # unattended run.
  MODEL="tiny.en"
  echo "[*] Auto-accept active - defaulting to model: tiny.en"
  echo "    (set WHISPER_MODEL=tiny.en|base.en|small.en|medium.en to pick a"
  echo "    different one non-interactively next time)"
else
  echo "Which whisper.cpp model would you like to use?"
  echo
  echo "  1) tiny.en   - Recommended (~39M params). The one that actually"
  echo "                 feels responsive once llama.cpp, wyoming-piper,"
  echo "                 and function-calling overhead are all running"
  echo "                 alongside it - real-world testing found the"
  echo "                 bigger options below too slow in practice for"
  echo "                 the full stack, even though they load and run"
  echo "                 fine on their own. Occasionally misses uncommon"
  echo "                 words/names."
  echo "  2) base.en   - The old default (~74M params). Runs roughly"
  echo "                 real-time standalone, but noticeably adds to"
  echo "                 total response time once the rest of the stack"
  echo "                 is running too."
  echo "  3) small.en  - ~3x base.en's size (~244M params). Meaningfully"
  echo "                 better accuracy on uncommon words/names, but"
  echo "                 confirmed too slow in practice alongside"
  echo "                 llama.cpp + wyoming-piper on this hardware."
  echo "                 Only pick this if accuracy matters more to you"
  echo "                 than response speed."
  echo "  4) medium.en - Best accuracy of these options, but ~3x"
  echo "                 small.en's size again (~769M params). Likely to"
  echo "                 feel very slow, and may not comfortably fit in"
  echo "                 memory alongside everything else running. Only"
  echo "                 worth trying if you've confirmed you have the"
  echo "                 memory/speed headroom for it (check 'free -h'"
  echo "                 with everything else already running)."
  echo
  read -rp "Press Enter for the recommended default (tiny.en), or type a number [1-4]: " MODEL_CHOICE
  case "$MODEL_CHOICE" in
    2) MODEL="base.en" ;;
    3) MODEL="small.en" ;;
    4) MODEL="medium.en" ;;
    ""|1) MODEL="tiny.en" ;;
    *)
      echo "[!] Unrecognized choice '$MODEL_CHOICE' - defaulting to tiny.en."
      MODEL="tiny.en"
      ;;
  esac
  echo "[*] Using model: ${MODEL}"
fi

echo "==> [1/7] Installing build dependencies"
sudo apt update
sudo apt install -y build-essential git gcc-9 g++-9 python3

echo "==> [2/7] Verifying CUDA toolkit is present"
if [ ! -x /usr/local/cuda/bin/nvcc ]; then
  echo "ERROR: nvcc not found at /usr/local/cuda/bin/nvcc."
  echo "Install the CUDA toolkit (comes with JetPack) before running this script."
  exit 1
fi
export PATH="/usr/local/cuda/bin:$PATH"
nvcc --version

echo "==> [3/7] Cloning whisper.cpp ${WHISPER_VERSION} into ${WHISPER_DIR}"
sudo mkdir -p "$WHISPER_DIR"
sudo chown "$SERVICE_USER":"$SERVICE_USER" "$WHISPER_DIR"
if [ ! -d "$WHISPER_DIR/.git" ]; then
  git clone https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
fi
cd "$WHISPER_DIR"
git fetch --tags
git checkout "$WHISPER_VERSION"
git reset --hard
git clean -fdx

echo "==> [4/7] Patching Makefile"

# --- Patch A ---------------------------------------------------------------
# Bug: the ggml-cuda.o rule/recipe is defined *inside* an
# "ifdef WHISPER_CUBLAS ... endif" block. On GNU Make 4.1 (Jetson's default),
# a rule defined inside a conditional can cause Make's recipe-parsing state
# to leak past the "endif" and swallow a later, unrelated tab-indented
# variable assignment elsewhere in the file as if it were a shell command.
# Symptom: "make: CFLAGS: Command not found" pointing at the ggml-cuda.o
# recipe line, even though that line is untouched.
# Fix: relocate the aarch64 "-mcpu=native" block earlier in the file, before
# any rule is defined inside a conditional block.
python3 - << 'PYEOF'
import re
path = "Makefile"
text = open(path).read()

block_re = re.compile(
    r"\nifneq \(\$\(filter aarch64%,\$\(UNAME_M\)\),\)\n"
    r"\tCFLAGS   \+= -mcpu=native\n"
    r"\tCXXFLAGS \+= -mcpu=native\nendif\n"
)
m = block_re.search(text)
if m:
    block = m.group(0)
    text = text[:m.start()] + "\n" + text[m.end():]
    text = text.replace("\nifdef WHISPER_OPENBLAS\n", block + "\nifdef WHISPER_OPENBLAS\n", 1)
    open(path, "w").write(text)
    print("  Patch A applied: relocated -mcpu=native block")
else:
    print("  Patch A skipped: block not found in expected form (already patched?)")
PYEOF

# --- Patch B ---------------------------------------------------------------
# Bug: nvcc has its own "-m<bitwidth>" option family (e.g. -m64) and
# intercepts anything starting with "-m" before handing args off via
# --forward-unknown-to-host-compiler. So "-mcpu=native" (needed for plain
# gcc/g++ builds) breaks nvcc specifically with:
# "nvcc fatal : 'cpu=native': expected a number"
# Fix: strip -mcpu=native only from the flags passed to nvcc's recipe.
if grep -q '\$(NVCC) \$(NVCCFLAGS) \$(CXXFLAGS) -Wno-pedantic -c \$< -o \$@' Makefile; then
  sed -i 's|\$(NVCC) \$(NVCCFLAGS) \$(CXXFLAGS) -Wno-pedantic -c \$< -o \$@|$(NVCC) $(NVCCFLAGS) $(filter-out -mcpu=native,$(CXXFLAGS)) -Wno-pedantic -c $< -o $@|' Makefile
  echo "  Patch B applied: stripped -mcpu=native from nvcc recipe"
else
  echo "  Patch B skipped: nvcc recipe line not found in expected form (already patched?)"
fi

echo "==> [5/7] Building (this takes several minutes on Jetson Nano -- be patient)"
# gcc-9 is required, not gcc-7 (Bionic's default) or gcc-8: ggml-quants.c
# uses NEON multi-vector load intrinsics (vld1q_s8_x4, vld1q_u8_x4) that
# were only added to GCC's ARM NEON headers in GCC 9.
make -j1 server main WHISPER_CUBLAS=1 CUDA_ARCH_FLAG="$CUDA_ARCH" CC=gcc-9 CXX=g++-9

echo "==> [6/7] Downloading model: ${MODEL}"
bash ./models/download-ggml-model.sh "$MODEL"

echo "==> [7/7] Cleaning up build artifacts"
rm -f *.o

echo "==> Installing systemd service (whisper-cpp-server.service)"
sudo tee /etc/systemd/system/whisper-cpp-server.service > /dev/null << EOF
[Unit]
Description=whisper.cpp CUDA STT server
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${WHISPER_DIR}
Environment="PATH=/usr/local/cuda/bin:/usr/bin:/bin"
Environment="LD_LIBRARY_PATH=/usr/local/cuda/lib64"
ExecStart=${WHISPER_DIR}/server -m ${WHISPER_DIR}/models/ggml-${MODEL}.bin --host 127.0.0.1 --port ${SERVER_PORT} --best-of 1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now whisper-cpp-server.service
sleep 3

echo ""
echo "==> Service status:"
sudo systemctl status whisper-cpp-server.service --no-pager || true

echo ""
echo "Done. whisper.cpp CUDA server is running at http://127.0.0.1:${SERVER_PORT} (localhost only)."
echo "Test it with a wav file:"
echo "  curl 127.0.0.1:${SERVER_PORT}/inference -H \"Content-Type: multipart/form-data\" -F file=@/path/to/your.wav -F response_format=text"
