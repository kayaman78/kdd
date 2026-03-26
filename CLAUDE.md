# KDD — Komodo Database Dumper

## Scopo
Container Docker Debian-based che backuppa database MySQL/MariaDB, PostgreSQL e MongoDB via Komodo Actions. Auto-discover tramite wizard, hot backup, verifica integrità, retention, notifiche.

## Struttura file
```
kdd/
├── docker/
│   ├── Dockerfile              # Debian 12 slim + DB clients + tools
│   ├── entrypoint.sh           # PUID/PGID handler + Docker socket GID
│   ├── setup.sh                # Wizard interattivo → genera config.yaml
│   ├── backup.sh               # Script backup principale
│   └── SETUP.md                # Guida setup dettagliata
├── komodo/
│   ├── dump-action-template.ts  # Action TypeScript per Komodo (source)
│   ├── arguments-template.json  # Parametri esempio per la Action
│   └── kdd-action-template.toml # Export Komodo Resource Sync — importa direttamente in Komodo
└── README.md
```

## Stack
- **Base image:** `debian:12-slim`
- **DB clients:** `mysql-client`, `postgresql-client-17`, `mongodump` v100.14.0
- **Tools:** `docker-ce-cli`, `yq` v4.40.5, `jq`, `msmtp`, `curl`, `gzip`
- **Image pubblicata:** `ghcr.io/kayaman78/kdd:latest`

## Flusso Komodo Action
1. Action TypeScript avvia `docker pull` + `docker run -d --entrypoint sleep infinity`
2. Connette il container a tutti i `backup_networks` via `docker network connect`
3. `docker exec` esegue `backup.sh` nel container
4. `trap EXIT` nel bash script rimuove il container al termine
5. Cleanup terminal nel `finally` block: `exit 0` → 500ms → `DeleteTerminal`

## Terminal lifecycle KDD — CRITICO
Il `finally` block usa `execute_terminal("exit 0")` + attesa 500ms + `DeleteTerminal`.
**Non modificare questa sequenza** — è il meccanismo che garantisce la chiusura del terminal Komodo.

## Setup wizard
```bash
docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v $(pwd)/config:/config \
  ghcr.io/kayaman78/kdd:latest /app/setup.sh
```
1. Scansiona container running, rileva image type (mysql/postgres/mongo)
2. Risolve credenziali: env vars dirette → fallback su `.env` nel compose dir
3. Prompt interattivo per ogni database trovato
4. Genera `config.yaml` con `yq`

## config.yaml generata
```yaml
mysql:
  - name: nextcloud
    host: nextcloud_db_1
    port: 3306
    dbname: nextcloud
    user: root
    password: secret123
    network: mynetwork

postgres:
  - name: gitea
    host: gitea_db_1
    port: 5432
    dbname: gitea
    user: gitea
    password: giteapass
    network: mynetwork

mongo:
  - name: my_mongo
    host: mongo-1
    port: 27017
    dbname: my_mongo
    user: admin
    password: pass
    authdb: admin
    network: docker_default
```

## Metodi dump
- **MySQL/MariaDB:** `mysqldump --single-transaction --routines --triggers --events <db> | gzip`
- **PostgreSQL:** `pg_dump --clean --if-exists | gzip` (single database)
- **MongoDB:** `mongodump --archive --gzip` (scrittura atomica, no marker check)

## Verifica 3-step
Il risultato di ogni verify è **sempre una singola riga** nel formato `OK` / `WARN:messaggio` / `FAIL:motivo`.

1. `gzip -t` — integrità archivio
2. Marker di completamento negli ultimi 5 righe (MySQL: "Dump completed", PG: "PostgreSQL database dump complete") — MongoDB: skip (scrittura atomica)
3. `_check_size_drop`: confronto size vs backup precedente — output catturato via `$()` e relay al caller, nessun double-echo

## Retention
`rotate_backups()` usa `-mtime +"$((RETENTION_DAYS - 1))"` — coerente con DABS e DABV (conserva esattamente RETENTION_DAYS giorni).

## configure_msmtp — TLS
```
tls_starttls derivato da porta:
  465  → starttls off  (SMTPS, SSL immediato)
  587  → starttls on   (STARTTLS)
  off  → starttls off  (no TLS)
```

## Parametri Action (arguments-template.json)
```json
{
  "server_name": "prod-server-01",
  "runner_network": "bridge-01",
  "backup_networks": ["bridge-01", "bridge-02"],
  "config_path": "/data/stacks/production/kdd/config",
  "dump_path": "/data/stacks/production/kdd/dump",
  "retention_days": "14",
  "timeout_seconds": 3600,
  "timezone": "Europe/Rome",
  "image": "ghcr.io/kayaman78/kdd:latest",
  "smtp": { "enabled": "false", "host": "...", "port": "587", "tls": "auto", ... },
  "telegram": { "enabled": "false", ... },
  "ntfy": { "enabled": "false", ... },
  "notify": { "attach_log": "false" }
}
```

Tutti i valori `-e VAR=value` nel `docker run` sono single-quoted nel template TS per proteggere da spazi e caratteri speciali.

## Multi-network support
`backup_networks` permette al container KDD di connettersi a reti di compose stack diversi:
```
Stack A (bridge-01): MySQL, PostgreSQL
Stack B (bridge-02): MongoDB
→ KDD si avvia su bridge-01, poi docker network connect bridge-02
```

## entrypoint.sh — PUID/PGID
- `PUID` / `PGID` env vars (default 1000:1000) — se entrambi 0, esegue direttamente come root
- Crea user/group se non esistono
- Rileva GID del Docker socket e aggiunge user al gruppo
- Usa `setpriv --reuid --regid --init-groups` per eseguire come user specificato
- Fix ownership su `/config` e `/backups`

## Output struttura
```
dump_path/
├── <db-name>/
│   └── dump-YYYY-MM-DD_HH-MM.sql.gz    # MySQL/PG
│   └── dump-YYYY-MM-DD_HH-MM.archive.gz # MongoDB
└── log/
    └── backup_YYYYMMDD.log
```

## Coerenza con l'ecosistema
- Retention: `-mtime +"$((RETENTION_DAYS - 1))"` — identico a DABS e DABV
- Notifiche: struttura `send_telegram` / `send_ntfy` / `build_text_summary` — allineata a DABS/DABV
- Email: usa `msmtp` (DABS/DABV usano `swaks`)
- YAML: usa `yq` (DABV usa parser bash puro)
- Timeout action: `timeout_seconds` con default 3600s (KCR ha default 300s per-command)

## Non implementato
- Redis support (manca client nel container)
- Incremental backups (solo full dump)
- Backup selettivo per singolo DB senza editare config.yaml
- Encryption at rest
