# KDD — Komodo Database Dumper

**Project Status**: Active development | **Latest Version**: 1.0.7 | **Maintained**: Yes

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)
[![Komodo](https://img.shields.io/badge/komodo-action-blue.svg)](https://github.com/mbecker20/komodo)

Universal database backup solution for Docker environments, designed to work seamlessly with [Komodo](https://github.com/mbecker20/komodo) orchestration.

> Part of the **KDD ecosystem** — see also [DABS](https://github.com/kayaman78/dabs) for SQLite, [DABV](https://github.com/kayaman78/dabv) for Docker volumes, and [KCR](https://github.com/kayaman78/kcr) to run shell-based backup tools from a Komodo Action.

---

## Features

- **Automatic Discovery**: Scans running Docker containers and detects databases automatically
- **Multi-Database Support**: MySQL/MariaDB (all versions), PostgreSQL 12-17, MongoDB 4.x-8.x, Redis
- **Safe Hot Backups**: Uses transaction-safe methods for consistent backups without downtime
- **Automatic Rotation**: Configurable retention policy (default: 7 days)
- **Backup Verification**: Every backup is verified immediately after creation (gzip integrity, dump completion marker, size trend)
- **Email Notifications**: Optional HTML email reports with color-coded status per database, separate Backup and Verify columns
- **Push Notifications**: Optional Telegram and ntfy alerts — fully independent from each other and from email
- **Detailed Logging**: Daily log files with automatic retention-based rotation
- **PUID/PGID Support**: LinuxServer.io style user mapping for correct file permissions
- **Network Aware**: Automatically detects and uses correct Docker networks
- **Lightweight**: Debian-based image with only required database clients

---

## Supported Databases

| Database | Versions | Backup Method | Hot Backup |
|----------|----------|---------------|------------|
| MySQL | All | mysqldump | Yes (InnoDB) |
| MariaDB | All | mysqldump | Yes |
| PostgreSQL | 12-17 | pg_dump | Yes |
| MongoDB | 4.x-8.x | mongodump | Yes |

---

## SQLite Support

KDD handles network-based databases via Docker. SQLite is file-based and requires a different approach — which is exactly what the companion projects in this ecosystem are built for.

### 🗄️ [DABS — Docker Automated Backup for SQLite](https://github.com/kayaman78/dabs)

DABS is a standalone bash script that auto-discovers SQLite databases mounted by running containers, stops each service gracefully, compresses the files, and restarts — with WAL support, retention policy, and the same HTML email reporting you get from KDD.

### 📦 [DABV — Docker Automated Backup for Volumes](https://github.com/kayaman78/dabv)

DABV backs up named Docker volumes that don't have a bind mount path. It spins up a temporary Alpine container, mounts the volume read-only, and writes a compressed tar archive to the host — ready for restic or any other tool to pick up.

### ⚙️ [KCR — Komodo Command Runner](https://github.com/kayaman78/kcr)

KCR is a Komodo Action template that lets you run arbitrary shell commands on your servers directly from Komodo — including DABS and DABV. No extra containers, no mounts. Just drop the Action in Komodo, point it at your script, and you're done.

### Running everything together

The recommended setup is a **Komodo Procedure** that chains KDD and DABS sequentially:

1. KDD Action → backs up MySQL, PostgreSQL, MongoDB
2. KCR Action running DABS → backs up all SQLite databases on the same host
3. KCR Action running DABV → backs up named Docker volumes
3. One schedule, one place to monitor, separate email reports per job

This gives you complete database coverage across your entire Docker stack with zero overlap and minimal configuration.

---

## Prerequisites

- Docker installed on host machine
- Running Docker containers with databases
- Access to `/var/run/docker.sock`
- Basic knowledge of Docker commands
- Komodo

## Quick Start

### 1. Setup Configuration

Run the setup script on your server to auto-discover databases.
Use SSH or Komodo shell on the target server.
Adjust the path of the Docker stacks.

```bash
mkdir -p /dockerpath/kdd/{config,dump}
cd /dockerpath/kdd

docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v $(pwd)/config:/config \
  ghcr.io/kayaman78/kdd:latest /app/setup.sh --interactive
```

See [SETUP.md](docker/SETUP.md) for detailed setup instructions.

### 2. Create Komodo Action

In Komodo go to **Actions → New Action**, paste the content of [dump-action-template.ts](komodo/dump-action-template.ts) into the Script field, and save.

> Always use the file from the repo — it stays in sync with new features and parameters.

### 3. Configure Action Parameters

Add this JSON to your Action's configuration field or use always updated [arguments template](komodo/arguments-template.json):

```json
{
  "server_name": "prod-server-01",
  "runner_network": "bridge-01",
  "backup_networks": ["bridge-01", "bridge-02"],
  "config_path": "/data/stacks/production/kdd/config",
  "dump_path": "/data/stacks/production/kdd/dump",
  "retention_days": "14",
  "timezone": "Europe/Rome",
  "server_display_name": "prod-server-01",
  "job_name": "Backup Report",
  "image": "ghcr.io/kayaman78/kdd:latest",
  "smtp": {
    "enabled": "false",
    "host": "smtp.example.com",
    "port": "587",
    "user": "",
    "pass": "",
    "from": "kdd@example.com",
    "to": "admin@example.com",
    "tls": "auto"
  },
  "telegram": {
    "enabled": "false",
    "token": "123456:ABC-your-bot-token",
    "chat_id": "-1001234567890"
  },
  "ntfy": {
    "enabled": "false",
    "url": "https://ntfy.sh",
    "topic": "kdd-backups"
  },
  "notify": {
    "attach_log": "false"
  }
}
```

### 4. Schedule Backups

Configure an Action Schedule (e.g., daily at 2 AM) or use a Komodo Procedure for multiple sequential backups.

---

## Notifications

KDD supports three independent notification channels. Each can be enabled or disabled without affecting the others.

### Email

Full HTML report with color-coded table, per-database Backup and Verify status, disk usage summary. Best for detailed post-run review.

### Telegram

Compact message sent to a bot/channel. Requires a bot token and chat ID. Set `telegram.enabled: "true"` and fill `token` and `chat_id`.

Example message:
```
KDD Backup — prod-server | 2025-01-15 03:00
MySQL 2 OK 0 ERR
PostgreSQL 1 OK 0 ERR
Verify 3 OK 0 WARN 0 ERR
```

### ntfy

Sends a push notification to any ntfy-compatible client (ntfy.sh or self-hosted). Priority is set automatically: default on success, urgent on any backup or verify error — useful to wake up the device even in Do Not Disturb mode.

Set `ntfy.enabled: "true"`, `ntfy.url` and `ntfy.topic`.

### Log attachment

Set `notify.attach_log: "true"` to attach the current day's log file to both Telegram and ntfy notifications. Useful to inspect errors directly from the phone without opening SSH.

---

## Architecture

**Network-based separation**: KDD uses Docker networks to organize backups. Create one Action per Docker network you want to backup. This allows:

- Independent backup schedules per network (prod daily, test weekly)
- Separate email notifications per environment
- Network isolation for security

---

## Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `server_name` | Komodo server name | required |
| `runner_network` | Primary Docker network | required |
| `config_path` | Path to config.yaml | required |
| `dump_path` | Backup storage directory | required |
| `retention_days` | Days to keep backups | `7` |
| `timezone` | Container timezone | `Europe/Rome` |
| `server_display_name` | Name in notifications | `KDD` |
| `job_name` | Name in email header | `Backup Report` |
| `smtp.enabled` | Enable email reports | `false` |
| `smtp.host` | SMTP server | - |
| `smtp.port` | SMTP port | `587` |
| `smtp.user` | SMTP username | - |
| `smtp.pass` | SMTP password | - |
| `smtp.from` | From email address | - |
| `smtp.to` | To email (comma-separated) | - |
| `smtp.tls` | TLS mode: auto/on/off | `auto` |
| `telegram.enabled` | Enable Telegram notifications | `false` |
| `telegram.token` | Bot token | - |
| `telegram.chat_id` | Chat or channel ID | - |
| `ntfy.enabled` | Enable ntfy notifications | `false` |
| `ntfy.url` | ntfy server URL | - |
| `ntfy.topic` | ntfy topic | - |
| `notify.attach_log` | Attach log to push notifications | `false` |

---

## How It Works

1. **Setup**: `setup.sh` scans Docker containers and generates `config.yaml`
2. **Execution**: Komodo Action triggers `backup.sh` with network filter
3. **Backup**: Creates compressed dumps of all databases on specified network
4. **Verification**: Checks gzip integrity, dump completion marker, and size trend
5. **Rotation**: Removes backups and logs older than retention period
6. **Notification**: Sends email report, Telegram message, and/or ntfy alert — each independently

---

## How Verification Works

After each backup is created, KDD runs three checks in sequence.

**1. gzip integrity**
Runs `gzip -t` on the `.gz` file. Catches truncated or corrupt archives caused by write errors, disk issues, or interrupted dumps.

**2. Dump completion marker**
Reads the last 5 lines of the compressed dump via `zcat | tail -5` — no full decompression needed. Checks for the marker that the dump tool always writes as the final line when it completes successfully:

- MySQL/MariaDB → `Dump completed`
- PostgreSQL → `PostgreSQL database dump complete`
- MongoDB → not applicable; mongodump writes atomically, gzip integrity + non-empty is sufficient

**3. Size trend**
Compares the size of the new backup against the most recent previous backup for the same database. If the new file is smaller by more than `SIZE_DROP_WARN`% (default: 20%), the verify is marked WARN. This catches silent data loss.

### Verify vs Backup status in the email

| Backup | Verify | Meaning |
|--------|--------|---------|
| success | OK | Backup written and verified clean |
| success | WARN | Backup valid but size dropped unexpectedly — investigate |
| success | FAIL | Backup written but corrupt or incomplete — do not rely on it |
| failed | skipped | Backup failed, verify not attempted |

---

## Log Structure

```
/backups/
├── <db-name>/
│   └── dump-YYYY-MM-DD_HH-MM.sql.gz
└── log/
    ├── backup_20250115.log
    ├── backup_20250116.log
    └── ...
```

---

## Building

Pre-built images are available at `ghcr.io/kayaman78/kdd:latest`

To build locally:

```bash
docker build -t kdd:latest .
```

---

## Changelog

### v1.0.7
- Added Telegram push notifications (independent of email and ntfy)
- Added ntfy push notifications (independent of email and Telegram)
- Added `notify.attach_log` option to attach the daily log to push notifications
- ntfy priority set to urgent automatically on backup or verify errors

### v1.0.6
- Added backup verification (gzip integrity, dump completion marker, size trend)
- Added `SIZE_DROP_WARN` env var (default: 20%)
- Email report now has separate Backup and Verify columns
- Email subject now reflects verify outcome
- Log files are now daily (`backup_YYYYMMDD.log`) stored in `/backups/log/`
- Log retention now follows `RETENTION_DAYS`

### v1.0.5
- Added `backup_networks` parameter to connect container to multiple Docker networks
- Improved network deduplication logic in Komodo Action

---

## Related Projects

| Project | Description |
|---------|-------------|
| [DABS](https://github.com/kayaman78/dabs) | Docker automated backup for SQLite |
| [DABV](https://github.com/kayaman78/dabv) | Docker automated backup for volumes |
| [KCR](https://github.com/kayaman78/kcr) | Komodo Action to run shell commands on remote servers |

---

## License

MIT License - feel free to use, modify, and distribute.

## Support

For issues or questions, open an issue on GitHub.