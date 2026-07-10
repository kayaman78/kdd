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
- **DB clients:** `mysql-client`, `postgresql-client-18`, `mongodump` v100.17.0
- **Tools:** `docker-ce-cli`, `yq` v4.53.3, `jq`, `msmtp`, `curl`, `gzip`
- **Image pubblicata:** `ghcr.io/kayaman78/kdd:latest`

## Flusso Komodo Action (v2 API — sequential pipeline)

L'action usa il pattern KCR: comandi singoli inviati uno alla volta nello stesso terminale persistente. Ogni comando è una riga sola — `execute_server_terminal` dell'SDK Komodo risolve la promise solo per comandi single-line.

**Pipeline:**
1. `docker rm -f kdd-backup-runner` — cleanup residuo da run precedenti falliti
2. `docker pull <image>` — pull immagine
3. `docker run -d ...` — avvia container con `sleep infinity` + tutte le env vars
4. `docker network connect <net>` — una call per ogni rete extra
5. `docker exec <container> /app/backup.sh` — esegue il backup

Ogni step usa `execCommand()` che aspetta `onFinish` con timeout. Se un comando fallisce, il loop si interrompe e l'errore viene propagato.

**Cleanup:** nel `finally` block, `execSafe()` tenta di rimuovere il container Docker (capped a 15s via `Promise.race` — mai hang), poi `deleteTerminalSafe()` rimuove il terminale Komodo.

## Terminal lifecycle — le 3 regole

1. **Mai multi-riga.** L'SDK Komodo non risolve la promise per blocchi multi-riga. Ogni `execute_server_terminal` riceve un singolo comando one-line. Il `docker run -d` con 20+ env flags viene costruito come array di stringhe (`buildDockerRun` + `buildEnvFlags`) e joinato con spazi.

2. **Mai `execute_server_terminal("exit")`.** Mandare `exit` uccide la shell, la connessione SDK si rompe, la promise resta pending. La shell muore solo quando `DeleteTerminal` la uccide.

3. **`execSafe()` per cleanup.** Nel `finally` block, ogni `execute_server_terminal` è wrappato in `Promise.race` con timeout — se la connessione è morta, non hang mai.

**Storico bug:** v2.0.0–v2.0.2 usavano un unico blocco bash multi-riga come comando → la promise SDK non risolveva mai → l'action restava in "running" per sempre. Fix v3.0.0: riscrittura completa con pipeline sequenziale single-command.

## Single-instance-per-server design (consapevole)
Sia `containerName = "kdd-backup-runner"` sia `terminalName = "kdd-backup-temp"` sono **hardcoded by design**. Conseguenza: due action KDD lanciate concorrentemente sullo stesso server collidono (sul container Docker prima ancora che sul terminal Komodo, perché il `--name` di `docker run` deve essere unico). Non è un bug — KDD è pensato per girare una volta per server schedulato (backup notturno, hourly, etc.), non in parallelo. Il primo step della pipeline (`docker rm -f`) nukes residui da run precedenti killed/timeout.

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
`rotate_backups()` mantiene gli **ultimi RETENTION_DAYS dump per database** (semantica N-most-recent, calendar-independent). Stessa policy applicata a logs (`backup_*.log`). Coerente con DABS e DABV.

**Perché non più calendar-based** (fix S199): la versione precedente usava `find -mtime +"$((RETENTION_DAYS - 1))" -delete`, che cancellava tutto ciò che era più vecchio di N giorni dal *now*. Caso d'uso roto: backup pausato per 30 giorni → alla prima nuova copia tutti gli archivi precedenti sparivano, lasciando 1 solo dump fresh. Il fix N-most-recent garantisce che gli archivi esistenti sopravvivano finché non vengono rimpiazzati uno-a-uno da nuovi dump. Implementazione: helper `_files_to_rotate()` che elenca i file di un target ordinati per mtime desc e ritorna quelli oltre i top N — usato da rotate_backups e log retention identicamente.

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
- Retention: N-most-recent (mantieni gli ultimi RETENTION_DAYS dump per target) — identico a DABS e DABV post-fix S199
- Notifiche: struttura `send_telegram` / `send_ntfy` / `build_text_summary` — allineata a DABS/DABV
- Email: usa `msmtp` (DABS/DABV usano `swaks`)
- YAML: usa `yq` (DABV usa parser bash puro)
- Timeout action: `timeout_seconds` con default 3600s (KCR ha default 300s per-command)
- Komodo v2 terminal: pipeline sequenziale single-command — identico a KCR

## Non implementato
- Redis support (manca client nel container)
- Incremental backups (solo full dump)
- Backup selettivo per singolo DB senza editare config.yaml
- Encryption at rest
