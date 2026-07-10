# KDD — Komodo Database Dumper

**Version**: 3.0.0 | **Requires**: Komodo v2 | **License**: MIT

[![Docker](https://img.shields.io/badge/docker-required-blue.svg)](https://www.docker.com/)
[![Komodo](https://img.shields.io/badge/komodo-action-blue.svg)](https://github.com/mbecker20/komodo)

Universal database backup for Docker environments, designed for [Komodo](https://github.com/mbecker20/komodo) orchestration.

> Part of the **KDD ecosystem** — see also [DABS](https://github.com/kayaman78/dabs) for SQLite, [DABV](https://github.com/kayaman78/dabv) for Docker volumes, and [KCR](https://github.com/kayaman78/kcr) to run shell-based tools from Komodo.

---

## Features

- **Multi-database**: MySQL/MariaDB, PostgreSQL 12–18, MongoDB 4.x–8.x
- **Auto-discovery**: setup wizard scans running containers
- **Safe hot backups**: transaction-safe methods, no downtime
- **3-step verification**: gzip integrity, completion marker, size trend
- **N-most-recent retention**: keeps last N dumps per database (not calendar-based)
- **Notifications**: email (HTML), Telegram, ntfy — independent channels
- **Multi-network**: connects to multiple Docker networks per run
- **PUID/PGID**: correct file permissions via user mapping

---

## Quick Start

### 1. Setup config

```bash
mkdir -p /dockerpath/kdd/{config,dump}
docker pull ghcr.io/kayaman78/kdd:3
docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v $(pwd)/config:/config \
  ghcr.io/kayaman78/kdd:3 /app/setup.sh
```

See [SETUP.md](docker/SETUP.md) for details.

### 2. Create the Action in Komodo

Create a new Action in Komodo, paste the content of [`dump-action-template.ts`](komodo/dump-action-template.ts) into the Script field, and fill the Args JSON with your values. See [Parameters](#parameters) for reference.

### 3. Schedule

Use an Action Schedule or a Komodo Procedure for sequential multi-tool backups.

---

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `server_name` | Komodo server name | required |
| `runner_network` | Primary Docker network | required |
| `backup_networks` | Extra networks (array or comma-separated) | `[]` |
| `config_path` | Host path to KDD config dir | required |
| `dump_path` | Host path to backup output dir | required |
| `image` | KDD Docker image | `ghcr.io/kayaman78/kdd:3` |
| `retention_days` | Dumps to keep per database | `7` |
| `timeout_seconds` | Max seconds for backup | `3600` |
| `timezone` | Container timezone | `Europe/Rome` |
| `server_display_name` | Name in notifications | `KDD` |
| `job_name` | Email header name | `Backup Report` |
| `dry_run` | `"true"` = scan only, no writes | `"false"` |
| `smtp.*` | SMTP settings (enabled, host, port, user, pass, from, to, tls) | — |
| `telegram.*` | Telegram settings (enabled, token, chat_id) | — |
| `ntfy.*` | ntfy settings (enabled, url, topic) | — |
| `notify.attach_log` | Attach log to push notifications | `"false"` |

---

## How It Works

1. **Setup**: `setup.sh` scans containers → generates `config.yaml`
2. **Action pipeline**: pull image → start container → connect networks → run `backup.sh`
3. **Backup**: compressed dumps per database type
4. **Verify**: gzip integrity + completion marker + size trend
5. **Rotate**: keep N most recent dumps and logs
6. **Notify**: email, Telegram, ntfy (independent)

### Dump errors

Stderr from `mysqldump`, `pg_dump`, and `mongodump` is captured and logged on failure. No errors are hidden.

### Verification

| Check | MySQL/MariaDB | PostgreSQL | MongoDB |
|-------|---------------|------------|---------|
| gzip integrity | ✅ | ✅ | ✅ |
| Completion marker | "Dump completed" | "PostgreSQL database dump complete" | N/A (atomic) |
| Size trend | ✅ | ✅ | ✅ |

### Multi-network

```
Stack A (bridge-01): MySQL, PostgreSQL
Stack B (bridge-02): MongoDB
→ KDD starts on bridge-01, then docker network connect bridge-02
```

---

## Updating

**Script and Args are separate in Komodo.** Updating the script never touches your parameters.

1. Open your KDD Action in Komodo
2. Paste the new [`dump-action-template.ts`](komodo/dump-action-template.ts) into the Script field
3. Save

If `backup.sh` changed, rebuild the image or pull the new tag.

---

## Ecosystem

| Project | What it backs up |
|---------|-----------------|
| **KDD** | MySQL, PostgreSQL, MongoDB |
| [DABS](https://github.com/kayaman78/dabs) | SQLite |
| [DABV](https://github.com/kayaman78/dabv) | Docker volumes |
| [KCR](https://github.com/kayaman78/kcr) | Runs DABS/DABV from Komodo |

Recommended: chain all four in a **Komodo Procedure** for complete coverage.

---

## Building

```bash
docker build -t ghcr.io/kayaman78/kdd:3 ./docker/
```

Pre-built: `ghcr.io/kayaman78/kdd:3` and `:latest`

---

## Changelog

### v3.0.0
- **Rewrite**: action now uses sequential single-command pipeline (same pattern as KCR). Fixes permanent hang caused by multi-line bash blocks — SDK `execute_server_terminal` never resolves the promise for multi-line commands.
- **Error logging**: dump stderr is captured and logged on failure instead of being discarded with `2>/dev/null`.
- Pipeline: cleanup residual → pull → run → network connect → exec backup.sh.
- Cleanup: `execSafe()` with `Promise.race` (15s cap) for container removal, `deleteTerminalSafe()` for terminal.
- Removed TOML template — TS source is SoT.

### v2.0.2
- Fixed `DeleteTerminal` params (was passing flat object, correct is `TerminalTarget`).
- Removed `execute_server_terminal("exit 0")` from finally — causes permanent hang.
- Image: pg-client 18, yq 4.53.3, mongodump 100.17.0.

### v2.0.1
- Retention changed from calendar-based to N-most-recent.
- Fixed action cleanup hang in finally block.

### v2.0.0
- Komodo v2 migration. `execute_server_terminal` with inline `init`.

### v1.0.5–v1.2.0
- Multi-network, verification, notifications (email/Telegram/ntfy), dry-run, TLS fix, timeout, retention fix.

---

## License

MIT
