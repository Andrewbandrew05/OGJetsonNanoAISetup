#!/bin/bash
#
# BackupSetup/backup_api_install.sh
#
# Installs restic (incremental, encrypted, deduplicated backups) and a
# small local FastAPI service exposing /status, /backup, and /reboot so
# Home Assistant (or anything else) can trigger backups/restarts without a
# custom HA integration - just HA's built-in rest_command / rest sensor.
#
# The API only binds to the Tailscale interface once it exists; until then
# it falls back to 127.0.0.1 so it's never accidentally exposed on the LAN.
#
# NOTE ON SCOPE: this backs up configs/homes/service state via restic to a
# remote target (NAS over Tailscale, or S3-compatible storage), NOT a full
# bare-metal disk image. True bare-metal imaging of a running root
# partition isn't safe on the Nano's stock ext4 layout (no LVM snapshot
# support), so that step should be done once, offline, via a host PC
# (SD card reader + dd, or NVIDIA SDK Manager) right after initial setup,
# and stored somewhere safe as your "reflash from scratch" baseline.
#
# Usage:
#   chmod +x backup_api_install.sh
#   sudo ./backup_api_install.sh
#
# Non-interactive usage: this script asks for a remote backup target, since
# there's no sane default for someone else's storage. Set these env vars to
# skip the prompts:
#   NANO_BACKUP_TARGET=ssh|s3
#   # ssh target:
#   NANO_BACKUP_SSH_HOST=<ip-or-tailscale-hostname>
#   NANO_BACKUP_SSH_USER=<remote-ssh-user>
#   NANO_BACKUP_SSH_PATH=<remote-path e.g. /mnt/backups/jetson-nano>
#   # s3 target:
#   NANO_BACKUP_S3_BUCKET=<bucket>
#   NANO_BACKUP_S3_ENDPOINT=<endpoint, blank for AWS S3>
#   NANO_BACKUP_S3_ACCESS_KEY=<access key id>
#   NANO_BACKUP_S3_SECRET_KEY=<secret access key>
#   # whether to also run backups automatically on a nightly timer, in
#   # addition to the API's /backup endpoint (defaults to yes if unset and
#   # running non-interactively):
#   NANO_BACKUP_AUTO=yes|no
#
# If NANO_SETUP_AUTO_YES/NANO_SETUP_AUTO_YES_OS is set (setup.sh's
# --bypassAllChecks/--bypassInstallerChecks) and NANO_BACKUP_TARGET is not
# set, this script fails fast with an error instead of hanging on a prompt.
#
set -euo pipefail

AUTO_YES=0
if [[ "${NANO_SETUP_AUTO_YES:-0}" == "1" || "${NANO_SETUP_AUTO_YES_OS:-0}" == "1" ]]; then
  AUTO_YES=1
fi

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

INSTALL_DIR="/opt/nano-ai-backup"
CONF_DIR="/etc/nano-ai-backup"
RESTIC_ENV="${CONF_DIR}/restic.env"
API_TOKEN_FILE="${CONF_DIR}/api_token"

mkdir -p "$INSTALL_DIR" "$CONF_DIR"
chmod 700 "$CONF_DIR"

echo "=== Backup + Control API Setup ==="

echo "[*] Installing prerequisites..."
apt-get update -y
apt-get install -y curl bzip2 openssl python3-venv python3-pip

# --- restic ---
echo "[*] Installing restic..."
if ! apt-get install -y restic; then
  echo "[!] apt restic unavailable/too old, fetching static binary instead..."
  RESTIC_VER="0.16.4"
  TMP_BZ2=$(mktemp)
  curl -fsSL -o "$TMP_BZ2" \
    "https://github.com/restic/restic/releases/download/v${RESTIC_VER}/restic_${RESTIC_VER}_linux_arm64.bz2"
  bunzip2 -f "$TMP_BZ2"
  install -m 755 "${TMP_BZ2%.bz2}" /usr/local/bin/restic
fi
restic version

# --- Repository configuration ---
echo
if [[ -n "${NANO_BACKUP_TARGET:-}" ]]; then
  case "${NANO_BACKUP_TARGET}" in
    ssh) REPO_CHOICE="1" ;;
    s3) REPO_CHOICE="2" ;;
    *)
      echo "[!] NANO_BACKUP_TARGET must be 'ssh' or 's3', got: ${NANO_BACKUP_TARGET}" >&2
      exit 1
      ;;
  esac
  echo "[*] NANO_BACKUP_TARGET=${NANO_BACKUP_TARGET} - skipping storage prompt."
