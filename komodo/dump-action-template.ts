/**
 * Action: KDD Backup Runner
 * Orchestrates Docker backups for MySQL, PostgreSQL/PostGIS and MongoDB
 * using the KDD (Komodo Docker Dump) image.
 *
 * Connects the backup container to all required networks so it can
 * reach databases across different Docker stacks on the same server.
 *
 * ARGS JSON fields:
 *   server_name          - Komodo server name
 *   runner_network       - Primary Docker network to start the KDD container on
 *   backup_networks      - Networks to connect: array ["net1","net2"] or string "net1,net2"
 *                          Must include runner_network. Omit to skip extra connects.
 *   config_path          - Host path to the KDD config directory
 *   dump_path            - Host path to the backup output directory
 *   retention_days       - Days to keep backups (default: 7)
 *   timezone             - Container timezone (e.g. "Europe/Rome")
 *   server_display_name  - Label shown in email subject and push notifications
 *   job_name             - Label shown in email header
 *   image                - KDD image (e.g. "ghcr.io/kayaman78/kdd:latest")
 *   timeout_seconds      - Max seconds to wait for backup (default: 3600)
 *   dry_run              - "true" to scan without writing backups (default: "false")
 *   smtp.*               - SMTP settings (enabled, host, port, user, pass, from, to, tls)
 *   telegram.*           - Telegram settings (enabled, token, chat_id)
 *   ntfy.*               - ntfy settings (enabled, url, topic)
 *   notify.attach_log    - "true" | "false" — attach log to push notifications
 */

// ─── Main ───────────────────────────────────────────────────────

async function runBackup() {
    // @ts-ignore — ARGS is injected by Komodo at runtime
    const config = ARGS;

    if (!config?.server_name) {
        throw new Error("Missing required 'server_name' in ARGS.");
    }

    const extraNetworks = parseNetworks(config.backup_networks)
        .filter((n: string) => n !== config.runner_network);

    const timeoutMs     = (config.timeout_seconds ?? 3600) * 1000;
    const containerName = "kdd-backup-runner";
    const terminalName  = "kdd-backup-temp";

    console.log(`🚀 KDD Backup on server: ${config.server_name}`);
    console.log(`🌐 Runner network : ${config.runner_network}`);
    console.log(`🌐 Extra networks : ${extraNetworks.length > 0 ? extraNetworks.join(", ") : "none"}`);

    const pipeline = buildPipeline(config, containerName, extraNetworks);
    let terminalReady = false;

    try {
        for (const step of pipeline) {
            console.log(`\n▶️ ${step.label}`);
            await execCommand(
                config.server_name, terminalName, step.cmd,
                !terminalReady, timeoutMs,
            );
            terminalReady = true;
        }

        console.log("\n✅ BACKUP COMPLETED SUCCESSFULLY");

    } catch (err: any) {
        console.error(`\n❌ CRITICAL ERROR: ${err.message}`);
        throw err;

    } finally {
        if (terminalReady) {
            await execSafe(
                config.server_name, terminalName,
                `docker rm -f ${containerName} 2>/dev/null || true`, 15000,
            );
        }
        await deleteTerminalSafe(config.server_name, terminalName);
    }
}

// ─── Pipeline builder ───────────────────────────────────────────

interface Step { label: string; cmd: string }

function buildPipeline(
    config: any, container: string, extraNets: string[],
): Step[] {
    const steps: Step[] = [];

    steps.push({
        label: "Cleanup residual container",
        cmd: `docker rm -f ${container} 2>/dev/null || true`,
    });

    steps.push({
        label: `Pull ${config.image}`,
        cmd: `docker pull ${config.image}`,
    });

    steps.push({
        label: `Start container on ${config.runner_network}`,
        cmd: buildDockerRun(config, container),
    });

    for (const net of extraNets) {
        steps.push({
            label: `Connect network ${net}`,
            cmd: `docker network connect ${net} ${container}`,
        });
    }

    steps.push({
        label: "Run backup",
        cmd: `docker exec ${container} /app/backup.sh`,
    });

    return steps;
}

