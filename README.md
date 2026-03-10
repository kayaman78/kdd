# KDD — Komodo Database Dumper

**Project Status**: Active development | **Latest Version**: 1.0.6 | **Maintained**: Yes

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)
[![Komodo](https://img.shields.io/badge/komodo-action-blue.svg)](https://github.com/mbecker20/komodo)

Universal database backup solution for Docker environments, designed to work seamlessly with [Komodo](https://github.com/mbecker20/komodo) orchestration.

> Part of the **KDD ecosystem** — see also [DABS](https://github.com/kayaman78/dabs) for SQLite backups and [KCR](https://github.com/kayaman78/kcr) to run shell-based backup tools from a Komodo Action.

---

## Features

- **Automatic Discovery**: Scans running Docker containers and detects databases automatically
- **Multi-Database Support**: MySQL/MariaDB (all versions), PostgreSQL 12-17, MongoDB 4.x-8.x, Redis
- **Safe Hot Backups**: Uses transaction-safe methods for consistent backups without downtime
- **Automatic Rotation**: Configurable retention policy (default: 7 days)
- **Backup Verification**: Every backup is verified immediately after creation (gzip integrity, dump completion marker, size trend)
- **Email Notifications**: Optional HTML email reports with color-coded status per database, separate Backup and Verify columns
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

### ⚙️ [KCR — Komodo Command Runner](https://github.com/kayaman78/kcr)

KCR is a Komodo Action template that lets you run arbitrary shell commands on your servers directly from Komodo — including DABS. No extra containers, no mounts. Just drop the Action in Komodo, point it at your script, and you're done.

### Running everything together

The recommended setup is a **Komodo Procedure** that chains KDD and DABS sequentially:

1. KDD Action → backs up MySQL, PostgreSQL, MongoDB
2. KCR Action running DABS → backs up all SQLite databases on the same host
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

Create a new Action in Komodo with this code or better with always updated [action template](komodo/dump-action-template.ts):

```typescript
/**
 * Action: KDD Backup Runner
 * Description: Orchestrates automated Docker backups for databases (MySQL, PostgreSQL/PostGIS, MongoDB)
 * using the KDD (Komodo Docker Dump) image. Connects the backup container to all required
 * networks so it can reach databases across different Docker stacks on the same server.
 *
 * ARGS JSON fields:
 *   server_name          - Komodo server name
 *   runner_network       - Primary Docker network to start the KDD container on
 *   backup_networks      - All networks to connect to: array ["net1","net2"] or string "net1,net2"
 *                          Must include runner_network. Omit to skip extra connects.
 *   config_path          - Host path to the KDD config directory
 *   dump_path            - Host path to the backup output directory
 *   retention_days       - Days to keep backups (default: 7)
 *   timezone             - Container timezone (e.g. "Europe/Rome")
 *   server_display_name  - Label shown in email subject
 *   job_name             - Label shown in email header
 *   image                - KDD image to use (e.g. "ghcr.io/kayaman78/kdd:latest")
 *   smtp.enabled         - "true" | "false"
 *   smtp.host            - SMTP server address
 *   smtp.port            - SMTP port
 *   smtp.user            - SMTP username (leave empty for unauthenticated)
 *   smtp.pass            - SMTP password
 *   smtp.from            - Sender address
 *   smtp.to              - Recipient address(es), comma-separated
 *   smtp.tls             - "auto" | "on" | "off"
 */
async function runBackup() {
    // @ts-ignore — ARGS is injected as a local constant by Komodo at runtime
    const config = ARGS;

    if (!config || !config.server_name) {
        throw new Error("Error: 'ARGS' parameters not found. Check your JSON field.");
    }

    console.log(`🚀 Starting KDD Backup on server: ${config.server_name}`);

    const allNetworks: string[] = config.backup_networks
        ? (Array.isArray(config.backup_networks)
            ? config.backup_networks
            : String(config.backup_networks).split(",").map((n: string) => n.trim())
          ).filter((n: string) => n.length > 0)
        : [];

    const extraNetworks = allNetworks.filter((n: string) => n !== config.runner_network);

    console.log(`🌐 Runner network : ${config.runner_network}`);
    console.log(`🌐 Extra networks : ${extraNetworks.length > 0 ? extraNetworks.join(", ") : "none"}`);

    const containerName = `kdd-backup-runner`;
    const terminalName  = `kdd-backup-temp`;

    const networkConnectCmds = extraNetworks.length > 0
        ? extraNetworks.map((n: string) => `docker network connect ${n} ${containerName}`).join(" && \\\n")
        : "echo '  No extra networks to connect'";

    const dockerCommand = `
set -e

trap 'echo "[KDD] Removing container..."; docker rm -f ${containerName} 2>/dev/null || true' EXIT

echo "[KDD] Pulling ${config.image}..."
docker pull ${config.image}

echo "[KDD] Starting container on network: ${config.runner_network}"
docker run -d \\
  --name ${containerName} \\
  --network ${config.runner_network} \\
  -v /var/run/docker.sock:/var/run/docker.sock:ro \\
  -v ${config.config_path}:/config:ro \\
  -v ${config.dump_path}:/backups \\
  -e RETENTION_DAYS=${config.retention_days} \\
  -e TZ=${config.timezone} \\
  -e ENABLE_EMAIL=${config.smtp.enabled} \\
  -e SMTP_HOST=${config.smtp.host} \\
  -e SMTP_PORT=${config.smtp.port} \\
  -e SMTP_USER=${config.smtp.user} \\
  -e SMTP_PASS='${config.smtp.pass}' \\
  -e SMTP_FROM=${config.smtp.from} \\
  -e SMTP_TO=${config.smtp.to} \\
  -e SMTP_TLS=${config.smtp.tls} \\
  -e SERVER_NAME='${config.server_display_name}' \\
  -e JOB_NAME='${config.job_name}' \\
  --entrypoint sleep ${config.image} infinity

echo "[KDD] Connecting extra networks..."
${networkConnectCmds}

echo "[KDD] Running backup..."
docker exec ${containerName} /app/backup.sh
`.trim();

    let exitCode: string | null = null;
    let executionFinished = false;

    try {
        await komodo.write("CreateTerminal", {
            server: config.server_name,
            name: terminalName,
            command: "bash",
            recreate: Types.TerminalRecreateMode.Always,
        });
        console.log("✅ Terminal created.");

        await komodo.execute_terminal(
            {
                server: config.server_name,
                terminal: terminalName,
                command: dockerCommand,
            },
            {
                onLine: (line: string) => console.log(`[KDD] ${line}`),
                onFinish: (code: string) => {
                    exitCode = code;
                    executionFinished = true;
                },
            }
        );

        while (!executionFinished) {
            await new Promise(r => setTimeout(r, 500));
        }

        if (exitCode === "0") {
            console.log("✅ BACKUP COMPLETED SUCCESSFULLY!");
        } else {
            throw new Error(`Backup failed with exit code: ${exitCode}`);
        }

    } catch (err: any) {
        console.error(`❌ CRITICAL ERROR: ${err.message}`);
        throw err;

    } finally {
        console.log("🧹 Cleaning up terminal resources...");
        try {
            await komodo.execute_terminal(
                {
                    server: config.server_name,
                    terminal: terminalName,
                    command: "exit 0",
                },
                { onLine: () => {}, onFinish: () => {} }
            );

            await new Promise(resolve => setTimeout(resolve, 500));

            await komodo.write("DeleteTerminal", {
                server: config.server_name,
                name: terminalName,
                terminal: terminalName
            } as any);

            console.log("✅ Terminal resource removed.");
        } catch (e) {
            console.log("⚠️ Cleanup: Terminal already closed.");
        }
    }
}

await runBackup();
```

### 3. Configure Action Parameters

Add this JSON to your Action's configuration field or use always updated [arguments template](komodo/arguments-template.json):

```json
{
  "server_name": "prod-server-01",
  "runner_network": "bridge-01",
  "backup_networks": [
    "bridge-01",
    "bridge-02",
    "bridge-03"
  ],
  "config_path": "/data/stacks/production/kdd/config",
  "dump_path": "/data/stacks/production/kdd/dump",
  "retention_days": "14",
  "timezone": "Europe/Rome",
  "server_display_name": "Server principale",
  "job_name": "Backup stack 01",
  "image": "ghcr.io/kayaman78/kdd:latest",
  "smtp": {
    "enabled": "true",
    "host": "smtp.gmail.com",
    "port": "587",
    "user": "backup@mycompany.com",
    "pass": "your-app-password",
    "from": "backup@mycompany.com",
    "to": "admin@mycompany.com,ops@mycompany.com",
    "tls": "auto"
  }
}
```

### 4. Schedule Backups

Configure an Action Schedule (e.g., daily at 2 AM) or use a Komodo Procedure for multiple sequential backups.

---

## Architecture

**Network-based separation**: KDD uses Docker networks to organize backups. Create one Action per Docker network you want to backup. This allows:

- Independent backup schedules per network (prod daily, test weekly)
- Separate email notifications per environment
- Network isolation for security

**Example setup**:

- Action 1: `network: "production"` → backs up all prod databases
- Action 2: `network: "staging"` → backs up all staging databases
- Action 3: `network: "services"` → backs up auxiliary services

---

## Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `server_name` | Komodo server name | required |
| `network` | Docker network to backup | required |
| `config_path` | Path to config.yaml | required |
| `dump_path` | Backup storage directory | required |
| `retention_days` | Days to keep backups | `7` |
| `timezone` | Container timezone | `Europe/Rome` |
| `server_display_name` | Name in email subject | `KDD` |
| `job_name` | Name in email header | `Backup Report` |
| `smtp.enabled` | Enable email reports | `false` |
| `smtp.host` | SMTP server | - |
| `smtp.port` | SMTP port | `587` |
| `smtp.user` | SMTP username | - |
| `smtp.pass` | SMTP password | - |
| `smtp.from` | From email address | - |
| `smtp.to` | To email (comma-separated) | - |
| `smtp.tls` | TLS mode: auto/on/off | `auto` |

---

## How It Works

1. **Setup**: `setup.sh` scans Docker containers and generates `config.yaml`
2. **Execution**: Komodo Action triggers `backup.sh` with network filter
3. **Backup**: Creates compressed dumps of all databases on specified network
4. **Rotation**: Removes backups older than retention period
5. **Notification**: Sends HTML email report with results

---

## Email Reports

KDD sends professional HTML email reports with:

- Color-coded status (green/yellow/red)
- Per-database backup status and size
- Customizable server name in subject
- Customizable job name in header
- Total disk usage footer

---

## Building

Pre-built images are available at `ghcr.io/kayaman78/kdd:latest`

To build locally:

```bash
docker build -t kdd:latest .
```

---

## How Verification Works

After each backup is created, KDD runs three checks in sequence. A backup must pass all three to be marked ✅ OK.

**1. gzip integrity**
Runs `gzip -t` on the `.gz` file. Catches truncated or corrupt archives caused by write errors, disk issues, or interrupted dumps.

**2. Dump completion marker**
Reads the last 5 lines of the compressed dump via `zcat | tail -5` — no full decompression needed. Checks for the marker that the dump tool always writes as the final line when it completes successfully:

- MySQL/MariaDB → `Dump completed`
- PostgreSQL → `PostgreSQL database dump complete`
- MongoDB → marker not applicable; mongodump writes atomically, so gzip integrity + non-empty file is sufficient

If the marker is missing, the dump was interrupted mid-write and the backup is incomplete.

**3. Size trend**
Compares the size of the new backup against the most recent previous backup for the same database. If the new file is smaller by more than `SIZE_DROP_WARN`% (default: 20%), the verify is marked ⚠️ WARN with the old and new sizes shown. This catches silent data loss — for example a service that wiped its tables or a misconfiguration that truncated data before the backup ran.

### Verify vs Backup status in the email

The email report has two separate columns per database row:

| Backup | Verify | Meaning |
|--------|--------|---------|
| ✅ success | ✅ OK | Backup written and verified clean |
| ✅ success | ⚠️ WARN | Backup valid but size dropped unexpectedly — investigate |
| ✅ success | ❌ FAIL | Backup written but corrupt or incomplete — do not rely on it |
| ❌ failed | — skipped | Backup failed, verify not attempted |

A WARN does not block the process — the backup is kept and the service continues. A FAIL is reflected in the email subject line.

---

## Log Structure

Logs are stored in a dedicated subdirectory with one file per day, rotated automatically using the same `RETENTION_DAYS` policy as backups.

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

## Changelog

### v1.0.6
- Added backup verification (gzip integrity, dump completion marker, size trend)
- Added `SIZE_DROP_WARN` env var (default: 20%)
- Email report now has separate Backup and Verify columns
- Email subject now reflects verify outcome (✅ SUCCESS / ⚠️ WARN / ⚠️ PARTIAL / ❌ FAILED)
- Log files are now daily (`backup_YYYYMMDD.log`) stored in `/backups/log/`
- Log retention now follows `RETENTION_DAYS` — old log files are deleted automatically

### v1.0.5
- Added `backup_networks` parameter to connect container to multiple Docker networks
- Improved network deduplication logic in Komodo Action

---

## Related Projects

| Project | Description |
|---------|-------------|
| [DABS](https://github.com/kayaman78/dabs) | Docker automated backup for SQLite |
| [KCR](https://github.com/kayaman78/kcr) | Komodo Action to run shell commands on remote servers |

---

## License

MIT License - feel free to use, modify, and distribute.

## Support

For issues or questions, open an issue on GitHub.