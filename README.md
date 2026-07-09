# OGJetsonNanoAISetup
Guide to setting up an original Jetson Nano to run llama.cpp, piper, and whisper.cpp to act as an ai coprocessor. Not sure how many people will find this useful but I know I would've liked to have found this when I was trying to set it up.

NOTE THIS IS STILL IN DEVELOPMENT I AM NOT AT FAULT IF IT BRICKS YOUR OS

This guide is built out as a series of steps augmented by automated installation scripts you can run if you so wish. It worked for me on a INSERT NAME OF EXACT NANO DEVICE HERE but I can't guarantee it'll work on yours. 

Credit Claude for majority of install scripts and documentation (I've verified this works by following this guide on a clean install of my own machine).

## Install

1. Flash the OS: follow Nvidia's instructions at
   https://developer.nvidia.com/embedded/learn/get-started-jetson-nano-devkit#write
2. Boot it and complete the first-boot setup wizard (needs a monitor +
   keyboard plugged in for this one step), then copy your SSH key over so
   you can do everything else headless:
   ```bash
   ssh-copy-id you@<nano-ip>
   ```
3. SSH in. Several of the steps below run unattended for a while, so
   install `tmux` first so a dropped SSH session doesn't kill an install
   partway through:
   ```bash
   sudo apt-get update
   sudo apt-get install -y tmux
   tmux new -s setup
   ```
4. Clone this repo:
   ```bash
   git clone https://github.com/Andrewbandrew05/OGJetsonNanoAISetup.git
   cd OGJetsonNanoAISetup
   ```

### Recommended default run

```bash
sudo ./setup.sh --installAll --bypassAllChecks
```

This runs core system setup (Python 3.9 + gcc-9 build-toolchain fixes,
swap, jtop, SSH hardening, GUI disabled but **not** uninstalled) + llama.cpp
+ whisper.cpp + wyoming-piper + a system package upgrade + Tailscale, fully
unattended. Each script automatically retries itself once if it hits a
transient failure (a flaky network blip during a download, etc.), so this
is safe to kick off inside `tmux` and walk away from. The one thing that
actually waits for you: Tailscale runs last and ends by blocking on
`tailscale up`'s login URL, so that's what you'll come back to.

This intentionally leaves out two things that need information only you
have:
- **GUI package purge** (`--purgeGuiPackages`) - reclaims disk space by
  actually uninstalling the desktop stack instead of just disabling it.
  Slower, more invasive, and still being hardened - read
  `CoreSystemSetup/GuiRemoval/README.md` before using it.
- **Backup + control API** (`--installBackupAPI`) - needs a remote backup
  target (NAS over Tailscale/SSH, or S3-compatible storage) that has to
  already exist and be reachable. See
  `CoreSystemSetup/BackupAPISetup/README.md`.

### The "everything" run (moonshot)

Once you've got a backup target ready and are comfortable with the more
invasive GUI purge mode:

```bash
export NANO_BACKUP_TARGET=ssh   # or s3 - see CoreSystemSetup/BackupAPISetup/README.md
export NANO_BACKUP_SSH_HOST=<nas-ip-or-tailscale-hostname>
export NANO_BACKUP_SSH_USER=<remote-user>
export NANO_BACKUP_SSH_PATH=/mnt/backups/jetson-nano
export NANO_BACKUP_AUTO=yes

sudo ./setup.sh --installAll --installBackupAPI --purgeGuiPackages --bypassAllChecks
```

### Picking and choosing

Every script under `CoreSystemSetup/`, `llama.cppSetup/`, `whisper.cppSetup/`,
and `wyoming-piperSetup/` also works completely standalone
(`sudo ./script.sh`), if you'd rather run things one at a time instead of
through `setup.sh`. Or run `sudo ./setup.sh` with no flags at all for an
interactive menu.

`--bypassAllChecks` auto-accepts every remaining confirmation, including
the GUI purge mode's prompt if you use it, plus apt/debconf dialogs.
`--bypassInstallerChecks` only auto-accepts installer-level confirmations,
not OS-level ones. `sudo ./setup.sh --help` lists everything, including the
env vars the backup API installer needs for a non-interactive run.
