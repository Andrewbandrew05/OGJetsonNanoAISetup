# LLama.cpp Setup
Pulls down a precompiled, CUDA-enabled llama.cpp build from
https://github.com/kreier/llama.cpp-jetson.nano, downloads the
`Qwen2.5-1.5B-Instruct-GGUF` model on first start, and installs+starts a
systemd service (`llama-cpp-server`) serving the HTTP API/web UI on port
**8081** (deliberately not 8080, since whisper.cpp's server binds that
port).

Qwen2.5-1.5B was chosen over a smaller ~1B model specifically for
meaningfully better instruction-following and tool-calling reliability
(e.g. correctly deciding whether/how to call a Home Assistant function),
while still comfortably fitting this hardware's memory budget (~1GB) and
running at a similar speed. Override with
`LLAMA_MODEL_HF=some-org/some-model-GGUF ./install-llama-cpp-nano-service.sh`
if you want to try a different model - bigger models are meaningfully
slower on this hardware (memory bandwidth, not just compute, is the real
bottleneck), so test any swap directly against `llama-cpp-server`'s own
`/v1/chat/completions` endpoint before assuming it's an improvement.

**Reports a clean model name, not the full cache path.** By default
`llama-server`'s `/v1/models` endpoint and completion responses report
whatever's in `-hf` verbatim - an ugly full local file path once it's
downloaded (e.g. `/home/you/.cache/llama.cpp/Qwen_Qwen2.5-1.5B-Instruct-GGUF_...gguf`).
The installer passes `--alias` with a clean name derived automatically
from `MODEL_HF` (e.g. `Qwen2.5-1.5B-Instruct`), so anything you connect to
this server sees a readable name instead - and it always matches whatever
model is actually configured, since it's computed from `MODEL_HF` at
install time rather than hardcoded, so it stays correct if you switch
models later.

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

**If you enable function calling / "Control Home Assistant"** (letting
the model actually control devices, not just chat), the client sends a
`tools` parameter with every request. The systemd unit passes `--jinja` to
`llama-server` specifically so it can handle that - without it,
`llama-server` rejects any request containing `tools` outright with a 500
error (`tools param requires --jinja flag`) before generating anything at
all. If you ever see that specific error, or requests that seem to vanish
without the GPU ever spiking, this flag is almost certainly why.

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
binaries and re-fetching the model). Confirming stops the running service
first - its `llama-server` binary can't be overwritten while that process
still has it open (fails with "Text file busy" otherwise). Under `setup.sh`'s
`--bypassAllChecks`/`--bypassInstallerChecks` it does **not** overwrite
automatically - it skips and reports "already installed" instead, so
re-run it directly (without those flags) to be prompted.

To remove it: `sudo ./uninstall-llama-cpp-nano-service.sh` (or via
`uninstall.sh --uninstallLlama`) - stops/disables the service and removes
the installed binaries/libraries; separately asks about the downloaded
model cache (`~/.cache/llama.cpp`, several GB) since that's a bigger,
more clearly-irreversible deletion.
