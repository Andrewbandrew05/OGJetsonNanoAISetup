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
   If your SSH session drops (or you close your laptop and reconnect
   later), the install keeps running inside `tmux` regardless - just SSH
   back in and reattach to see it:
   ```bash
   tmux attach -t setup
   ```
   If you're not sure whether a session is still running, `tmux ls` lists
   all of them by name.
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
+ whisper.cpp + a Wyoming-whisper bridge (for HA - see below) +
wyoming-piper + a system package upgrade + Tailscale, fully unattended.
Each script automatically retries itself once if it hits a transient
failure (a flaky network blip during a download, etc.), so this is safe
to kick off inside `tmux` and walk away from. The one thing that actually
waits for you: Tailscale runs last and ends by blocking on
`tailscale up`'s login URL, so that's what you'll come back to.

### Default ports

| Service | Port | Notes |
|---|---|---|
| llama.cpp | 8081 | `http://<nano-ip>:8081` - OpenAI-compatible API + web UI. LAN-wide by default, no auth - see `llama.cppSetup/README.md`. |
| whisper.cpp | 8080 | `http://127.0.0.1:8080` - plain REST API, always localhost-only, **not** the Wyoming protocol. |
| Wyoming-whisper bridge | 10300 | `tcp://<nano-ip>:10300` - Wyoming protocol wrapper in front of whisper.cpp, for HA's Wyoming integration. LAN-wide by default. See `wyoming-whisperSetup/README.md`. |
| wyoming-piper | 10200 | `tcp://<nano-ip>:10200` - Wyoming protocol, HA-ready directly. LAN-wide by default. |
| Backup + control API | 8843 | `http://<nano-ip>:8843` - LAN-wide by default; can trigger a reboot/backup, see the Binding section below. |

Every port above is overridable - `--llamaPort=`, `--whisperPort=`,
`--wyomingWhisperPort=`, `--piperPort=`, `--backupApiPort=` (each only
applies if that service is actually being installed in the same run). See
`sudo ./setup.sh --help` for the full reference.

### Binding: LAN-wide vs Tailscale-only

llama.cpp, wyoming-piper, the Wyoming-whisper bridge, and the backup +
control API all default to `0.0.0.0` - reachable by anyone on your LAN.
`--tailscaleAll` restricts all 4 to the Tailscale interface only, for that
run's fresh installs (falls back to `127.0.0.1` if `tailscale0` never
comes up, never silently to LAN-wide):

```bash
sudo ./setup.sh --installAll --tailscaleAll --bypassAllChecks
```

Each installer also takes its own `--tailscale` flag if you only want to
restrict one service (e.g. `sudo ./backup_api_install.sh --tailscale`).
**The backup API is worth restricting even if you leave the AI services
LAN-wide** - it can trigger a reboot and a backup run, guarded only by a
bearer token in a plaintext file.

Already installed and just want to flip the setting without a full
reinstall (redownloading models/binaries, a new API token)?

```bash
sudo ./setup.sh --rebindTailscale   # or --rebindLan
```

