#!/bin/bash
#
# restore_backup.sh
#
# Interactively restores a backup created by backup_api_install.sh: lists
# available snapshots, lets you pick one (or "latest"), and restores it to
# / on this machine.
#
# Works for two scenarios:
#   1. Same machine, rolling back - /etc/nano-ai-backup/restic.env still
#      exists, so the repository location and password are already known
#      and nothing needs to be re-entered.
#   2. Disaster recovery on a fresh/replacement Nano - no local restic.env
#      exists yet, so this asks for the same repository details
#      backup_api_install.sh originally asked for, plus the encryption
#      password, before it can see any snapshots at all.
#
# Non-interactive inputs (same env vars backup_api_install.sh accepts, for
# scenario 2 only - ignored if restic.env already exists):
#   NANO_BACKUP_TARGET=ssh|s3
#   NANO_BACKUP_SSH_HOST / NANO_BACKUP_SSH_USER / NANO_BACKUP_SSH_PATH
#   NANO_BACKUP_S3_BUCKET / NANO_BACKUP_S3_ENDPOINT /
#   NANO_BACKUP_S3_ACCESS_KEY / NANO_BACKUP_S3_SECRET_KEY
#   RESTIC_PASSWORD - if already exported, skips the password prompt
#   NANO_RESTORE_SNAPSHOT=<id>|latest - skips the "pick a snapshot" prompt
#
# The final "actually overwrite files on this machine" confirmation is
# deliberately NOT covered by setup.sh's --bypassAllChecks/
# --bypassInstallerChecks - restoring overwrites live files and isn't
# something that should ever happen as a side effect of an unrelated
# unattended run. Pass --yes explicitly on this script if you really want
# to skip that one prompt.
#
# Usage:
#   sudo ./restore_backup.sh
#   sudo ./restore_backup.sh --yes
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

AUTO_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=1 ;;
  esac
done

CONF_DIR="/etc/nano-ai-backup"
RESTIC_ENV="${CONF_DIR}/restic.env"

echo "=== Nano AI Backup Restore ==="

echo "[*] Checking for restic..."
if ! command -v restic >/dev/null 2>&1; then
  echo "[*] restic not found, installing..."
  apt-get update -y
  if ! apt-get install -y restic; then
    echo "[!] apt restic unavailable/too old, fetching static binary instead..."
    RESTIC_VER="0.16.4"
    TMP_BZ2=$(mktemp)
    curl -fsSL -o "$TMP_BZ2" \
      "https://github.com/restic/restic/releases/download/v${RESTIC_VER}/restic_${RESTIC_VER}_linux_arm64.bz2"
    bunzip2 -f "$TMP_BZ2"
    install -m 755 "${TMP_BZ2%.bz2}" /usr/local/bin/restic
  fi
fi
restic version

# --- Determine repository connection details ---
if [[ -f "$RESTIC_ENV" ]]; then
  echo "[*] Found existing config at $RESTIC_ENV - using it, no need to re-enter anything."
  set -a; source "$RESTIC_ENV"; set +a
