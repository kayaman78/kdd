# Configuration Guide - DDD (DockerDatabaseDumper)

This document lists all parameters you need to customize for your specific environment.

## Before First Use

Review and adjust these settings in the project files to match your environment.

## Script Parameters

### setup.sh - Lines 29-30

```bash
# Default location for Docker compose files
DOCKER_ROOT="${DOCKER_ROOT:-/srv/docker}"

# Default Docker network name
DEFAULT_NETWORK="bridge"
```

**Customize if**:
- Your Docker compose files are not in `/srv/docker`
- Your main Docker network is not named `bridge`

**Common alternatives**:
- `/opt/docker`
- `/home/user/docker`
- `/var/lib/docker-compose`

**To find your Docker network name**:
```bash
docker network ls
```

### backup.sh - Line 28

```bash
# Number of days to keep old backups
RETENTION_DAYS=7
```

**Customize if**:
- You want to keep backups longer (e.g., `RETENTION_DAYS=30`)
- You have limited disk space (e.g., `RETENTION_DAYS=3`)

### entrypoint.sh - Lines 16-17

```bash
# Default user and group ID for file ownership
PUID=${PUID:-1000}
PGID=${PGID:-1000}
```

**Customize if**:
- Your user ID is not 1000
- You want files owned by a different user

**To find your user ID on Linux**:
```bash
id -u  # Shows your user ID
id -g  # Shows your group ID
```

### Dockerfile - Line 15

```bash
# Container metadata
LABEL maintainer="Your Name <your.email@example.com>"
```

**Customize**:
- Replace with your name and email

### Dockerfile - Line 24

```bash
# Timezone for backup timestamps
ENV TZ=Europe/Rome
```

**Customize if** you're not in Europe/Rome timezone.

**Common alternatives**:
- `America/New_York`
- `America/Los_Angeles`
- `Asia/Tokyo`
- `UTC`

**Full list**: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones

## Docker Run Parameters

When executing the container, customize these parameters:

### User ID and Group ID

```bash
-e PUID=1000 \
-e PGID=1000 \
```

**Replace** `1000` with your actual user and group ID.

### Volume Paths

```bash
-v /srv/docker:/srv/docker:ro \
```

**Replace** `/srv/docker` with your Docker compose files location.

```bash
-v $(pwd)/config:/config \
-v $(pwd)/dump:/backups \
```

**Change** `$(pwd)` to absolute paths if needed:
- `/home/user/db-backup/config:/config`
- `/home/user/db-backup/dump:/backups`

### Network Name

```bash
--network bridge \
```

**Replace** `bridge` with your actual Docker network name.

## Configuration File (config.yaml)

After running `setup.sh`, review the generated `config/config.yaml` and verify:

### Database Names

```yaml
mysql:
  - name: "myapp"           # This appears in backup directory names
    host: "myapp_db_1"      # Docker container name
    dbname: "myapp_production"  # Actual database name inside container
```

Make sure these values are correct for your environment.

### Network Names

```yaml
mysql:
  - name: "myapp"
    network: "myapp_network"  # Must match actual Docker network
```

Verify network name matches your Docker setup.

### Credentials

```yaml
mysql:
  - name: "myapp"
    user: "root"
    password: "your_password"  # Ensure this is correct
```

**Security reminder**: This file contains plain-text passwords. Protect it:
```bash
chmod 600 config/config.yaml
```

## Cron Configuration

In your cron wrapper script (`/usr/local/bin/db-backup.sh`):

```bash
#!/bin/bash
docker run --rm \
  -e PUID=1000 \                                    # Your user ID
  -e PGID=1000 \                                    # Your group ID
  -v /srv/docker/db-backup/config:/config:ro \     # Config path
  -v /srv/docker/db-backup/dump:/backups \         # Backup destination
  -v /srv/docker:/srv/docker:ro \                  # Docker compose path
  --network bridge \                               # Network name
  db-backup-tool:latest /app/backup.sh
```