This flips every already-installed one of the 4 services above in place
(skipping any that aren't installed) - no reinstall, just a config change
and a restart. Per-service equivalent: `sudo ./<script>.sh --rebind
[--tailscale]`.

This intentionally leaves out two things that need information only you
have:
- **GUI package purge** (`--purgeGuiPackages`) - reclaims disk space by
  actually uninstalling the desktop stack instead of just disabling it.
  Slower and more invasive than the default. Tested against a JetPack image
  downloaded 2026-07-07: reliably removes a good chunk of unused desktop
  packages on that image, with no guarantee it catches everything on every
  image variant - but it's guaranteed not to remove anything that would
  stop the board from booting, since it removes packages one at a time via
  `dpkg` rather than letting `apt`'s dependency solver decide what else
  should go. Read `CoreSystemSetup/GuiRemoval/README.md` for the details.
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
`wyoming-whisperSetup/`, and `wyoming-piperSetup/` also works completely
standalone (`sudo ./script.sh`), if you'd rather run things one at a time
instead of through `setup.sh`.

Run `sudo ./setup.sh` with no arguments at all for an interactive
installer: it prints the full flag reference, a numbered menu of every
script grouped by category, and one prompt where you can either type
numbers (e.g. `1 3 4`, or `all`) to run individual scripts, or type a full
flag string (e.g. `--installAll --bypassAllChecks`) to run a preconfigured
package - same effect either way as passing those flags directly on the
command line, just without needing to remember the flag names up front.

`setup.sh` `chmod +x`'s each script it calls right before running it, so if
you're doing one big run through `setup.sh` you only need to
`chmod +x setup.sh` itself - it handles the rest. Running any of the other
scripts standalone, though, needs it done manually first for that specific
script: `chmod +x script.sh` before `sudo ./script.sh`.

`--bypassAllChecks` auto-accepts every remaining confirmation, including
the GUI purge mode's prompt if you use it, plus apt/debconf dialogs.
`--bypassInstallerChecks` only auto-accepts installer-level confirmations,
not OS-level ones. `--forceNewConfigs` changes how the system upgrade step
handles a config file that's been locally modified (e.g. something
JetPack's first-boot setup customized) - default is to keep the current
one, this flag takes the package maintainer's version instead; see
`CoreSystemSetup/SystemUpgrade/README.md` for the reasoning either way.
`sudo ./setup.sh --help` lists everything, including the env vars the
backup API installer needs for a non-interactive run.

## Reinstalling something already installed

The 5 externally-facing service installers (llama.cpp, whisper.cpp, the
Wyoming-whisper bridge, wyoming-piper, and the Backup + control API) detect
an existing install and ask before overwriting it. Under
`--bypassAllChecks`/`--bypassInstallerChecks` they deliberately **don't**
overwrite automatically - re-downloading binaries or a model, or
regenerating an API token, is too big a decision for a bypass flag to make
silently. Instead they skip and report "already installed" in the final
summary; re-run that specific script directly (without those flags) to be
prompted. The core/system scripts (Python 3.9, gcc-9, swap, jtop, SSH
hardening, GUI removal) are idempotent instead - safe to overwrite/re-run
without asking, since there's nothing user-specific to lose.

## Uninstalling

```bash
sudo ./uninstall.sh --uninstallAll
```

Undoes everything `setup.sh` can do, script by script - each
`uninstall-*.sh` stops/disables its systemd service(s) and removes what it
installed. A few are worth knowing about specifically:

- **GUI removal** is reversed properly, not just "turned back on": it
  restores the boot target and display manager, and if you used
  `--purgeGuiPackages`, it diffs the oldest pre-removal package snapshot
  against what's currently installed and offers to reinstall exactly what's
  missing - not a guessed list, the actual packages that specific run
  removed. See `CoreSystemSetup/GuiRemoval/README.md`.
- **SSH hardening** restores the oldest backed-up `sshd_config` (the true
  pre-hardening baseline), validating it with `sshd -t` before restarting
  `ssh` so a bad restore can't lock you out.
- **The Backup API** uninstaller does **not** touch your remote backups -
  only the local API/service/config on the Nano. It warns before letting
  you delete the restic password and asks separately about the dedicated
  SSH key, since removing it locally doesn't revoke it remotely.

Like `setup.sh`, running `sudo ./uninstall.sh` with no arguments gives you
an interactive menu (numbers or a flag string), and every `uninstall-*.sh`
also works standalone. Individual flags: `--uninstallLlama`,
`--uninstallWhisper`, `--uninstallWyomingWhisper`, `--uninstallPiper`,
`--uninstallBackupAPI`, `--uninstallTailscale`, `--uninstallSshHarden`,
`--uninstallJtop`, `--uninstallSwap`, `--uninstallGcc9`,
`--uninstallPython39`, `--uninstallGui`. `--bypassAllChecks` skips the
"are you sure?" confirmations. `sudo ./uninstall.sh --help` lists
everything.
