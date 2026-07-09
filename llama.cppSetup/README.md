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
