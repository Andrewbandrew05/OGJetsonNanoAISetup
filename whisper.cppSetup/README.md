# whisper.cpp with CUDA on the original Jetson Nano

A working, GPU-accelerated build of [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
v1.5.4, running as a systemd service, on the **original** Jetson Nano
(4GB, Maxwell GPU, compute capability 5.3, CUDA 10.2, JetPack 4.6.x).

This hardware/software combination is old enough that the stock build
instructions don't work out of the box. This repo documents the exact
problems encountered and why each fix is needed, so you're not debugging
them blind.

## Hardware / software this was built and tested on

- Jetson Nano (original, **not** Orin Nano — different GPU architecture)
- JetPack 4.6.x, Ubuntu 18.04 (Bionic), aarch64
- CUDA 10.2 (`nvcc` release 10.2, V10.2.300)
- GCC 7.5 default; GCC 9 required for the build (installed alongside, not
  a replacement for the system default)
- whisper.cpp `v1.5.4`

If you're on Orin Nano or Xavier, you have a newer GPU (sm_87 / sm_72) and
likely a newer CUDA/GCC combo where most of this doesn't apply — the stock
whisper.cpp build instructions will probably just work for you.

## Quick start

```bash
git clone <this-repo>
cd <this-repo>
chmod +x install-whisper-cpp.sh
./install-whisper-cpp.sh
```

This builds whisper.cpp into `/opt/whisper.cpp` and installs+starts a
systemd service (`whisper-cpp-server`) serving an HTTP transcription API on
`127.0.0.1:8080` (override with `WHISPER_SERVER_PORT=9000
./install-whisper-cpp.sh`, or via `setup.sh`: `--whisperPort=9000`).

**Model:** defaults to `small.en` - a real, worthwhile accuracy upgrade
over the original `base.en` default (roughly 3x the parameters), noticeably
better at uncommon words/names/proper nouns, confirmed to still run fine
under CUDA on the original Nano. Run the script with no args interactively
and it'll ask which model to use with a tradeoff description for each
(`tiny.en` / `base.en` / `small.en` / `medium.en`) - press Enter for the
`small.en` default, or pick another. Set `WHISPER_MODEL=base.en` (or via
`setup.sh`: `--whisperModel=base.en`) to skip that prompt and pick a
specific model non-interactively; under `setup.sh`'s
`--bypassAllChecks`/`--bypassInstallerChecks` with no `WHISPER_MODEL` set,
it defaults to `small.en` automatically rather than hanging on a prompt.
`medium.en` is available but likely to feel noticeably slower and may not
comfortably fit in memory alongside llama.cpp/wyoming-piper running at the
same time - only reach for it if `small.en`'s accuracy genuinely isn't
enough and you've confirmed the headroom (`free -h` with everything else
already running).

**This is a plain REST endpoint, not the Wyoming protocol.** Home
Assistant's Wyoming integration expects a Wyoming-protocol TCP service, the
same way `wyoming-piperSetup` provides one for TTS - this whisper.cpp
service won't plug into that integration directly. You'd need either a
Wyoming-protocol wrapper in front of this REST API, or a Wyoming-native STT
service instead (e.g. `wyoming-faster-whisper`) to get local STT working in
HA via the Wyoming integration.

## Why the stock build fails on this hardware, in order

### 1. `-arch=all` isn't a valid nvcc flag on CUDA 10.2

whisper.cpp's Makefile tries to auto-detect your GPU architecture using
`nvcc --version` and an `expr` comparison against CUDA 11.6. On CUDA 10.2,
that comparison actually fails silently (`expr: syntax error`, because the
Makefile references a variable, `NVCC_VERSION`, that isn't reliably
populated), which falls through to a default of `-arch=all`. `nvcc` 10.2
doesn't understand `all` as a value for `-arch` (that shorthand requires a
much newer CUDA toolkit) and fails with:

```
nvcc fatal : Value 'all' is not defined for option 'gpu-architecture'
```

**Fix:** force the architecture explicitly on the `make` command line:
`CUDA_ARCH_FLAG=sm_53` (the original Nano's compute capability).

### 2. A GNU Make parsing quirk swallows a later Makefile line as a shell command

whisper.cpp's `ggml-cuda.o:` build rule is defined *inside* an
`ifdef WHISPER_CUBLAS ... endif` conditional block. On GNU Make 4.1 (the
default on Ubuntu 18.04 / Jetson), a rule defined this way can cause Make's
"currently reading a recipe" parser state to leak past the block's `endif`.
The next tab-indented line elsewhere in the file — in this case, the
aarch64 `CFLAGS += -mcpu=native` line — gets misread as another recipe
command for `ggml-cuda.o` rather than a plain variable assignment. Since
`CFLAGS` isn't an executable, you get:

```
make: CFLAGS: Command not found
```

**Fix:** relocate the aarch64 flags block earlier in the Makefile, before
any conditional-embedded rule is defined. (Done automatically by this
script, see Patch A.)

### 3. `nvcc` intercepts `-mcpu=native` as its own `-m<N>` flag

Even after fixing #2, `-mcpu=native` (needed for the plain `gcc`/`g++`
compiles) breaks `nvcc` specifically, because `nvcc` has its own family of
`-m<bitwidth>` flags (like `-m64`) and intercepts anything starting with
`-m` before forwarding unknown flags to the host compiler:

