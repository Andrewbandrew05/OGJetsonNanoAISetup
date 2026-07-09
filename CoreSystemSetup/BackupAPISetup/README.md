# Backup + Control API Setup

Installs:

1. **restic** - encrypted, deduplicated, incremental backups of `/etc`, `/home`,
   `/root`, and the API's own state, sent to a remote target you choose during
   install (a machine reachable over Tailscale via SFTP, or S3-compatible
   storage like Backblaze B2/AWS S3/MinIO).
2. A small local **FastAPI control service** exposing three endpoints, so
   Home Assistant can trigger things without a custom HA integration -
   just its built-in `rest_command` / `rest` sensor platforms:
   - `GET /status` - uptime, disk usage, last backup time
   - `POST /backup` - kicks off a backup immediately
   - `POST /reboot` - reboots the Nano
3. Optionally, a **nightly systemd timer** (3am) that runs the same backup
   automatically, independent of the API - you're asked during install
   whether you want this or prefer API-triggered backups only.

All endpoints require a bearer token (generated at install time, printed at
the end, and saved to `/etc/nano-ai-backup/api_token`).

Listens on port 8843 by default - override with
`NANO_BACKUP_API_PORT=9000 ./backup_api_install.sh`, or via `setup.sh`:
`--backupApiPort=9000`.

## Non-interactive install

By default this script prompts for where to store backups (remote
SSH/Tailscale host, or S3-compatible storage) since there's no sane
default for someone else's storage - that can't be skipped with a bypass
flag, but it can be supplied up front via env vars:

```bash
# SSH/Tailscale target:
NANO_BACKUP_TARGET=ssh
NANO_BACKUP_SSH_HOST=<ip-or-tailscale-hostname>
NANO_BACKUP_SSH_USER=<remote-ssh-user>
NANO_BACKUP_SSH_PATH=<remote-path, e.g. /mnt/backups/jetson-nano>

# or S3-compatible target:
NANO_BACKUP_TARGET=s3
NANO_BACKUP_S3_BUCKET=<bucket>
NANO_BACKUP_S3_ENDPOINT=<endpoint, blank for AWS S3>
NANO_BACKUP_S3_ACCESS_KEY=<access key id>
NANO_BACKUP_S3_SECRET_KEY=<secret access key>

# whether to also schedule automatic nightly backups (systemd timer, 3am),
# in addition to the API's /backup endpoint - defaults to yes if unset and
# running non-interactively:
NANO_BACKUP_AUTO=yes|no
```

If `setup.sh`'s `--bypassAllChecks`/`--bypassInstallerChecks` is active and
`NANO_BACKUP_TARGET` isn't set, the script fails fast with an error instead
of hanging on a prompt - set the vars above, or just run this script by
itself interactively instead.

## Important: this is not full bare-metal imaging

This backs up your **configuration and data**, not a raw disk image. Cloning
a running root partition block-for-block isn't safe on the Nano's stock
ext4 layout (no LVM/snapshot support), so a true "reflash from scratch"
disaster-recovery baseline should be created **once, offline**, right after
you've got a Nano fully set up: pull the SD card and image it with `dd` from
a host PC, or use NVIDIA SDK Manager. Store that image somewhere safe. This
restic setup then handles everything that changes day-to-day on top of that
baseline.

## Security notes

- The API only binds to the Tailscale interface (`tailscale0`). Until
  Tailscale is up, it falls back to `127.0.0.1` only - it will never be
  exposed on your LAN or the internet by default.
- The restic encryption password is generated for you and stored in
  `/etc/nano-ai-backup/restic.env` (mode 600). **Copy it somewhere else too**
  - if that file is lost alongside the Nano, your backups can't be decrypted.
- If you chose the SFTP/Tailscale option, a dedicated SSH keypair is
  generated for backups only (`/root/.ssh/id_ed25519_backup`) - it's not
  your personal login key.

## Restore

Use `restore_backup.sh` rather than restoring by hand - it lists the
available snapshots, lets you pick one (or just take the latest), and
handles both scenarios:

```bash
sudo ./restore_backup.sh
```

- **Rolling back the same machine**: `/etc/nano-ai-backup/restic.env`
  already exists, so it's used automatically - nothing to re-enter.
- **Disaster recovery on a fresh/replacement Nano** (reflashed, or a whole
  new board): no local config exists yet, so it asks for the same
  repository details (SSH/Tailscale host or S3 bucket) `backup_api_install.sh`
  originally asked for, plus the encryption password you saved somewhere
  safe, before it can see any snapshots at all.

The final "actually overwrite files on this machine" confirmation is a
separate, explicit `--yes` flag on this script (`sudo ./restore_backup.sh --yes`)
rather than something `setup.sh`'s bypass flags can trigger - restoring
overwrites live files, and that shouldn't ever happen as a side effect of
an unrelated unattended run.

Env vars for scripting scenario 2 (same names as the install script, plus
one new one):

```bash
NANO_BACKUP_TARGET=ssh|s3
# ... same NANO_BACKUP_SSH_*/NANO_BACKUP_S3_* vars as above ...
RESTIC_PASSWORD=<password>          # skips the password prompt if pre-exported
NANO_RESTORE_SNAPSHOT=<id>|latest    # skips the "pick a snapshot" prompt
```

If you'd rather do it fully by hand:

```bash
source /etc/nano-ai-backup/restic.env
restic snapshots                  # see what's available
restic restore latest --target /  # restore the most recent snapshot
```

## Reinstalling / uninstalling

If `nano-ai-api.service` already exists, running the install script again
asks before overwriting it (this would regenerate the API token and redo
the backup target setup). Under `setup.sh`'s
`--bypassAllChecks`/`--bypassInstallerChecks` it does **not** overwrite
automatically - it skips and reports "already installed" instead, so
re-run it directly (without those flags) to be prompted.

To remove it: `sudo ./uninstall-backup-api.sh` (or via `uninstall.sh
--uninstallBackupAPI`) - stops/disables all three systemd units and
removes `/opt/nano-ai-backup`/`/etc/nano-ai-backup`. **Does not touch your
remote backup target** - your actual backups stay exactly where they are;
this only removes the local API/service/config on this Nano. Warns before
deleting the restic password (needed to ever decrypt those remote
backups) and separately asks about the dedicated SSH key, since removing
it locally doesn't revoke it on the remote side.

## Home Assistant example (`configuration.yaml`)

```yaml
rest_command:
  nano_backup:
    url: "http://<tailscale-ip>:8843/backup"
    method: POST
    headers:
      Authorization: "Bearer <token>"
  nano_reboot:
    url: "http://<tailscale-ip>:8843/reboot"
    method: POST
    headers:
      Authorization: "Bearer <token>"

rest:
  - resource: "http://<tailscale-ip>:8843/status"
    method: GET
    headers:
      Authorization: "Bearer <token>"
    sensor:
      - name: "Jetson Nano Last Backup"
        value_template: "{{ value_json.last_backup }}"
```
