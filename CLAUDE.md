# KDD — Komodo Database Dumper

## Struttura
```
kdd/
├── docker/
│   ├── Dockerfile              # Debian 12 slim + DB clients + tools
│   ├── entrypoint.sh           # PUID/PGID + Docker socket GID
│   ├── setup.sh                # Wizard → genera config.yaml
│   ├── backup.sh               # Backup + verify + notify
│   └── SETUP.md                # Guida setup
├── komodo/
│   ├── dump-action-template.ts # Action Komodo (SoT)
│   └── arguments-template.json # Parametri esempio
└── README.md
```

## Stack
- Debian 12 slim, `default-mysql-client`, `postgresql-client-18`, `mongodump` 100.17.0
- `docker-ce-cli`, `yq` 4.53.3, `jq`, `msmtp`, `curl`, `gzip`
- Image: `ghcr.io/kayaman78/kdd:3` (tag 3.1.0, anche `:latest`)

## Action — pipeline sequenziale (v3.0.0)

Comandi singoli one-line nello stesso terminale persistente — pattern KCR.

1. `docker rm -f kdd-backup-runner` — cleanup residuo
2. `docker pull <image>`
3. `docker run -d ...` — container con `sleep infinity` + env vars
4. `docker network connect <net>` — per ogni rete extra
5. `docker exec <container> /app/backup.sh`

Cleanup finally: `execSafe()` (Promise.race 15s) rimuove container, `deleteTerminalSafe()` rimuove terminale.

## 3 regole terminale

1. **Mai multi-riga** — SDK Komodo non risolve la promise. `buildDockerRun()` + `buildEnvFlags()` costruiscono il `docker run` come array joinato.
2. **Mai `execute_server_terminal("exit")`** — uccide la shell, stream HTTP non chiude, promise pending.
3. **`execSafe()` per cleanup in finally** — Promise.race con timeout, mai hang.

## Backup

- MySQL/MariaDB: `mysqldump --single-transaction --routines --triggers --events | gzip`
- PostgreSQL: `pg_dump --clean --if-exists | gzip`
- MongoDB: `mongodump --archive --gzip`
- Stderr catturato su file temp — loggato riga per riga su failure, scartato su success
- `--skip-ssl-verify-server-cert` su mysqldump — accetta certificati self-signed (MariaDB 11.8 verifica TLS di default)

## Verify 3-step
1. `gzip -t` integrità
2. Completion marker (MySQL: "Dump completed", PG: "PostgreSQL database dump complete", Mongo: skip)
3. Size drop vs backup precedente (warn se > `SIZE_DROP_WARN`%)

## Retention
N-most-recent: mantieni gli ultimi `RETENTION_DAYS` dump per DB. Non calendar-based. Stessa policy per log.

## Single-instance-per-server
`containerName` e `terminalName` hardcoded. Una action per server, non parallele. Primo step pipeline pulisce residui.

## Notifiche
Email HTML, Telegram, ntfy — indipendenti. `notify.attach_log` allega il log.

## PUID/PGID
`entrypoint.sh`: crea user/group, rileva Docker socket GID, `setpriv` per esecuzione.
