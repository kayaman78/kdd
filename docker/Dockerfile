# =============================================================================
# KDD - Komodo Database Dumper
# =============================================================================
# Universal database backup container for Docker environments
# Supports: MySQL/MariaDB 5.5-12.x, PostgreSQL 12-17, MongoDB 4.2-8.0
#
# Build:
#   docker build -t ghcr.io/yourusername/kdd:latest .
#
# License: MIT
# =============================================================================

FROM debian:12-slim

LABEL maintainer="KDD Backup Tool" \
      description="Komodo Database Dumper - Universal Database Backup" \
      version="1.0.0" \
      org.opencontainers.image.source="https://github.com/kayaman78/kdd"

# -----------------------------------------------------------------------------
# Environment Variables
# -----------------------------------------------------------------------------
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
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/debian bookworm stable" \
    > /etc/apt/sources.list.d/docker.list

# Add PostgreSQL official repository (client 17, backward compatible 12-16)
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
    gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] \
    http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list

# -----------------------------------------------------------------------------
# Install Database Clients and Tools
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    docker-ce-cli \
    default-mysql-client \
    postgresql-client-17 \
    bash \
    coreutils \
    findutils \
    jq \
    gzip \
    bzip2 \
    xz-utils \
    msmtp \
    msmtp-mta \
    iputils-ping \
    netcat-openbsd \
    tzdata \
 && rm -rf /var/lib/apt/lists/*

# Install yq v4 (YAML processor)
RUN wget -qO /usr/local/bin/yq \
    https://github.com/mikefarah/yq/releases/download/v4.40.5/yq_linux_amd64 && \
    chmod +x /usr/local/bin/yq

# Install MongoDB Database Tools (100.14.0 - supports MongoDB 4.2-8.0)
RUN wget -q https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian12-x86_64-100.14.0.deb \
    -O /tmp/mongo-tools.deb && \
    dpkg -i /tmp/mongo-tools.deb && \
    rm /tmp/mongo-tools.deb

# Verify installed versions
RUN echo "=== Database Client Versions ===" && \
    mysql --version && \
    psql --version && \
    mongodump --version | head -n1 && \
    yq --version && \
    msmtp --version

# -----------------------------------------------------------------------------
# Setup Application
# -----------------------------------------------------------------------------
WORKDIR /app

COPY setup.sh backup.sh ./
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /app/setup.sh /app/backup.sh /entrypoint.sh && \
    mkdir -p /config /backups

# -----------------------------------------------------------------------------
# Volumes and Health Check
# -----------------------------------------------------------------------------
VOLUME ["/config", "/backups"]

HEALTHCHECK --interval=60s --timeout=10s --start-period=5s --retries=3 \
    CMD test -x /app/backup.sh && yq --version > /dev/null || exit 1

# -----------------------------------------------------------------------------
# Entrypoint
# -----------------------------------------------------------------------------
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]