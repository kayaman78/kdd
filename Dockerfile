# =============================================================================
# DockerDatabaseDumper (DDD) - Universal Database Backup Container
# =============================================================================
# Automated backup tool for Docker databases
# Supports: MySQL/MariaDB (all versions), PostgreSQL 12-17, MongoDB 4.x-8.x
# 
# Build:
#   docker build -t ddd:latest .
#
# Usage:
#   docker run --rm \
#     -v /var/run/docker.sock:/var/run/docker.sock:ro \
#     -v /srv/docker:/srv/docker:ro \
#     -v /srv/docker/ddd/config:/config \
#     -v /srv/docker/ddd/dump:/backups \
#     --network bridge \
#     ddd:latest /app/backup.sh
#
# GitHub: https://github.com/kayaman78/ddd
# License: MIT
# =============================================================================

FROM debian:12-slim

# Container metadata
LABEL maintainer="Your Name <your.email@example.com>" \
      description="DockerDatabaseDumper (DDD) - Universal Database Backup Tool" \
      version="1.0.0" \
      org.opencontainers.image.source="https://github.com/yourusername/ddd"

# -----------------------------------------------------------------------------
# Environment Variables
# -----------------------------------------------------------------------------
# TZ: Timezone for backup timestamps (change as needed)
# PUID/PGID: User/Group ID for file ownership (default: 1000)
ENV TZ=Europe/Rome \
    DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:$PATH \
    PUID=1000 \
    PGID=1000

# -----------------------------------------------------------------------------
# Install Base Packages and Repository Keys
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    wget \
 && rm -rf /var/lib/apt/lists/*

# Add Docker official repository for docker-cli
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

# Add PostgreSQL official repository for latest client versions (12-17)
# This ensures compatibility with all modern PostgreSQL servers
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
    gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" | \
    tee /etc/apt/sources.list.d/pgdg.list

# Add MongoDB official repository for version 8.x tools
# IMPORTANT: If using MongoDB 7.x or older, change "8.0" to your version
RUN curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
    gpp --dearmor -o /usr/share/keyrings/mongodb-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/mongodb-archive-keyring.gpg] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" | \
    tee /etc/apt/sources.list.d/mongodb-org-8.0.list

# -----------------------------------------------------------------------------
# Install Database Clients and Tools
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Docker CLI to query container metadata via socket
    docker-ce-cli \
    # MySQL/MariaDB client (supports all MySQL/MariaDB versions)
    default-mysql-client \
    # PostgreSQL 17 client (backward compatible with PG 12-16)
    postgresql-client-17 \
    # MongoDB database tools (compatible with MongoDB 4.x-8.x)
    mongodb-database-tools \
    # Scripting utilities
    bash \
    coreutils \
    findutils \
    # YAML/JSON parsing for config and Docker API
    jq \
    # Compression tools for backup files
    gzip \
    bzip2 \
    xz-utils \
    # Email sending capability (msmtp + msmtp-mta for sendmail compatibility)
    msmtp \
    msmtp-mta \
    # Network debugging tools (optional but useful)
    iputils-ping \
    netcat-openbsd \
    # Timezone data
    tzdata \
 && rm -rf /var/lib/apt/lists/*

# Install yq manually (not available in Debian repos)
# yq v4 - YAML processor used for config parsing
RUN wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.40.5/yq_linux_amd64 && \
    chmod +x /usr/local/bin/yq

# Verify installed database client versions (logged during build)
RUN echo "=== Installed Database Client Versions ===" && \
    mysql --version && \
    psql --version && \
    mongodump --version | head -n1 && \
    yq --version && \
    msmtp --version

# -----------------------------------------------------------------------------
# Setup Application Directory
# -----------------------------------------------------------------------------
WORKDIR /app

# Copy backup scripts into container
# These are embedded in the image for reliability
COPY setup.sh backup.sh ./

# Copy entrypoint for PUID/PGID handling
COPY entrypoint.sh /entrypoint.sh

# Make all scripts executable
RUN chmod +x /app/setup.sh /app/backup.sh /entrypoint.sh

# Create mount points for volumes
RUN mkdir -p /config /backups

# -----------------------------------------------------------------------------
# Volume Definitions
# -----------------------------------------------------------------------------
# /config   - Configuration directory (config.yaml)
# /backups  - Backup destination directory
VOLUME ["/config", "/backups"]

# -----------------------------------------------------------------------------
# Health Check
# -----------------------------------------------------------------------------
# Verifies that scripts exist and yq is functional
HEALTHCHECK --interval=60s --timeout=10s --start-period=5s --retries=3 \
    CMD test -x /app/backup.sh && yq --version > /dev/null || exit 1

# -----------------------------------------------------------------------------
# Container Startup
# -----------------------------------------------------------------------------
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]