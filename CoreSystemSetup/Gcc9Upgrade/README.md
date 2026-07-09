# gcc-9 Upgrade

Ubuntu 18.04 (Bionic)'s default apt repos only go up to gcc-8, but
whisper.cpp's CUDA build specifically needs gcc-9 - `ggml-quants.c` uses
NEON multi-vector load intrinsics (`vld1q_s8_x4`/`vld1q_u8_x4`) that were
only added to GCC's ARM NEON headers in GCC 9. This script installs
gcc-9/g++-9 via the `ubuntu-toolchain-r/test` PPA, which still backports
newer GCC versions to Bionic.

Idempotent - skips the install entirely if gcc-9 and g++-9 are already
present. Safe to run standalone (`sudo ./gcc9_upgrade.sh`) or as part of
`setup.sh`, where it runs right after the Python 3.9 build so both are
ready before `whisper.cppSetup/install-whisper-cpp.sh` needs them.
