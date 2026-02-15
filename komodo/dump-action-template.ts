/**
 * Action: KDD Backup Runner
 * Description: Orchestrates automated Docker backups for databases (MySQL, MongoDB, etc.)
 * using the KDD (Komodo Docker Dump) image. It dynamically pulls parameters from 
 * the Komodo 'ARGS' injection, executes the backup via a temporary terminal, 
 * and handles clean cleanup of resources.
 */

async function runBackup() {
    // @ts-ignore
    // ARGS is globally injected by Komodo from the 'Argument' field in the UI
    const config = ARGS;

    if (!config || !config.server_name) {
        throw new Error("Error: 'ARGS' parameters not found. Check your JSON configuration.");
    }

    console.log(`🚀 Starting KDD Backup on server: ${config.server_name}`);
    const terminalName = `kdd-backup-temp`;
    
    // Constructing the Docker command using injected parameters
    const dockerCommand = `docker run --rm \\
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
        ${config.image} \\
        /app/backup.sh --network-filter ${config.network}`;

    let exitCode: number | null = null;
    let executionFinished = false;

    try {
        // 1. Create a temporary terminal on the target server
        await komodo.write("CreateTerminal", {
            server: config.server_name,
            name: terminalName,
            command: "bash",
            recreate: "Always", 
        });

        console.log("✅ Terminal created successfully.");

        // 2. Execute the backup command and stream logs
        await komodo.execute_terminal(
            {
                server: config.server_name,
                terminal: terminalName,
                command: dockerCommand,
            },
            {
                onLine: (line: string) => console.log(`[KDD] ${line}`),
                onFinish: (code: number) => {
                    exitCode = code;
                    executionFinished = true;
                },
            }
        );

        // Wait for the onFinish callback to trigger
        while (!executionFinished) {
            await new Promise(r => setTimeout(r, 500));
        }

        // 3. Evaluate the result
        const finalStatus = Number(exitCode ?? 0);
        if (finalStatus === 0) {
            console.log("✅ BACKUP COMPLETED SUCCESSFULLY!");
        } else {
            throw new Error(`Backup failed with exit code: ${finalStatus}`);
        }

    } catch (err: any) {
        console.error(`❌ CRITICAL ERROR: ${err.message}`);
        throw err;
    } finally {
        // 4. Robust Cleanup: ensuring the terminal is closed and removed
        console.log("🧹 Cleaning up terminal resources...");
        try {
            // Send exit command to the bash process
            await komodo.execute_terminal(
                {
                    server: config.server_name,
                    terminal: terminalName,
                    command: "exit 0",
                },
                { onLine: () => {}, onFinish: () => {} }
            );
            
            // Short delay to allow the process to release handles
            await new Promise(resolve => setTimeout(resolve, 500));

            // Delete the terminal resource from Komodo
            await komodo.write("DeleteTerminal", {
                server: config.server_name,
                name: config.terminalName || terminalName,
            });
            console.log("✅ Terminal resource removed.");
        } catch (e) {
            console.log("⚠️ Cleanup note: Terminal was closed forcefully or was already gone.");
        }
    }
}

// Start the execution
await runBackup();