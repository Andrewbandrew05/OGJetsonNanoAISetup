# OGJetsonNanoAISetup
Guide to setting up an original Jetson Nano to run llama.cpp, piper, and whisper.cpp to act as an ai coprocessor. Not sure how many people will find this useful but I know I would've liked to have found this when I was trying to set it up.

NOTE THIS IS STILL IN DEVELOPMENT I AM NOT AT FAULT IF IT BRICKS YOUR OS

This guide is built out as a series of steps augmented by automated installation scripts you can run if you so wish. It worked for me on a INSERT NAME OF EXACT NANO DEVICE HERE but I can't guarantee it'll work on yours. 

Credit Claude for majority of install scripts and documentation (I've verified this works by following this guide on a clean install of my own machine).

## Quick start

Every script under `CoreSystemSetup/`, `llama.cppSetup/`, `whisper.cppSetup/`, and
`wyoming-piperSetup/` works standalone (`sudo ./script.sh`) if you'd rather pick
and choose. Or run everything through `setup.sh`, either interactively:

```bash
sudo ./setup.sh
```

or non-interactively with one of the preconfigured packages, which are
combinable (running the same script via more than one flag only runs it once):

```bash
sudo ./setup.sh --installAll                          # core system + llama.cpp/whisper.cpp/piper + Tailscale
sudo ./setup.sh --installModels                       # just llama.cpp + whisper.cpp + piper
sudo ./setup.sh --installBackupAPI                     # just the restic backup + control API
sudo ./setup.sh --installAll --installBackupAPI --bypassAllChecks   # everything, no prompts
```

GUI removal defaults to a fast, non-destructive mode (just disables the
display manager - nothing gets uninstalled); its more invasive
`--purge-packages` mode isn't part of `--installAll` and has to be run
standalone if you want it. `--bypassAllChecks` auto-accepts every remaining
confirmation, including that purge mode's prompt if you do run it, plus
apt/debconf dialogs. `--bypassInstallerChecks` only auto-accepts
installer-level confirmations, not OS-level ones. A system package
update/upgrade and Tailscale always run last, in that order, if selected -
Tailscale ends by waiting on `tailscale up`'s login link, so with everything
else on autopilot that's the one thing left on screen when you come back.
`sudo ./setup.sh --help` lists everything, including the env vars the
backup API installer needs for a non-interactive run.

STEP 1: Install OS
Go to this link (https://developer.nvidia.com/embedded/learn/get-started-jetson-nano-devkit#write) and follow Nvidia's instructions on how to install the OS.
