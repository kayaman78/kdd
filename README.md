# DockerDatabaseDumper (DDD)

Automated backup solution for Docker-based databases with support for MySQL/MariaDB, PostgreSQL, MongoDB, and Redis.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)

## Features

- **Automatic Discovery**: Scans running Docker containers and detects databases automatically
- **Multi-Database Support**: MySQL/MariaDB (all versions), PostgreSQL 12-17, MongoDB 4.x-8.x, Redis
- **Safe Hot Backups**: Uses transaction-safe methods for consistent backups without downtime
- **Automatic Rotation**: Configurable retention policy (default: 7 days)
- **Email Notifications**: Optional HTML email reports with color-coded status
- **Detailed Logging**: Text logs with automatic rotation
- **PUID/PGID Support**: LinuxServer.io style user mapping for correct file permissions
- **Network Aware**: Automatically detects and uses correct Docker networks
- **Lightweight**: Debian-based image with only required database clients

## Supported Databases

| Database | Versions | Backup Method | Hot Backup |
|----------|----------|---------------|------------|
| MySQL | All | mysqldump | Yes (InnoDB) |
| MariaDB | All | mysqldump | Yes |
| PostgreSQL | 12-17 | pg_dump | Yes |
| MongoDB | 4.x-8.x | mongodump | Yes |
| Redis | All | Manual (see docs) | N/A (cache) |

## Prerequisites

- Docker installed on host machine
- Running Docker containers with databases
- Access to `/var/run/docker.sock`
- Basic knowledge of Docker commands

## Installation

### Step 1: Clone Repository

```bash
git clone https://github.com/yourusername/docker-db-backup.git
cd docker-db-backup
```

### Step 2: Build Container Image

```bash
docker build -t db-backup-tool:latest .
```

Build time: approximately 2-3 minutes depending on your internet connection.

## Configuration

### Important: Adjust Paths in Scripts

Before using the tool, you may need to adjust the following parameters in the scripts to match your environment:

**In `setup.sh` (line 29-30):**
```bash
DOCKER_ROOT="${DOCKER_ROOT:-/srv/docker}"  # Change to your Docker compose files location
DEFAULT_NETWORK="bridge"                    # Change to your main Docker network name
```

**In `entrypoint.sh` (line 16-17):**
```bash
PUID=${PUID:-1000}  # Change to match your user ID
PGID=${PGID:-1000}  # Change to match your group ID
```

To find your user ID and group ID on Linux:
```bash
id -u  # Shows your PUID
id -g  # Shows your PGID
```

### Automatic Database Discovery

Run the setup script to automatically scan your Docker containers and generate configuration:

```bash
docker run --rm -it \
  -e PUID=1000 \
  -e PGID=1000 \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v /srv/docker:/srv/docker:ro \
  -v $(pwd)/config:/config \
  --network bridge \
  ddd:latest /app/setup.sh --interactive
```

**Important**: Replace `/srv/docker` with your actual Docker compose files location, and `bridge` with your network name.

This will:
1. Scan all running Docker containers
2. Detect databases (MySQL, PostgreSQL, MongoDB)
3. Extract credentials from environment variables
4. Generate `config/config.yaml` with detected databases

**Options:**
- `--interactive`: Ask for confirmation before adding each database (recommended for first run)
- `--docker-root /path`: Specify custom Docker compose files location

### Manual Configuration

Alternatively, create `config/config.yaml` manually:

```yaml
# Database backup configuration
# Generated: 2024-11-23

mysql:
  - name: "myapp"
    host: "myapp_db_1"
    port: "3306"
    dbname: "myapp_production"
    user: "root"
    password: "your_password"
    network: "myapp_network"

postgres:
  - name: "analytics"
    host: "analytics_postgres_1"
    port: "5432"
    dbname: "analytics"
    user: "postgres"
    password: "your_password"
    network: "analytics_network"

mongo:
  - name: "unifi"
    host: "unifi_mongo_1"
    port: "27017"
    dbname: "unifi"
    user: "root"
    password: "your_password"
    authdb: "admin"
    network: "unifi_network"

redis: []
```

**Note on Redis**: Redis is typically used as a cache and does not require backups. If you have Redis with persistent data (AOF/RDB), you can enable Redis backups by adding entries to the `redis` section or by manually copying the `dump.rdb` file from the Redis container.

## Usage

### Manual Backup

Execute a one-time backup of all configured databases:

