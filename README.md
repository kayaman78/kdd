# KDD — Komodo Database Dumper

**Project Status**: Active development | **Latest Version**: 2.0.0 | **Maintained**: Yes | **Requires**: Komodo v2

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)
[![Komodo](https://img.shields.io/badge/komodo-action-blue.svg)](https://github.com/mbecker20/komodo)

Universal database backup solution for Docker environments, designed to work seamlessly with [Komodo](https://github.com/mbecker20/komodo) orchestration.

> Part of the **KDD ecosystem** — see also [DABS](https://github.com/kayaman78/dabs) for SQLite, [DABV](https://github.com/kayaman78/dabv) for Docker volumes, and [KCR](https://github.com/kayaman78/kcr) to run shell-based backup tools from a Komodo Action.

---

## Features

- **Automatic Discovery**: Scans running Docker containers and detects databases automatically
- **Multi-Database Support**: MySQL/MariaDB (all versions), PostgreSQL 12-17, MongoDB 4.x-8.x
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
4. One schedule, one place to monitor, separate email reports per job

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

docker pull ghcr.io/kayaman78/kdd:latest && \
docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v $(pwd)/config:/config \
  ghcr.io/kayaman78/kdd:latest /app/setup.sh
```

See [SETUP.md](docker/SETUP.md) for detailed setup instructions.

### 2. Import the Action Template

In Komodo go to **Resource Sync → New Resource Sync**, paste the content of [kdd-action-template.toml](komodo/kdd-action-template.toml), and execute the sync. The Action template is created automatically with the TypeScript code and default parameters already in place.

Open the imported Action, go to the **Args** field, and fill in your values (server, paths, networks, notifications). See [Configuration Parameters](#configuration-parameters) for the full reference.

### 3. Schedule Backups

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
| `runner_network` | Primary Docker network to start the KDD container on | required |
| `backup_networks` | All networks to connect to — array or comma-separated string; must include `runner_network` | `[]` |
| `config_path` | Host path to the KDD config directory | required |
| `dump_path` | Host path to the backup output directory | required |
| `image` | KDD Docker image to use | `ghcr.io/kayaman78/kdd:latest` |
| `retention_days` | Days to keep backups | `7` |
| `timeout_seconds` | Max seconds to wait for the backup before raising a timeout error | `3600` |
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
| `dry_run` | `"true"` = scan without writing any backups or touching files | `"false"` |

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
docker build -t kdd:latest ./docker/
```

---

## Updating

In Komodo, the **Script** field (TypeScript code) and the **Args** field (your JSON configuration) are stored separately. Updating KDD never touches your parameters — networks, paths, SMTP, Telegram, ntfy are all safe.

### Update the Action Script

**1. Open the Action in Komodo**

Go to Actions → select your KDD Action.

**2. Replace the Script field only**

Paste the new content of [`dump-action-template.ts`](komodo/dump-action-template.ts) into the Script field. Your Args JSON is in a separate field and is untouched.

**3. Save**

Done. No server changes, no re-entering parameters.

---

### Multiple servers

If you have one KDD Action per server (the standard setup), repeat the Script paste for each one. Since the code is identical across all actions and only the Args differ, this is a straightforward copy-paste for each action.

> **Tip**: Update and test one action first. Once confirmed working, copy the Script field content into all remaining actions — parameters stay exactly as you configured them.

---

### Update the KDD image

If `backup.sh` changed (visible in the [Changelog](#changelog)), you need a new image. Pull it on the server or let the Action do it automatically — the `docker pull` at the start of each run always fetches the latest tag if you use `ghcr.io/kayaman78/kdd:latest`.

No manual image update is needed if you use the `:latest` tag.

---

### Check what changed before updating

The [Changelog](#changelog) documents every change per version. If a release only touches the Komodo Action TypeScript, you only need to update the Script field. If it also touches `backup.sh`, the image rebuild handles that automatically on the next pull.

---

## Changelog

### v2.0.0 — Komodo v2 migration (breaking)
- **Requires Komodo v2.** Migrated from `komodo.execute_terminal` (v1) to `komodo.execute_server_terminal` (v2 unified API).
- Terminal initialization is now inline: `init: { command: "bash", recreate: Always }` is passed alongside the docker command in a single call, replacing the previous separate `CreateTerminal` step.
- Cleanup pattern preserved: `execute_server_terminal("exit 0")` → 500ms grace period → `DeleteTerminal`. The cleanup call deliberately omits `init` — the terminal already exists from the run above and we don't want to spawn a new shell just to delete it.
- Documented KDD's **single-instance-per-server design constraint**: both `containerName` and `terminalName` are hardcoded; concurrent KDD actions on the same server are not supported (would collide on the Docker container `--name` first). Defensive recreate (`recreate: Always` + `docker rm -f` in `trap EXIT`) handles residuals from previously killed/timed-out runs. If multi-action concurrency is needed in the future, both names must be made unique per-action (e.g. suffix with `runner_network`).
- No changes to user-facing parameters: `server_name`, `runner_network`, `backup_networks`, `config_path`, `dump_path`, retention, timezone, SMTP/Telegram/ntfy/notify configs all work exactly as before.
- No changes to the KDD container image (`backup.sh`, `setup.sh`, `entrypoint.sh`, `Dockerfile` untouched).

### v1.2.0
- Added `dry_run` parameter — set `"true"` to scan all configured databases and report what would be backed up without writing any files or touching retention; email subject shows `[🔍 DRY-RUN]`, push notifications include a dry-run summary, log shows a retention preview of what would be removed
- Dry-run shows per-database rows in the HTML report with a 🔍 indicator and "skipped" verify status
- Dry-run does not modify any files: no archives written, no retention deletions, no log cleanup

### v1.1.0
- Fixed backup verification double-output bug — `_check_size_drop` was writing to stdout directly while callers also wrote their own message, producing two lines in `verify_result` and garbled HTML report entries; callers now capture `_check_size_drop` output via `$()` and relay it cleanly
- Fixed `rotate_backups` retention off-by-one — was using `-mtime +RETENTION_DAYS` (keeps one extra day) instead of `-mtime +"$((RETENTION_DAYS - 1))"`, now consistent with DABS and DABV
- Fixed `configure_msmtp` TLS configuration — `tls_starttls` was always set to `on`, breaking port 465 (SMTPS/immediate SSL); it is now derived from the port: `465` → `off`, all others → `on`
- Added `timeout_seconds` parameter to the Komodo Action — prevents the action from hanging indefinitely if a backup stalls; default is 3600 seconds
- All environment variable values in the Komodo Action `docker run` command are now single-quoted — prevents breakage when values contain spaces or special characters
- Removed dead `size_result` variable in `verify_mysql_backup`

### v1.0.9
- Removed `--interactive` flag from `setup.sh` — interactive mode is now the only mode
- Simplified `ask_confirm()` function, removed `INTERACTIVE` variable and related logic
- Updated `SETUP.md` and `README.md` accordingly

### v1.0.8
- Added emoji icons to all log output in `backup.sh` for improved readability in Komodo logs

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