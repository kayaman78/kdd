#!/bin/bash
# =============================================================================
# DDD (DockerDatabaseDumper) - Cron Wrapper with Email Notifications
# =============================================================================
# This script should be placed in /usr/local/bin/ and called from cron
#
# Installation:
#   sudo cp ddd-backup.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/ddd-backup.sh
#
# Cron entry (daily at 3 AM):
#   0 3 * * * /usr/local/bin/ddd-backup.sh >> /var/log/ddd-backup.log 2>&1
#
# Configuration:
#   Edit the variables below to match your environment
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURATION - CUSTOMIZE THESE VALUES
# -----------------------------------------------------------------------------

# User and group ID (find with: id -u && id -g)
PUID=1000
PGID=1000

# Paths
CONFIG_PATH="/srv/docker/ddd/config"
BACKUP_PATH="/srv/docker/ddd/dump"
DOCKER_PATH="/srv/docker"

# Docker network name
NETWORK="bridge"

# Backup retention (days)
RETENTION=7

# Email configuration (set ENABLE_EMAIL=true to activate)
ENABLE_EMAIL=false
SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
SMTP_USER="backups@example.com"
SMTP_PASS="your-app-password-here"
SMTP_FROM="backups@example.com"
SMTP_TO="admin@example.com"  # Can add multiple: "admin@example.com ops@example.com"
SMTP_TLS="on"  # Options: auto, on, off

# -----------------------------------------------------------------------------
# SCRIPT EXECUTION - DO NOT MODIFY BELOW THIS LINE
# -----------------------------------------------------------------------------

# Build docker run command
CMD="docker run --rm \
  -e PUID=${PUID} \
  -e PGID=${PGID} \
  -v ${CONFIG_PATH}:/config:ro \
  -v ${BACKUP_PATH}:/backups \
  -v ${DOCKER_PATH}:/srv/docker:ro \
  --network ${NETWORK} \
  ddd:latest /app/backup.sh \
  --retention ${RETENTION}"

# Add email parameters if enabled
if [ "$ENABLE_EMAIL" = true ]; then
    CMD="$CMD \
  --enable-email \
  --smtp-host ${SMTP_HOST} \
  --smtp-port ${SMTP_PORT} \
  --smtp-user ${SMTP_USER} \
  --smtp-pass ${SMTP_PASS} \
  --smtp-from ${SMTP_FROM} \
  --smtp-tls ${SMTP_TLS}"
    
    # Add multiple recipients
    for recipient in $SMTP_TO; do
        CMD="$CMD --smtp-to ${recipient}"
    done
fi

# Execute backup
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting database backup..."
eval $CMD
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Backup completed successfully"
else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Backup completed with errors (exit code: $EXIT_CODE)"
fi

exit $EXIT_CODE