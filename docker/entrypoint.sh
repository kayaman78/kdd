#!/bin/bash
# =============================================================================
# KDD Entrypoint - User Permission Handler
# =============================================================================
# Creates a user with specified PUID/PGID and executes commands as that user
# instead of root, preventing permission issues with generated files.
#
# Also detects Docker socket GID and adds user to that group for API access.
#
# Usage:
#   docker run -e PUID=1000 -e PGID=1000 ...
#
# Default: 1000:1000 (first non-root user on most Linux systems)
# =============================================================================

PUID=${PUID:-1000}
PGID=${PGID:-1000}

# If running as root (PUID=0), skip user creation and run directly
if [ "$PUID" = "0" ] && [ "$PGID" = "0" ]; then
    echo "[entrypoint] Running as root (PUID=0, PGID=0)"
    exec "$@"
    exit 0
fi

# Create group if it doesn't exist
if ! getent group "$PGID" > /dev/null 2>&1; then
    echo "[entrypoint] Creating group with GID $PGID"
    groupadd -g "$PGID" kddbackup
    GROUPNAME="kddbackup"
else
    echo "[entrypoint] Group with GID $PGID already exists"
    GROUPNAME=$(getent group "$PGID" | cut -d: -f1)
fi

# Create user if it doesn't exist
if ! getent passwd "$PUID" > /dev/null 2>&1; then
    echo "[entrypoint] Creating user with UID $PUID"
    useradd -u "$PUID" -g "$PGID" -m -s /bin/bash kddbackup
    USERNAME="kddbackup"
else
    echo "[entrypoint] User with UID $PUID already exists"
    USERNAME=$(getent passwd "$PUID" | cut -d: -f1)
fi

# Detect Docker socket GID and add user to that group (for docker ps/inspect)
if [ -S /var/run/docker.sock ]; then
    # Try Linux stat first, fallback to BSD stat format
    DOCKER_SOCK_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || \
                      stat -f '%g' /var/run/docker.sock 2>/dev/null || \
                      echo "999")
    echo "[entrypoint] Docker socket detected with GID $DOCKER_SOCK_GID"
    
    # Create docker group with that GID if it doesn't exist
    if ! getent group "$DOCKER_SOCK_GID" > /dev/null 2>&1; then
        echo "[entrypoint] Creating docker group with GID $DOCKER_SOCK_GID"
        groupadd -g "$DOCKER_SOCK_GID" dockergroup
        DOCKER_GROUPNAME="dockergroup"
    else
        DOCKER_GROUPNAME=$(getent group "$DOCKER_SOCK_GID" | cut -d: -f1)
    fi
    
    # Add user to docker group
    echo "[entrypoint] Adding $USERNAME to group $DOCKER_GROUPNAME (GID $DOCKER_SOCK_GID)"
    usermod -aG "$DOCKER_SOCK_GID" "$USERNAME" 2>/dev/null || true
fi

# Set ownership on working directories
echo "[entrypoint] Setting permissions on /config and /backups"
chown -R "$PUID:$PGID" /config /backups 2>/dev/null || true

# Execute command as specified user with supplementary groups
echo "[entrypoint] Executing command as $USERNAME (UID=$PUID, GID=$PGID)"
exec setpriv --reuid="$PUID" --regid="$PGID" --init-groups "$@"