elif [[ $AUTO_YES -eq 1 ]]; then
  echo "[!] Non-interactive run but no NANO_BACKUP_TARGET env var set." >&2
  echo "    Set NANO_BACKUP_TARGET=ssh|s3 plus the matching NANO_BACKUP_* vars" >&2
  echo "    (see the usage comment at the top of this script), or run it by" >&2
  echo "    itself interactively instead." >&2
  exit 1
else
  echo "Where should backups be stored?"
  echo "  1) Remote machine over Tailscale/SSH (SFTP)"
  echo "  2) S3-compatible storage (e.g. Backblaze B2, AWS S3, MinIO)"
  read -rp "Choose [1/2]: " REPO_CHOICE
fi

RESTIC_PASSWORD=$(openssl rand -base64 32)

if [[ "$REPO_CHOICE" == "1" ]]; then
  if [[ -n "${NANO_BACKUP_TARGET:-}" ]]; then
    REMOTE_HOST="${NANO_BACKUP_SSH_HOST:?NANO_BACKUP_SSH_HOST is required when NANO_BACKUP_TARGET=ssh}"
    REMOTE_USER="${NANO_BACKUP_SSH_USER:?NANO_BACKUP_SSH_USER is required when NANO_BACKUP_TARGET=ssh}"
    REMOTE_PATH="${NANO_BACKUP_SSH_PATH:?NANO_BACKUP_SSH_PATH is required when NANO_BACKUP_TARGET=ssh}"
  else
    read -rp "Remote host (IP or Tailscale hostname): " REMOTE_HOST
    read -rp "Remote SSH user: " REMOTE_USER
    read -rp "Remote path for backups (e.g. /mnt/backups/jetson-nano): " REMOTE_PATH
  fi

  KEYFILE="/root/.ssh/id_ed25519_backup"
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  if [[ ! -f "$KEYFILE" ]]; then
    echo "[*] Generating a dedicated SSH key for backups..."
    ssh-keygen -t ed25519 -f "$KEYFILE" -N "" -C "nano-ai-backup"
  fi

  # Dedicated Host alias so restic (and the systemd-run backup script) just
  # work without any extra flags on every invocation.
  SSH_CONFIG="/root/.ssh/config"
  touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
  if ! grep -q "^Host nano-backup-target$" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF

Host nano-backup-target
    HostName ${REMOTE_HOST}
    User ${REMOTE_USER}
    IdentityFile ${KEYFILE}
    StrictHostKeyChecking accept-new
EOF
  fi

  RESTIC_REPOSITORY="sftp:nano-backup-target:${REMOTE_PATH}"

  echo
  echo ">>> Add this public key to ${REMOTE_USER}@${REMOTE_HOST}'s ~/.ssh/authorized_keys"
  echo "    (on the remote machine) before continuing:"
  echo
  cat "${KEYFILE}.pub"
  echo
  if [[ -n "${NANO_BACKUP_TARGET:-}" ]]; then
    echo "[*] Non-interactive run: assuming the key above is already authorized"
    echo "    on the remote host, and continuing without pausing."
  else
    read -rp "Press Enter once that's done to continue..." _
  fi

elif [[ "$REPO_CHOICE" == "2" ]]; then
  if [[ -n "${NANO_BACKUP_TARGET:-}" ]]; then
    S3_BUCKET="${NANO_BACKUP_S3_BUCKET:?NANO_BACKUP_S3_BUCKET is required when NANO_BACKUP_TARGET=s3}"
    S3_ENDPOINT="${NANO_BACKUP_S3_ENDPOINT:-}"
    AWS_ACCESS_KEY_ID="${NANO_BACKUP_S3_ACCESS_KEY:?NANO_BACKUP_S3_ACCESS_KEY is required when NANO_BACKUP_TARGET=s3}"
    AWS_SECRET_ACCESS_KEY="${NANO_BACKUP_S3_SECRET_KEY:?NANO_BACKUP_S3_SECRET_KEY is required when NANO_BACKUP_TARGET=s3}"
  else
    read -rp "Bucket name: " S3_BUCKET
    read -rp "Endpoint (blank for AWS S3, or e.g. s3.us-west-000.backblazeb2.com): " S3_ENDPOINT
    read -rp "Access Key ID: " AWS_ACCESS_KEY_ID
    read -rsp "Secret Access Key: " AWS_SECRET_ACCESS_KEY
    echo
  fi
  if [[ -n "$S3_ENDPOINT" ]]; then
    RESTIC_REPOSITORY="s3:https://${S3_ENDPOINT}/${S3_BUCKET}"
  else
    RESTIC_REPOSITORY="s3:s3.amazonaws.com/${S3_BUCKET}"
  fi
