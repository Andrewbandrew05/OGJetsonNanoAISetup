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

**Pinned to `wyoming-piper` tag `v1.6.3`, not `main`.** Commit `a9bedf7`
("Use piper1-gpl") removed the `--piper <path>` flag entirely and switched
`wyoming-piper` to import `piper1-gpl` as a library instead of shelling out
to an external binary - which drags the glibc 2.28+ requirement straight
back in. `v1.6.3` is the last tag before that change; `v2.0.0` is the first
tag with it. If you ever bump this pin, expect the service to crash-loop
with `unrecognized arguments: --piper ...` until the `ExecStart` line in
the systemd unit is updated to match whatever the new version's CLI
actually looks like (check with `.venv/bin/python3 -m wyoming_piper --help`
in `/opt/wyoming-piper/wyoming-piper` first).

If the service fails to start for some other reason, check
`journalctl -u wyoming-piper.service -n 50` for the actual error.
