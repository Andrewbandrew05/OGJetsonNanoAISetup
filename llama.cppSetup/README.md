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

**Security note:** unlike whisper.cpp (binds `127.0.0.1` only) and the
backup API (binds the Tailscale interface only), `llama-server` binds
`0.0.0.0` - every network interface - with no authentication at all. It's
reachable from anywhere on your LAN by default, not just over Tailscale.
That may be intentional for easy direct access, but it's worth being
aware of before exposing this to a network you don't fully trust.