```bash
docker run --rm \
  -e PUID=1000 \
  -e PGID=1000 \
  -v $(pwd)/config:/config:ro \
  -v $(pwd)/dump:/backups \
  -v /srv/docker:/srv/docker:ro \
  --network bridge \
  ddd:latest /app/backup.sh
```

**Options:**
- `--verbose`: Show detailed debug output
- `--retention N`: Keep backups for N days (default: 7)
- `--log-file PATH`: Custom log file path (default: /backups/backup.log)

Example with options:
```bash
docker run --rm \
  -e PUID=1000 \
  -e PGID=1000 \
  -v $(pwd)/config:/config:ro \
  -v $(pwd)/dump:/backups \
  -v /srv/docker:/srv/docker:ro \
  --network bridge \
  db-backup-tool:latest /app/backup.sh --verbose --retention 30
```

### Email Notifications

Enable email notifications to receive HTML reports after each backup:

```bash
docker run --rm \
  -e PUID=1000 \
  -e PGID=1000 \
  -v $(pwd)/config:/config:ro \
  -v $(pwd)/dump:/backups \
  -v /srv/docker:/srv/docker:ro \
  --network bridge \
  ddd:latest /app/backup.sh \
  --enable-email \
  --smtp-host smtp.gmail.com \
  --smtp-port 587 \
  --smtp-user backups@example.com \
  --smtp-pass "your-app-password" \
  --smtp-from backups@example.com \
  --smtp-to admin@example.com \
  --smtp-tls on
```

**Email Features:**
- Color-coded status (green/yellow/red)
- Detailed per-database results
- Disk usage statistics
- Support for multiple recipients
- Works with Gmail, Office365, SendGrid, and custom SMTP servers

For complete email configuration guide, see [EMAIL_NOTIFICATIONS.md](EMAIL_NOTIFICATIONS.md)

### Automated Backups with Cron

For production environments, set up automated daily backups using cron.

#### Create Wrapper Script

```bash
sudo nano /usr/local/bin/db-backup.sh
```

Content:
```bash
#!/bin/bash
# Universal Database Backup - Cron Wrapper
# Adjust paths and parameters as needed

docker run --rm \
  -e PUID=1000 \
  -e PGID=1000 \
  -v /srv/docker/ddd/config:/config:ro \
  -v /srv/docker/ddd/dump:/backups \
  -v /srv/docker:/srv/docker:ro \
  --network bridge \
  ddd:latest /app/backup.sh
```

Make executable:
```bash
sudo chmod +x /usr/local/bin/db-backup.sh
```

#### Setup Cron Job

```bash
sudo crontab -e
```

Add daily backup at 3:00 AM:
```cron
0 3 * * * /usr/local/bin/db-backup.sh >> /var/log/db-backup.log 2>&1
```

Other useful schedules:
```cron
0 */6 * * *  # Every 6 hours
0 2 * * 0    # Weekly on Sunday at 2 AM
0 4 1 * *    # Monthly on the 1st at 4 AM
```

## Directory Structure

```
docker-db-backup/
├── Dockerfile              # Container image definition
├── entrypoint.sh          # PUID/PGID handler
├── setup.sh               # Database discovery script
├── backup.sh              # Backup execution script
├── README.md              # This file
├── EMAIL_NOTIFICATIONS.md # Email setup guide
├── LICENSE                # MIT License
├── config/
│   └── config.yaml        # Generated database configuration
└── dump/                  # Backup destination directory
    ├── backup.log         # Execution log (auto-rotated)
    ├── mysql-app/
    │   ├── dump-2024-11-23_03-00.sql.gz
    │   └── dump-2024-11-24_03-00.sql.gz
    ├── postgres-analytics/
    │   └── dump-2024-11-23_03-00.sql.gz
    └── mongo-unifi/
        └── dump-2024-11-23_03-00.archive.gz
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | 1000 | User ID for file ownership |
| `PGID` | 1000 | Group ID for file ownership |
| `TZ` | Europe/Rome | Timezone for backup timestamps |

## Backup Methods

### MySQL / MariaDB

**Command**: `mysqldump --single-transaction --routines --triggers --events`

**Features**:
- Uses `--single-transaction` for consistent snapshot without locking (InnoDB tables)
- Includes stored procedures, triggers, and events
- Compresses output with gzip

**Note**: MyISAM tables will be locked during backup. Consider converting to InnoDB for hot backups.

### PostgreSQL

**Command**: `pg_dump --clean --if-exists`

**Features**:
- Uses PostgreSQL's MVCC for consistent snapshots
- Includes DROP statements for clean restore
- Compatible with PostgreSQL 12-17
- Compresses output with gzip

### MongoDB

**Command**: `mongodump --archive --gzip`

**Features**:
- Creates compressed archive of database
- Supports MongoDB 4.x through 8.x
- Uses standard authentication (no replica set required)

**Note**: For perfect consistency under heavy writes, consider using replica sets with oplog backup.

### Redis

Redis is typically used as a cache and does not require backups. If you need to backup Redis persistent data:

**Option 1**: Copy RDB file directly from container
```bash
docker cp redis_container:/data/dump.rdb ./backup/redis-$(date +%Y%m%d).rdb
```

**Option 2**: Trigger BGSAVE and copy
```bash
docker exec redis_container redis-cli BGSAVE
# Wait a few seconds
docker cp redis_container:/data/dump.rdb ./backup/
```

## Restore Procedures

### MySQL Restore

```bash
zcat dump/myapp/dump-2024-11-23_03-00.sql.gz | \
  docker exec -i myapp_db_1 mysql -uroot -pPASSWORD myapp_production
