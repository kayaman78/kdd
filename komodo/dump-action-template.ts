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

    console.log(`Starting KDD Backup on server: ${config.server_name}`);

    const allNetworks: string[] = config.backup_networks
        ? (Array.isArray(config.backup_networks)
            ? config.backup_networks
            : String(config.backup_networks).split(",").map((n: string) => n.trim())
          ).filter((n: string) => n.length > 0)
        : [];

    const extraNetworks = allNetworks.filter((n: string) => n !== config.runner_network);

    console.log(`Runner network : ${config.runner_network}`);
    console.log(`Extra networks : ${extraNetworks.length > 0 ? extraNetworks.join(", ") : "none"}`);

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
  -e TELEGRAM_ENABLED=${config.telegram?.enabled ?? 'false'} \\
  -e TELEGRAM_TOKEN=${config.telegram?.token ?? ''} \\
  -e TELEGRAM_CHAT_ID=${config.telegram?.chat_id ?? ''} \\
  -e NTFY_ENABLED=${config.ntfy?.enabled ?? 'false'} \\
  -e NTFY_URL=${config.ntfy?.url ?? ''} \\
  -e NTFY_TOPIC=${config.ntfy?.topic ?? ''} \\
  -e NOTIFY_ATTACH_LOG=${config.notify?.attach_log ?? 'false'} \\
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
        console.log("Terminal created.");

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
            console.log("BACKUP COMPLETED SUCCESSFULLY");
        } else {
            throw new Error(`Backup failed with exit code: ${exitCode}`);
        }

    } catch (err: any) {
        console.error(`CRITICAL ERROR: ${err.message}`);
        throw err;

    } finally {
        console.log("Cleaning up terminal resources...");
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

            console.log("Terminal resource removed.");
        } catch (e) {
            console.log("Cleanup: Terminal already closed.");
        }
    }
}

await runBackup();