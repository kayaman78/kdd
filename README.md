**Project Status**: Active development | **Latest Version**: 1.0.0 | **Maintained**: Yes

# KDD - Komodo Database Dumper

Universal database backup solution for Docker environments, designed to work seamlessly with [Komodo](https://github.com/mbecker20/komodo) orchestration.

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

## Prerequisites

- Docker installed on host machine
- Running Docker containers with databases
- Access to `/var/run/docker.sock`
- Basic knowledge of Docker commands
- Komodo

## Quick Start

### 1. Setup Configuration

Run the setup script on your server to auto-discover databases
Use ssh or komodo shell on target server
Adjust the path of the docker stacks

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

Create a new Action in Komodo with this code or better with [action template](komodo/dump-action-template.ts):

```typescript
/**
 * Action: KDD Backup Runner
 * Orchestrates database backups via Docker
 */
async function runBackup() {
    // @ts-ignore
    const config = ARGS;
    if (!config || !config.server_name) {
        throw new Error("Error: 'ARGS' parameters not found");
    }
    console.log(`🚀 Starting KDD Backup on server: ${config.server_name}`);
    const terminalName = `kdd-backup-temp`;
    
    const dockerCommand = `docker run --rm \\
        --pull always \\
        --name kdd-backup-runner-$(date +%s) \\
        --network ${config.network} \\
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
        ${config.image} \\
        /app/backup.sh --network-filter ${config.network}`;
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

Add this JSON to your Action's configuration field or use [arguments template](komodo/arguments-template.json):

```json
{
  "server_name": "your-server",
  "network": "your-docker-network",
  "config_path": "/srv/docker/kdd/config",
  "dump_path": "/srv/docker/kdd/dump",
  "retention_days": "7",
  "timezone": "Europe/Rome",
  "server_display_name": "Production Server",
  "job_name": "Database Backup",
  "image": "ghcr.io/kayaman78/kdd:latest",
  "smtp": {
    "enabled": "true",
    "host": "smtp.gmail.com",
    "port": "587",
    "user": "backup@example.com",
    "pass": "your-app-password",
    "from": "backup@example.com",
    "to": "admin@example.com",
    "tls": "auto"
  }
}
```

### 4. Schedule Backups

Configure Action Schedule (e.g., daily at 2 AM) or use a Komodo Procedure for multiple sequential backups

## Architecture

**Network-based separation**: KDD uses Docker networks to organize backups. Create one Action per Docker network you want to backup. This allows:
- Independent backup schedules per network (prod daily, test weekly)
- Separate email notifications per environment
- Network isolation for security

**Example setup**:
- Action 1: `network: "production"` → backs up all prod databases
- Action 2: `network: "staging"` → backs up all staging databases
- Action 3: `network: "services"` → backs up auxiliary services

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



## How It Works

1. **Setup**: `setup.sh` scans Docker containers and generates `config.yaml`
2. **Execution**: Komodo Action triggers `backup.sh` with network filter
3. **Backup**: Creates compressed dumps of all databases on specified network
4. **Rotation**: Removes backups older than retention period
5. **Notification**: Sends HTML email report with results

## Email Reports

KDD sends professional HTML email reports with:
- Color-coded status (green/yellow/red)
- Per-database backup status and size
- Customizable server name in subject
- Customizable job name in header
- Total disk usage footer

## Requirements

- Docker installed on target server
- Komodo instance with server connection
- Running database containers with standard environment variables

## Building

Pre-built images are available at `ghcr.io/kayaman78/kdd:latest`

To build locally:

```bash
docker build -t kdd:latest .
```

## License

MIT License - feel free to use, modify, and distribute.

## Support

For issues or questions, open an issue on GitHub.

---