```

### PostgreSQL Restore

```bash
zcat dump/analytics/dump-2024-11-23_03-00.sql.gz | \
  docker exec -i analytics_postgres_1 psql -U postgres -d analytics
```

### MongoDB Restore

```bash
docker run --rm -it \
  --network myapp_network \
  -v $(pwd)/dump:/backups:ro \
  db-backup-tool:latest \
  mongorestore --host=unifi_mongo_1 --port=27017 \
    --username=root --password=PASSWORD \
    --authenticationDatabase=admin \
    --archive=/backups/unifi/dump-2024-11-23_03-00.archive.gz \
    --gzip
```

## Troubleshooting

### Permission Denied Errors

**Problem**: Backup files are owned by root or wrong user.

**Solution**: Ensure PUID and PGID match your user:
```bash
id -u  # Get your user ID
id -g  # Get your group ID
```

Then use these values in docker run command:
```bash
-e PUID=1000 -e PGID=1000  # Replace with your IDs
```

### PostgreSQL Version Mismatch

**Problem**: `pg_dump: error: aborting because of server version mismatch`

**Solution**: The container uses PostgreSQL 17 client which is backward compatible with versions 12-16. If you see this error, check that the actual issue isn't authentication or network connectivity.

### MongoDB Authentication Failed

**Problem**: `Authentication failed`

**Solution**: Verify credentials work:
```bash
docker exec mongo_container mongosh \
  --username root \
  --password YOUR_PASSWORD \
  --authenticationDatabase admin \
  --eval "db.adminCommand('listDatabases')"
```

### Network Connection Failed

**Problem**: Cannot connect to database container.

**Solution**: Ensure backup container is on the same network:
```bash
# List networks
docker network ls

# Check container network
docker inspect container_name | grep NetworkMode

# Use correct network in docker run command
--network your_network_name
```

### No Databases Detected During Setup

**Problem**: `setup.sh` finds no databases.

**Solution**: 
1. Verify containers are running: `docker ps`
2. Check containers have environment variables: `docker inspect container_name | grep -i env`
3. Try manual configuration in `config.yaml`

## Security Considerations

**Important**: This tool stores database passwords in plain text in `config.yaml`. Take appropriate security measures:

- Restrict file permissions: `chmod 600 config/config.yaml`
- Keep backups in secure location with restricted access
- Consider encrypting backup files for long-term storage
- Use read-only mounts where possible (`:ro` flag)
- Run with minimal privileges (non-root PUID/PGID)
- Rotate passwords regularly
- Do not commit `config.yaml` to version control (add to `.gitignore`)

## Performance Considerations

- Backup duration depends on database size and disk I/O
- Expect approximately 50-100 MB/s for compressed backups
- Schedule backups during low-traffic periods
- Monitor disk space usage for backup directory
- Consider offsite backup replication for disaster recovery

## Contributing

Contributions are welcome. Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Test your changes thoroughly
4. Commit your changes (`git commit -m 'Add amazing feature'`)
5. Push to the branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by LinuxServer.io PUID/PGID pattern
- Database client tools: MySQL, PostgreSQL, MongoDB projects
- Community feedback and contributions

## Support

- **Issues**: [GitHub Issues](https://github.com/yourusername/ddd/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/ddd/discussions)
- **Wiki**: [Project Wiki](https://github.com/yourusername/ddd/wiki)

---

**Project Status**: Active development | **Latest Version**: 1.0.0 | **Maintained**: Yes