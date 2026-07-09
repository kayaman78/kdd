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
 *   server_display_name  - Label shown in email subject and push notifications
 *   job_name             - Label shown in email header
 *   image                - KDD image to use (e.g. "ghcr.io/kayaman78/kdd:latest")
 *   timeout_seconds      - Max seconds to wait for the backup to complete (default: 3600)
 *   dry_run              - "true" to scan without writing any backups or touching files (default: "false")
 *   smtp.enabled         - "true" | "false"
 *   smtp.host            - SMTP server address
 *   smtp.port            - SMTP port
 *   smtp.user            - SMTP username (leave empty for unauthenticated)
 *   smtp.pass            - SMTP password
 *   smtp.from            - Sender address
 *   smtp.to              - Recipient address(es), comma-separated
 *   smtp.tls             - "auto" | "on" | "off"
 *   telegram.enabled     - "true" | "false"
 *   telegram.token       - Telegram bot token
 *   telegram.chat_id     - Telegram chat/channel ID
 *   ntfy.enabled         - "true" | "false"
 *   ntfy.url             - ntfy server URL (e.g. "https://ntfy.sh" or self-hosted)
 *   ntfy.topic           - ntfy topic name
 *   notify.attach_log    - "true" | "false" — attach log file to push notifications
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

    const timeoutMs     = (config.timeout_seconds ?? 3600) * 1000;
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
  -v '${config.config_path}':/config:ro \\
  -v '${config.dump_path}':/backups \\
  -e RETENTION_DAYS='${config.retention_days}' \\
  -e TZ='${config.timezone}' \\
  -e ENABLE_EMAIL='${config.smtp.enabled}' \\
  -e SMTP_HOST='${config.smtp.host}' \\
  -e SMTP_PORT='${config.smtp.port}' \\
  -e SMTP_USER='${config.smtp.user}' \\
  -e SMTP_PASS='${config.smtp.pass}' \\
  -e SMTP_FROM='${config.smtp.from}' \\
  -e SMTP_TO='${config.smtp.to}' \\
  -e SMTP_TLS='${config.smtp.tls}' \\
  -e SERVER_NAME='${config.server_display_name}' \\
  -e JOB_NAME='${config.job_name}' \\
  -e TELEGRAM_ENABLED='${config.telegram?.enabled ?? 'false'}' \\
  -e TELEGRAM_TOKEN='${config.telegram?.token ?? ''}' \\
  -e TELEGRAM_CHAT_ID='${config.telegram?.chat_id ?? ''}' \\
  -e NTFY_ENABLED='${config.ntfy?.enabled ?? 'false'}' \\
  -e NTFY_URL='${config.ntfy?.url ?? ''}' \\
  -e NTFY_TOPIC='${config.ntfy?.topic ?? ''}' \\
  -e NOTIFY_ATTACH_LOG='${config.notify?.attach_log ?? 'false'}' \\
  -e DRY_RUN='${config.dry_run ?? 'false'}' \\
  --entrypoint sleep ${config.image} infinity

echo "[KDD] Connecting extra networks..."
${networkConnectCmds}

echo "[KDD] Running backup..."
docker exec ${containerName} /app/backup.sh
_kdd_rc=$?
exit $_kdd_rc
`.trim();

    let exitCode: string | null = null;
    let executionFinished = false;

    try {
        // Komodo v2 unified API: terminal init + command in a single call.
        // `init` opens the terminal with bash, then `command` runs the docker workflow.
        await komodo.execute_server_terminal(
            {
                server: config.server_name,
                terminal: terminalName,
                command: dockerCommand,
                init: {
                    command: "bash",
                    recreate: Types.TerminalRecreateMode.Always,
                },
            },
            {
                onLine: (line: string) => console.log(`[KDD] ${line}`),
                onFinish: (code: string) => {
                    exitCode = code;
                    executionFinished = true;
                },
            }
        );

        const deadline = Date.now() + timeoutMs;
        while (!executionFinished) {
            if (Date.now() > deadline) {
                throw new Error(`Backup timed out after ${config.timeout_seconds ?? 3600}s`);
            }
            await new Promise(r => setTimeout(r, 500));
        }

        if (exitCode === "0") {
            console.log("✅ BACKUP COMPLETED SUCCESSFULLY");
        } else {
            throw new Error(`Backup failed with exit code: ${exitCode}`);
        }

    } catch (err: any) {
        console.error(`❌ CRITICAL ERROR: ${err.message}`);
        throw err;

    } finally {
        // Two-step cleanup: graceful shell exit → DeleteTerminal.
        // The bash shell opened by `init` stays alive after the command finishes,
        // leaving the terminal open in Komodo UI. Sending "exit 0" closes it.
        // Promise.race guards against the edge case where the shell already died
        // (e.g. set -e in non-interactive mode) — the SDK promise would hang
        // indefinitely, so we cap the wait at 2s and fall through to DeleteTerminal.
        console.log("🧹 Cleaning up terminal resources...");
        try {
            await Promise.race([
                komodo.execute_server_terminal(
                    {
                        server: config.server_name,
                        terminal: terminalName,
                        command: "exit 0",
                    },
                    { onLine: () => {}, onFinish: () => {} }
                ),
                new Promise(r => setTimeout(r, 2000)),
            ]);
        } catch (e) { /* graceful exit failed — proceed to hard cleanup */ }
        try {
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