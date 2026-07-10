# Piper setup

Installs Piper TTS as a Wyoming-protocol systemd service (`wyoming-piper`),
listening on port 10200 (override with `WYOMING_PIPER_PORT=10201
./install-wyoming-piper.sh`, or via `setup.sh`: `--piperPort=10201`).

CPU-only by design: Piper's CUDA-accelerated ONNX Runtime path only exists
for newer JetPack/CUDA builds (Orin-series Jetsons), and the original
Nano's CUDA 10.2 is too old for any current ONNX Runtime GPU execution
provider. It uses the older `rhasspy/piper` C++ binary release rather than
the actively-maintained `piper-tts` pip package, since that one requires
glibc 2.28+ and the Nano's Ubuntu 18.04 ships glibc 2.27.

**The prebuilt piper release itself needs one library rebuilt.** Its
bundled `libespeak-ng.so.1` needs glibc 2.29 - one version newer than what
Ubuntu 18.04 ships - so loading it as-is fails with
`version 'GLIBC_2.29' not found`. The install script automatically rebuilds
just that one library from source (pinned to the exact commit
`piper-phonemize` itself builds against - see its `CMakeLists.txt`) against
this system's actual glibc, and swaps it in over the bundled one.
`onnxruntime` and `piper_phonemize` both resolve cleanly as shipped, so
this stays quick and never touches the much heavier `onnxruntime` build.
Do **not** try to fix this by upgrading the system's own glibc instead -
Ubuntu 18.04's entire package repository is built and tested against glibc
2.27; forcing a newer one in place risks breaking far more than Piper (up
to and including an unbootable system), for no benefit over rebuilding
this one small library.

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

## Binding

Defaults to `0.0.0.0` (reachable by anyone on your LAN). Pass
`--tailscale` (or set `WYOMING_PIPER_BIND_TAILSCALE=1`) to restrict it to
the Tailscale interface instead; falls back to `127.0.0.1` if `tailscale0`
never comes up, never silently to LAN-wide. Already installed and just
want to flip that setting without a full reinstall?
`sudo ./install-wyoming-piper.sh --rebind [--tailscale]`, or
`sudo ./setup.sh --rebindTailscale` / `--rebindLan` to flip every
already-installed bind-aware service at once.

## Reinstalling / uninstalling

If `wyoming-piper.service` already exists, running the install script
again asks before overwriting it. Under `setup.sh`'s
`--bypassAllChecks`/`--bypassInstallerChecks` it does **not** overwrite
automatically - it skips and reports "already installed" instead, so
re-run it directly (without those flags) to be prompted.

To remove it: `sudo ./uninstall-wyoming-piper.sh` (or via `uninstall.sh
--uninstallPiper`) - stops/disables the service and removes
`/opt/wyoming-piper` (piper binary, venv, and downloaded voice data).