```
nvcc fatal   : 'cpu=native': expected a number
```

**Fix:** strip `-mcpu=native` only from the flags passed to the `ggml-cuda.o`
recipe, via `$(filter-out -mcpu=native,$(CXXFLAGS))`. (Patch B.)

### 4. GCC 7 (and 8) are missing some NEON intrinsics used by `ggml-quants.c`

`ggml-quants.c` uses ARM NEON "multi-vector load" intrinsics:
`vld1q_s16_x2`, `vld1q_u8_x2`, `vld1q_s8_x2` (added in GCC 8's headers) and
`vld1q_s8_x4`, `vld1q_u8_x4` (only added in GCC 9's headers). Ubuntu 18.04's
default compiler is GCC 7.5, which has none of these, and even GCC 8 is
still missing the `_x4` variants. Symptom: `invalid initializer` /
`incompatible types` errors deep in the quantization code.

**Fix:** install `gcc-9`/`g++-9` and build with `CC=gcc-9 CXX=g++-9`.

Note: Bionic's own apt repos only ever went up to gcc-8, and as of this
writing the `ubuntu-toolchain-r/test` PPA is needed to get gcc-9 at all -
this script's own `apt install -y gcc-9 g++-9` line assumes it's already
available and will fail with "Unable to locate package" if the PPA hasn't
been added first. Run `CoreSystemSetup/Gcc9Upgrade/gcc9_upgrade.sh` before
this script (it's wired into `setup.sh`'s core order automatically) rather
than relying on this script to fetch it itself.

### 5. Original Nano GPU is genuinely weak — set expectations accordingly

The original Nano's Maxwell GPU (128 CUDA cores) is a big step down from
Orin-series hardware. With CUDA working correctly, `base.en` transcribes
roughly real-time or a bit better with default (beam search) decoding, and
noticeably faster with greedy decoding (`--best-of 1`, which this script
always uses). `small.en` (this script's default - see above) is
confirmed to also run acceptably under CUDA on this hardware, at a real
but tolerable speed cost over `base.en`. `medium.en` is a much bigger step
up again and is unlikely to feel responsive for interactive use - see the
model-selection notes above before reaching for it.

## Verifying the CUDA build actually works (not silently falling back to CPU)

```bash
sudo systemctl status whisper-cpp-server.service --no-pager
```

Look for these lines in the log:

```
ggml_init_cublas: found 1 CUDA devices:
  Device 0: NVIDIA Tegra X1, compute capability 5.3, VMM: no
whisper_backend_init: using CUDA backend
```

If you don't see these, the binary silently fell back to CPU — check that
`CUDA_ARCH_FLAG=sm_53` was actually passed during the build.

## Manual test

```bash
curl 127.0.0.1:8080/inference \
  -H "Content-Type: multipart/form-data" \
  -F file=@/opt/whisper.cpp/samples/jfk.wav \
  -F response_format=text
```

(If you don't have `samples/jfk.wav`, run `make samples` inside
`/opt/whisper.cpp`, which downloads a few short test clips via `wget`/`ffmpeg`,
or just point `-F file=@` at any wav file of your own.)

## Directory layout

Following the convention that services get their own folder under `/opt`:

```
/opt/whisper.cpp/          # this build: source, binaries, models
```

For bridging this to Home Assistant via the Wyoming protocol, see
`wyoming-whisperSetup/` in this repo - it wraps this exact server (no
second whisper model loaded) rather than being a separate install.

## Reinstalling / uninstalling

If `whisper-cpp-server.service` already exists, running the install
script again asks before overwriting it (rebuilding takes several minutes
on Jetson Nano). Under `setup.sh`'s
`--bypassAllChecks`/`--bypassInstallerChecks` it does **not** overwrite
automatically - it skips and reports "already installed" instead, so
re-run it directly (without those flags) to be prompted.

To remove it: `sudo ./uninstall-whisper-cpp.sh` (or via `uninstall.sh
--uninstallWhisper`) - stops/disables the service and removes
`/opt/whisper.cpp` entirely (source, build, and model together). If the
Wyoming-whisper bridge is also installed, uninstall that too since it'll
have nothing to forward requests to afterward.

## Notes / things that surprised us along the way

- `git checkout v1.5.4` plus `git clean -fdx` gives you a genuinely clean
  tree — if you're debugging a build issue, always reset to this baseline
  before layering on patches, rather than patching an already-patched file.
- Run builds with `-j1` while debugging. Parallel (`-j2`+) output
  interleaves from multiple compiler processes and makes it much harder to
  tell which command actually produced a given error.
- systemd services don't inherit your interactive shell's `PATH`/exports —
  explicitly set `PATH` and `LD_LIBRARY_PATH` in the unit file even if
  `ldconfig -p | grep cudart` shows the library is already registered
  system-wide (it likely is on Jetson, via JetPack's `ld.so.conf.d` entry,
  but the `PATH` for finding `nvcc` at runtime is a separate concern from
  library resolution).