else
  echo "[*] No config found at $RESTIC_ENV - this looks like a fresh/replacement"
  echo "    machine. Enter the details of where the original backups were sent."
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
  else
    echo "Where were backups stored?"
    echo "  1) Remote machine over Tailscale/SSH (SFTP)"
    echo "  2) S3-compatible storage (e.g. Backblaze B2, AWS S3, MinIO)"
    read -rp "Choose [1/2]: " REPO_CHOICE
  fi

  if [[ "$REPO_CHOICE" == "1" ]]; then
    if [[ -n "${NANO_BACKUP_TARGET:-}" ]]; then
      REMOTE_HOST="${NANO_BACKUP_SSH_HOST:?NANO_BACKUP_SSH_HOST is required when NANO_BACKUP_TARGET=ssh}"
      REMOTE_USER="${NANO_BACKUP_SSH_USER:?NANO_BACKUP_SSH_USER is required when NANO_BACKUP_TARGET=ssh}"
      REMOTE_PATH="${NANO_BACKUP_SSH_PATH:?NANO_BACKUP_SSH_PATH is required when NANO_BACKUP_TARGET=ssh}"
    else
      read -rp "Remote host (IP or Tailscale hostname): " REMOTE_HOST
      read -rp "Remote SSH user: " REMOTE_USER
      read -rp "Remote path used for backups (e.g. /mnt/backups/jetson-nano): " REMOTE_PATH
    fi

    KEYFILE="/root/.ssh/id_ed25519_backup"
    if [[ ! -f "$KEYFILE" ]]; then
      echo
      echo "[!] No backup SSH key found at $KEYFILE (expected on a fresh machine)."
      echo "    Restore the original private key to that path, or generate a new"
      echo "    keypair and authorize it on ${REMOTE_USER}@${REMOTE_HOST}, before"
      echo "    this can connect."
      read -rp "Press Enter once that's sorted to continue..." _
    fi

    mkdir -p /root/.ssh && chmod 700 /root/.ssh
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
    export RESTIC_REPOSITORY="sftp:nano-backup-target:${REMOTE_PATH}"

  elif [[ "$REPO_CHOICE" == "2" ]]; then
    if [[ -n "${NANO_BACKUP_TARGET:-}" ]]; then
      S3_BUCKET="${NANO_BACKUP_S3_BUCKET:?NANO_BACKUP_S3_BUCKET is required when NANO_BACKUP_TARGET=s3}"
      S3_ENDPOINT="${NANO_BACKUP_S3_ENDPOINT:-}"
      export AWS_ACCESS_KEY_ID="${NANO_BACKUP_S3_ACCESS_KEY:?NANO_BACKUP_S3_ACCESS_KEY is required when NANO_BACKUP_TARGET=s3}"
      export AWS_SECRET_ACCESS_KEY="${NANO_BACKUP_S3_SECRET_KEY:?NANO_BACKUP_S3_SECRET_KEY is required when NANO_BACKUP_TARGET=s3}"
    else
      read -rp "Bucket name: " S3_BUCKET
      read -rp "Endpoint (blank for AWS S3, or e.g. s3.us-west-000.backblazeb2.com): " S3_ENDPOINT
      read -rp "Access Key ID: " AWS_ACCESS_KEY_ID
      read -rsp "Secret Access Key: " AWS_SECRET_ACCESS_KEY
      echo
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    fi
    if [[ -n "$S3_ENDPOINT" ]]; then
      export RESTIC_REPOSITORY="s3:https://${S3_ENDPOINT}/${S3_BUCKET}"
    else
      export RESTIC_REPOSITORY="s3:s3.amazonaws.com/${S3_BUCKET}"
    fi
  else
    echo "Invalid choice." >&2
    exit 1
  fi

  if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
    echo
    read -rsp "Restic encryption password: " RESTIC_PASSWORD
    echo
  fi
  export RESTIC_PASSWORD
fi

# --- List snapshots and let the user pick one ---
echo
echo "[*] Available snapshots:"
restic snapshots

echo
if [[ -n "${NANO_RESTORE_SNAPSHOT:-}" ]]; then
  SNAPSHOT_ID="$NANO_RESTORE_SNAPSHOT"
  echo "[*] NANO_RESTORE_SNAPSHOT=${SNAPSHOT_ID} - skipping selection prompt."
else
  echo "Enter a snapshot ID to restore (or leave blank for 'latest'):"
  read -rp "> " SNAPSHOT_ID
  SNAPSHOT_ID="${SNAPSHOT_ID:-latest}"
fi

echo
echo "This will restore snapshot '${SNAPSHOT_ID}' to / on THIS machine,"
echo "overwriting any current files that also exist in the backup (it does"
echo "NOT delete files that exist now but aren't in the backup)."
if [[ $AUTO_YES -eq 1 ]]; then
  echo "Type 'yes' to proceed: yes (auto-accepted via --yes)"
else
  read -rp "Type 'yes' to proceed: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo "[*] Restoring snapshot '${SNAPSHOT_ID}'..."
restic restore "$SNAPSHOT_ID" --target /

echo
echo "=== Done ==="
echo "Restore complete. A reboot is recommended before relying on this"
echo "system: sudo reboot"
