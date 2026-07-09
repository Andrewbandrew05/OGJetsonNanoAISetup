# LLama.cpp Setup
Pulls down a precompiled, CUDA-enabled llama.cpp build from
https://github.com/kreier/llama.cpp-jetson.nano, downloads the
`gemma-3-1b-it-GGUF` model on first start, and installs+starts a systemd
service (`llama-cpp-server`) serving the HTTP API/web UI on port **8081**
(deliberately not 8080, since whisper.cpp's server binds that port).

First startup takes a few minutes while the model downloads and converts -
watch progress with `sudo journalctl -u llama-cpp-server.service -f`.

Override the port with `LLAMA_SERVICE_PORT=9000 ./install-llama-cpp-nano-service.sh`,
or via `setup.sh`: `--llamaPort=9000`.

Run this via `sudo`, not as a plain user with internal `sudo` calls as the
script's own header comment suggests - the systemd service is created to
run as whichever user invoked the script (`$SUDO_USER`), so running it
under `sudo` directly still gets it right.

## Connecting to Home Assistant

`llama-server` implements an OpenAI-compatible API at
`http://<nano-ip>:8081/v1/...` - the same request/response shape as
`api.openai.com`, just pointed at this box instead. Two ways to wire that
into HA:

1. **Built-in "OpenAI Conversation" integration** (Settings > Devices &
   Services > Add Integration > OpenAI Conversation) - recent HA versions
   let you set a custom Base URL during setup instead of the real OpenAI
   endpoint. Point it at `http://<nano-ip>:8081/v1`. The API key field
   just needs to be non-empty - `llama-server` doesn't check it.
2. **"Extended OpenAI Conversation"** (HACS custom integration) - built
   specifically for local LLM backends like this one, with more control
   (custom endpoint, function calling for HA voice assistant actions)
   than the stock integration offers.

**Security note:** `llama-server` binds `0.0.0.0` by default - every
network interface, reachable by anyone on your LAN - with no
authentication at all. Pass `--tailscale` (or set
`LLAMA_BIND_TAILSCALE=1`) to restrict it to the Tailscale interface
instead; falls back to `127.0.0.1` if `tailscale0` never comes up, never
silently to LAN-wide. Already installed and just want to flip that setting
without a full reinstall (which redownloads the model)?
`sudo ./install-llama-cpp-nano-service.sh --rebind [--tailscale]`, or
`sudo ./setup.sh --rebindTailscale` / `--rebindLan` to flip every
already-installed bind-aware service (llama.cpp, wyoming-piper, the
Wyoming-whisper bridge, backup API) at once.

## Reinstalling / uninstalling

If `llama-cpp-server.service` already exists, running the install script
again asks before overwriting it (rebuilding means redownloading the CUDA
binaries and re-fetching the model). Under `setup.sh`'s
`--bypassAllChecks`/`--bypassInstallerChecks` it does **not** overwrite
automatically - it skips and reports "already installed" instead, so
re-run it directly (without those flags) to be prompted.

To remove it: `sudo ./uninstall-llama-cpp-nano-service.sh` (or via
`uninstall.sh --uninstallLlama`) - stops/disables the service and removes
the installed binaries/libraries; separately asks about the downloaded
model cache (`~/.cache/llama.cpp`, several GB) since that's a bigger,
more clearly-irreversible deletion.
