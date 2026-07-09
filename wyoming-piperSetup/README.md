# Piper setup

Installs Piper TTS as a Wyoming-protocol systemd service (`wyoming-piper`),
listening on port 10200.

CPU-only by design: Piper's CUDA-accelerated ONNX Runtime path only exists
for newer JetPack/CUDA builds (Orin-series Jetsons), and the original
Nano's CUDA 10.2 is too old for any current ONNX Runtime GPU execution
provider. It uses the older `rhasspy/piper` C++ binary release rather than
the actively-maintained `piper-tts` pip package, since that one requires
glibc 2.28+ and the Nano's Ubuntu 18.04 ships glibc 2.27.

**Requires Python 3.9** on PATH - Ubuntu 18.04 doesn't ship it, and the
deadsnakes PPA this script used to fall back to no longer publishes builds
for Bionic. Run `CoreSystemSetup/Python39Upgrade/python39_upgrade.sh`
first (it's wired into `setup.sh`'s core order automatically, before the
optional installs) rather than relying on this script to fetch it itself.

If the service fails to start, check
`journalctl -u wyoming-piper.service -n 50` - the most likely cause is the
`--piper`/`--voice` flag names differing from what `wyoming_piper --help`
actually shows for the installed version (this script prints that output
during install so you can compare).