else
  echo "Invalid choice." >&2
  exit 1
fi

# --- Write env file (root-only readable) ---
{
  echo "RESTIC_REPOSITORY=${RESTIC_REPOSITORY}"
  echo "RESTIC_PASSWORD=${RESTIC_PASSWORD}"
  if [[ "$REPO_CHOICE" == "2" ]]; then
    echo "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}"
    echo "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}"
  fi
} > "$RESTIC_ENV"
chmod 600 "$RESTIC_ENV"

echo "[*] Saved restic config to $RESTIC_ENV (mode 600)."
echo "[!] IMPORTANT: copy the encryption password below somewhere safe -"
echo "    without it your backups CANNOT be decrypted, even by you:"
echo "    ${RESTIC_PASSWORD}"

# --- Initialize repo (idempotent - ignores 'already initialized') ---
echo "[*] Initializing restic repository..."
set -a; source "$RESTIC_ENV"; set +a
restic init || echo "    (repository already initialized, continuing)"

# --- Backup script ---
cat > "${INSTALL_DIR}/run-backup.sh" <<EOF
#!/bin/bash
set -euo pipefail
set -a; source "${RESTIC_ENV}"; set +a
BACKUP_PATHS="/etc /home /opt/nano-ai-backup /root"
echo "[\$(date)] Starting backup..."
restic backup \$BACKUP_PATHS --exclude-caches
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
echo "[\$(date)] Backup complete." | tee "${INSTALL_DIR}/last-backup.log"
EOF
chmod 700 "${INSTALL_DIR}/run-backup.sh"

# --- Automatic nightly backups, or API-triggered only? ---
if [[ -n "${NANO_BACKUP_AUTO:-}" ]]; then
  case "${NANO_BACKUP_AUTO,,}" in
    yes|y|1|true) ENABLE_AUTO_BACKUP=1 ;;
    no|n|0|false) ENABLE_AUTO_BACKUP=0 ;;
    *)
      echo "[!] NANO_BACKUP_AUTO must be yes/no, got: ${NANO_BACKUP_AUTO}" >&2
      exit 1
      ;;
  esac
  echo "[*] NANO_BACKUP_AUTO=${NANO_BACKUP_AUTO} - skipping schedule prompt."
elif [[ $AUTO_YES -eq 1 ]]; then
  echo "[*] Non-interactive run, no NANO_BACKUP_AUTO set - defaulting to automatic nightly backups enabled."
  ENABLE_AUTO_BACKUP=1
else
  echo
  read -rp "Enable automatic nightly backups (systemd timer, 3am), in addition to the API? [Y/n]: " AUTO_CHOICE
  case "${AUTO_CHOICE,,}" in
    n|no) ENABLE_AUTO_BACKUP=0 ;;
    *) ENABLE_AUTO_BACKUP=1 ;;
  esac
fi

if [[ $ENABLE_AUTO_BACKUP -eq 1 ]]; then
  echo "[*] Scheduling automatic nightly backups (systemd timer, 3am)..."
  cat > /etc/systemd/system/nano-ai-backup.service <<EOF
[Unit]
Description=Nano AI restic backup (scheduled)

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/run-backup.sh
EOF

  cat > /etc/systemd/system/nano-ai-backup.timer <<EOF
[Unit]
Description=Nightly Nano AI backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now nano-ai-backup.timer
else
  echo "[*] Skipping the automatic nightly timer - backups only run when the"
  echo "    API's /backup endpoint is called."
fi

# --- Python API service ---
echo "[*] Setting up Python control API..."
python3 -m venv "${INSTALL_DIR}/venv"
# Pinned to pydantic v1 / older fastapi so pip doesn't need a Rust
# toolchain to build wheels on older Python/aarch64 combos.
"${INSTALL_DIR}/venv/bin/pip" install --upgrade pip
"${INSTALL_DIR}/venv/bin/pip" install "fastapi<0.100" "pydantic<2" "uvicorn[standard]<0.23"

