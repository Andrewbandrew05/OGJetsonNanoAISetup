# Wyoming-Whisper Bridge

A small Wyoming-protocol bridge that sits in front of the whisper.cpp
server installed by `whisper.cppSetup`. It does **not** load its own
whisper model - `whisper.cppSetup`'s server (see
`whisper.cppSetup/README.md`) exposes a plain REST endpoint, not the
Wyoming protocol Home Assistant's Wyoming integration expects, so this
just forwards whatever audio HA streams to it straight to that
already-running server's `/inference` endpoint and relays the
transcription back. One whisper model/process on the box, never two.

## Requirements

- `whisper.cppSetup/install-whisper-cpp.sh` must be run first - this has
  nothing to transcribe with otherwise. `setup.sh`'s `--installAll` and
  `--installModels` packages run this right after whisper.cpp
  automatically; the systemd unit also declares
  `After=`/`Wants=whisper-cpp-server.service` as a second layer of
  ordering, independent of install order.
- Python 3.9 (shared with `wyoming-piperSetup` - installed by
  `CoreSystemSetup/Python39Upgrade/python39_upgrade.sh`, which runs
  automatically before this in `setup.sh`'s core order).

## Install

```bash
sudo ./install-wyoming-whisper.sh
```

Installs a venv + the `wyoming` and `requests` pip packages into
`/opt/wyoming-whisper`, and a systemd service (`wyoming-whisper.service`)
listening on port 10300 by default.

Override the port with `WYOMING_WHISPER_PORT=10301 ./install-wyoming-whisper.sh`,
or via `setup.sh`: `--wyomingWhisperPort=10301`.

Points at whisper.cpp's server via `WHISPER_SERVER_PORT` (the same env var
`whisper.cppSetup` reads) if set, else `8080` - if you customized
whisper.cpp's port, this picks it up automatically without needing to be
told twice.

## Home Assistant

Settings > Devices & Services > Add Integration > Wyoming Protocol,
host = `<nano-ip>`, port = `10300` (or whatever you set
`WYOMING_WHISPER_PORT` to).

## How it works

`wyoming_whisper_bridge.py` is a small asyncio service built on the
official `wyoming` Python library:

1. On `AudioStart`/`AudioChunk`/`AudioStop`, it buffers the raw PCM audio
   HA streams in, wraps it in a WAV container, and `POST`s it to
   whisper.cpp's `/inference` endpoint with `response_format=text`.
2. The returned text comes back as a Wyoming `Transcript` event.
3. On `Describe`, it responds with an `Info` event advertising itself as
   an ASR provider so HA's Wyoming integration recognizes it correctly.

This was validated with an end-to-end test (a real instance of this
bridge, a real Wyoming client, and a stub HTTP server standing in for
whisper.cpp) confirming both the `Describe`/`Info` handshake and the full
audio round trip work - but it hasn't been tested against a real HA
instance yet. If something doesn't work as expected, check both services:

```bash
sudo systemctl status whisper-cpp-server.service wyoming-whisper.service --no-pager
sudo journalctl -u wyoming-whisper.service -n 50
```

Most likely failure mode: whisper.cpp itself isn't running or isn't
reachable at the URL this bridge is configured with - the bridge logs a
clear error for that case rather than crashing, and returns an empty
transcript to the client.

## Binding

The bridge (this service, port 10300) defaults to `0.0.0.0` (reachable by
anyone on your LAN). Pass `--tailscale` (or set
`WYOMING_WHISPER_BIND_TAILSCALE=1`) to restrict it to the Tailscale
interface instead; falls back to `127.0.0.1` if `tailscale0` never comes
up, never silently to LAN-wide. Already installed and just want to flip
that setting without a full reinstall?
`sudo ./install-wyoming-whisper.sh --rebind [--tailscale]`, or
`sudo ./setup.sh --rebindTailscale` / `--rebindLan` to flip every
already-installed bind-aware service at once. whisper.cpp's own REST
server underneath stays `127.0.0.1`-only regardless - nothing outside this
box needs to reach it directly, only this bridge does.

## Reinstalling / uninstalling

If `wyoming-whisper.service` already exists, running the install script
again asks before overwriting it. Under `setup.sh`'s
`--bypassAllChecks`/`--bypassInstallerChecks` it does **not** overwrite
automatically - it skips and reports "already installed" instead, so
re-run it directly (without those flags) to be prompted.

To remove it: `sudo ./uninstall-wyoming-whisper.sh` (or via `uninstall.sh
--uninstallWyomingWhisper`) - stops/disables the service and removes
`/opt/wyoming-whisper`. whisper.cpp itself is untouched.