**Customize all paths and IDs** to match your environment.

## Testing Your Configuration

After customizing, test each component:

### 1. Test Setup Script

```bash
docker run --rm -it \
  -e PUID=$(id -u) \
  -e PGID=$(id -g) \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v YOUR_DOCKER_PATH:/srv/docker:ro \
  -v $(pwd)/config:/config \
  --network YOUR_NETWORK \
  db-backup-tool:latest /app/setup.sh --interactive
```

Replace:
- `YOUR_DOCKER_PATH` with your actual path
- `YOUR_NETWORK` with your network name

### 2. Test Backup Script

```bash
docker run --rm \
  -e PUID=$(id -u) \
  -e PGID=$(id -g) \
  -v $(pwd)/config:/config:ro \
  -v $(pwd)/dump:/backups \
  -v YOUR_DOCKER_PATH:/srv/docker:ro \
  --network YOUR_NETWORK \
  db-backup-tool:latest /app/backup.sh --verbose
```

### 3. Verify Results

```bash
# Check generated config
cat config/config.yaml

# Check backup files
ls -lh dump/*/

# Check file ownership
ls -ln dump/
# Should show your PUID:PGID
```

## Environment Variables Reference

Complete list of environment variables you can set:

| Variable | Default | Description | Customize? |
|----------|---------|-------------|------------|
| `PUID` | 1000 | User ID for file ownership | Yes |
| `PGID` | 1000 | Group ID for file ownership | Yes |
| `TZ` | Europe/Rome | Timezone for timestamps | Yes |
| `DOCKER_ROOT` | /srv/docker | Docker compose files location | Yes |
| `RETENTION_DAYS` | 7 | Backup retention period | Optional |

## Quick Start Checklist

Before first use, ensure you have:

- [ ] Updated `DOCKER_ROOT` in setup.sh if needed
- [ ] Updated `DEFAULT_NETWORK` in setup.sh if needed
- [ ] Updated `TZ` in Dockerfile if not in Europe/Rome
- [ ] Updated `maintainer` label in Dockerfile
- [ ] Verified your PUID and PGID (run `id` command)
- [ ] Tested setup.sh with correct paths
- [ ] Reviewed generated config.yaml
- [ ] Tested backup.sh successfully
- [ ] Configured cron with correct paths
- [ ] Set correct permissions on config.yaml (600)

## Getting Help

If you need to find your current configuration:

```bash
# Find your user and group ID
id

# Find your Docker networks
docker network ls

# Find your Docker compose files location
find / -name "docker-compose.yml" 2>/dev/null

# Check where your containers store data
docker inspect CONTAINER_NAME | grep -i "source"

# List all running containers and their networks
docker ps --format "{{.Names}}\t{{.Networks}}"
```

## Common Configuration Scenarios

### Scenario 1: All defaults work

No changes needed! Just run:
```bash
docker build -t db-backup-tool:latest .
# Then use as documented in README
```

### Scenario 2: Custom Docker path

Change in `setup.sh`:
```bash
DOCKER_ROOT="${DOCKER_ROOT:-/opt/docker}"
```

And in docker run commands:
```bash
-v /opt/docker:/srv/docker:ro \
```

### Scenario 3: Multiple networks

If databases are on different networks, you have two options:

**Option A**: Use host network mode
```bash
--network host \
```

**Option B**: Connect to specific network per database (configured in config.yaml)
```yaml
mysql:
  - name: "app1"
    network: "network1"
  - name: "app2"
    network: "network2"
```

### Scenario 4: Non-standard user ID

If your user ID is not 1000:
```bash
# Find your ID
id -u

# Use in all docker run commands
-e PUID=1234 \
-e PGID=1234 \
```

## Final Notes

- Always test in a non-production environment first
- Keep a backup of your config.yaml
- Document any custom changes you make
- Review logs regularly: `/var/log/db-backup.log`
- Test restore procedure before relying on backups

---

**Remember**: When sharing your configuration or asking for help, never include passwords from config.yaml!