API_TOKEN=$(openssl rand -hex 24)
echo "$API_TOKEN" > "$API_TOKEN_FILE"
chmod 600 "$API_TOKEN_FILE"

cat > "${INSTALL_DIR}/app.py" <<'PYEOF'
import os
import subprocess
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException

TOKEN_FILE = Path("/etc/nano-ai-backup/api_token")
BACKUP_SCRIPT = "/opt/nano-ai-backup/run-backup.sh"
LAST_BACKUP_LOG = "/opt/nano-ai-backup/last-backup.log"

app = FastAPI(title="Nano AI Control API")


def _check_auth(authorization: Optional[str]):
    expected = TOKEN_FILE.read_text().strip()
    if not authorization or authorization != f"Bearer {expected}":
        raise HTTPException(status_code=401, detail="Unauthorized")


@app.get("/status")
def status(authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    uptime = subprocess.run(["uptime", "-p"], capture_output=True, text=True).stdout.strip()
    disk = subprocess.run(["df", "-h", "/"], capture_output=True, text=True).stdout
    last_backup = None
    if os.path.exists(LAST_BACKUP_LOG):
        last_backup = open(LAST_BACKUP_LOG).read().strip()
    return {"uptime": uptime, "disk": disk, "last_backup": last_backup}


@app.post("/backup")
def trigger_backup(authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    subprocess.Popen(["/bin/bash", BACKUP_SCRIPT])
    return {"status": "backup started"}


@app.post("/reboot")
def trigger_reboot(authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    subprocess.Popen(["/bin/bash", "-c", "sleep 3 && systemctl reboot"])
    return {"status": "rebooting in 3 seconds"}
PYEOF

# --- Startup wrapper: bind to Tailscale IP once available, else localhost ---
cat > "${INSTALL_DIR}/start-api.sh" <<'EOF'
#!/bin/bash
set -e
BIND_HOST="127.0.0.1"
for i in $(seq 1 30); do
  TS_IP=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  if [[ -n "$TS_IP" ]]; then
    BIND_HOST="$TS_IP"
    break
  fi
  sleep 2
done
echo "[start-api] Binding to ${BIND_HOST}:8843"
exec /opt/nano-ai-backup/venv/bin/uvicorn app:app --app-dir /opt/nano-ai-backup --host "$BIND_HOST" --port 8843
EOF
chmod +x "${INSTALL_DIR}/start-api.sh"

# --- systemd service for the API ---
cat > /etc/systemd/system/nano-ai-api.service <<EOF
[Unit]
Description=Nano AI Control API (backup/reboot/status)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
ExecStart=${INSTALL_DIR}/start-api.sh
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nano-ai-api.service

echo
echo "=== Done ==="
echo "API token (give this to Home Assistant as a Bearer token):"
echo "    ${API_TOKEN}"
echo "Also stored at: $API_TOKEN_FILE"
echo
echo "IMPORTANT: the API only binds once the tailscale0 interface exists"
echo "(falls back to 127.0.0.1 until then). If Tailscale isn't set up yet,"
echo "run its installer, then: sudo systemctl restart nano-ai-api"
echo
echo "Example calls (replace <tailscale-ip> and <token>):"
echo '  curl -H "Authorization: Bearer <token>" http://<tailscale-ip>:8843/status'
echo '  curl -X POST -H "Authorization: Bearer <token>" http://<tailscale-ip>:8843/backup'
echo '  curl -X POST -H "Authorization: Bearer <token>" http://<tailscale-ip>:8843/reboot'
echo
if [[ $ENABLE_AUTO_BACKUP -eq 1 ]]; then
  echo "A nightly backup is also scheduled automatically (systemd timer, 3am)."
else
  echo "Automatic nightly backups are OFF - only the API's /backup endpoint"
  echo "(or the systemd timer, if you enable it later) triggers a backup."
fi
echo
echo "To restore (same machine or a fresh replacement after reflashing),"
echo "run the interactive restore script instead of restoring by hand:"
echo "    sudo ./restore_backup.sh"
echo "It lists available snapshots, lets you pick one (or 'latest'), asks"
echo "for the encryption password if this is a fresh machine, and restores."
