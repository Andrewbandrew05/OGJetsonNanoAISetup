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
3. A **nightly systemd timer** (3am) that runs the same backup automatically,
   independent of the API.

All endpoints require a bearer token (generated at install time, printed at
the end, and saved to `/etc/nano-ai-backup/api_token`).

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

```bash
source /etc/nano-ai-backup/restic.env
restic snapshots                 # see what's available
restic restore latest --target /  # restore the most recent snapshot
```

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