function buildDockerRun(config: any, container: string): string {
    const args = [
        "docker run -d",
        `--name ${container}`,
        `--network ${config.runner_network}`,
        "-v /var/run/docker.sock:/var/run/docker.sock:ro",
        `-v '${config.config_path}':/config:ro`,
        `-v '${config.dump_path}':/backups`,
        ...buildEnvFlags(config),
        `--entrypoint sleep ${config.image} infinity`,
    ];
    return args.join(" ");
}

function buildEnvFlags(config: any): string[] {
    const e = (key: string, val: string) => `-e ${key}='${val}'`;
    return [
        e("RETENTION_DAYS", config.retention_days),
        e("TZ",             config.timezone),
        e("ENABLE_EMAIL",   config.smtp.enabled),
        e("SMTP_HOST",      config.smtp.host),
        e("SMTP_PORT",      config.smtp.port),
        e("SMTP_USER",      config.smtp.user),
        e("SMTP_PASS",      config.smtp.pass),
        e("SMTP_FROM",      config.smtp.from),
        e("SMTP_TO",        config.smtp.to),
        e("SMTP_TLS",       config.smtp.tls),
        e("SERVER_NAME",    config.server_display_name),
        e("JOB_NAME",       config.job_name),
        e("TELEGRAM_ENABLED", config.telegram?.enabled  ?? "false"),
        e("TELEGRAM_TOKEN",   config.telegram?.token    ?? ""),
        e("TELEGRAM_CHAT_ID", config.telegram?.chat_id  ?? ""),
        e("NTFY_ENABLED",     config.ntfy?.enabled ?? "false"),
        e("NTFY_URL",         config.ntfy?.url     ?? ""),
        e("NTFY_TOPIC",       config.ntfy?.topic   ?? ""),
        e("NOTIFY_ATTACH_LOG", config.notify?.attach_log ?? "false"),
        e("DRY_RUN",          config.dry_run ?? "false"),
    ];
}

// ─── Komodo terminal helpers ────────────────────────────────────

async function execCommand(
    server: string, terminal: string, command: string,
    init: boolean, timeoutMs: number,
): Promise<void> {
    let exitCode = "0";
    let finished = false;

    const args: any = { server, terminal, command };
    if (init) {
        args.init = {
            command: "bash",
            recreate: Types.TerminalRecreateMode.Always,
        };
    }

    await komodo.execute_server_terminal(args, {
        onLine:   (line: string) => console.log(`  ${line}`),
        onFinish: (code: string) => { exitCode = code; finished = true; },
    });

    const deadline = Date.now() + timeoutMs;
    while (!finished) {
        if (Date.now() > deadline) {
            throw new Error(`Timed out after ${Math.round(timeoutMs / 1000)}s`);
        }
        await new Promise(r => setTimeout(r, 500));
    }

    if (exitCode !== "0") {
        throw new Error(`Exit code ${exitCode}`);
    }
}

/** Best-effort single command — capped by Promise.race, never hangs. */
async function execSafe(
    server: string, terminal: string, command: string, timeoutMs: number,
): Promise<void> {
    try {
        await Promise.race([
            komodo.execute_server_terminal(
                { server, terminal, command },
                { onLine: () => {}, onFinish: () => {} },
            ),
            new Promise<void>((_, reject) =>
                setTimeout(() => reject(new Error("cleanup timeout")), timeoutMs),
            ),
        ]);
    } catch (_) { /* best effort */ }
}

async function deleteTerminalSafe(server: string, terminal: string): Promise<void> {
    try {
        await komodo.write("DeleteTerminal", {
            target: { type: "Server", params: { server } },
            terminal,
        });
        console.log("🧹 Terminal removed.");
    } catch (_) {
        console.log("🧹 Terminal already closed.");
    }
}

// ─── Parsing ────────────────────────────────────────────────────

function parseNetworks(raw: any): string[] {
    if (!raw) return [];
    if (Array.isArray(raw)) return raw.filter((n: string) => n.length > 0);
    return String(raw).split(",").map((n: string) => n.trim()).filter((n: string) => n.length > 0);
}

// ─── Run ────────────────────────────────────────────────────────

await runBackup();
