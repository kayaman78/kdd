// Action: KDD Backup Runner
// Description: Runs KDD backup on specified server with configurable SMTP parameters

// ==================== CONFIGURABLE PARAMETERS ====================

const CONFIG = {
  // Target server (Komodo server name, NOT the ID)
  SERVER_NAME: "nameserver",  // <-- MODIFY HERE: put your Komodo server name
  
  // Docker network
  NETWORK: "namenetwork",
  
  // Volumes (modify paths if needed)
  CONFIG_PATH: "/stackpath/kdd/config",
  DUMP_PATH: "/stackpath/kdd/dump",
  
  // Backup parameters
  RETENTION_DAYS: "7",
  TIMEZONE: "Europe/Rome",
  
  // SMTP configuration (editable)
  SMTP: {
    ENABLED: "false",
    HOST: "smtp",
    PORT: "25",
    USER: "your-email@gmail.com",
    PASS: "your-app-password",  // <-- Use Komodo secrets for this!
    FROM: "backup@yourdomain.com",
    TO: "admin@yourdomain.com",
    TLS: "off"  // on/off
  },
  
  // KDD Image
  IMAGE: "ghcr.io/kayaman78/kdd:latest"
};

// ==================== ACTION CODE ====================

async function runBackup() {
  // Static name to avoid issues
  const terminalName = `kdd-backup-temp`;
  
  const dockerCommand = `docker run --rm \\
    --name kdd-backup-runner-$(date +%s) \\
    --network ${CONFIG.NETWORK} \\
    -v /var/run/docker.sock:/var/run/docker.sock:ro \\
    -v ${CONFIG.CONFIG_PATH}:/config:ro \\
    -v ${CONFIG.DUMP_PATH}:/backups \\
    -e RETENTION_DAYS=${CONFIG.RETENTION_DAYS} \\
    -e TZ=${CONFIG.TIMEZONE} \\
    -e ENABLE_EMAIL=${CONFIG.SMTP.ENABLED} \\
    -e SMTP_HOST=${CONFIG.SMTP.HOST} \\
    -e SMTP_PORT=${CONFIG.SMTP.PORT} \\
    -e SMTP_USER=${CONFIG.SMTP.USER} \\
    -e SMTP_PASS='${CONFIG.SMTP.PASS}' \\
    -e SMTP_FROM=${CONFIG.SMTP.FROM} \\
    -e SMTP_TO=${CONFIG.SMTP.TO} \\
    -e SMTP_TLS=${CONFIG.SMTP.TLS} \\
    ${CONFIG.IMAGE} \\
    /app/backup.sh --network-filter ${CONFIG.NETWORK}`;

  console.log(`🚀 Starting KDD backup on server: ${CONFIG.SERVER_NAME}`);
  
  let exitCode = null;
  let executionFinished = false;
  
  try {
    // Create terminal
    await komodo.write("CreateTerminal", {
      server: CONFIG.SERVER_NAME,
      name: terminalName,
      command: "bash",
      recreate: Types.TerminalRecreateMode.Always,
    });
    
    console.log("✅ Terminal created, starting backup...");
    
    // Execute command with real-time logging
    await komodo.execute_terminal(
      {
        server: CONFIG.SERVER_NAME,
        terminal: terminalName,
        command: dockerCommand,
      },
      {
        onLine: (line) => {
          console.log(`📝 ${line}`);
        },
        onFinish: (code) => {
          exitCode = code;
          executionFinished = true;
          console.log(`🏁 Process finished with exit code: ${code}`);
        },
      }
    );
    
    // Wait for execution to finish
    while (!executionFinished) {
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    
    // Evaluate result
    const finalCode = Number(exitCode ?? 0);
    
    if (finalCode === 0) {
      console.log("✅ BACKUP COMPLETED SUCCESSFULLY!");
      console.log(`📁 Dumps saved to: ${CONFIG.DUMP_PATH}`);
    } else {
      throw new Error(`Backup failed with exit code ${finalCode}`);
    }
    
  } catch (error) {
    console.error("❌ Error:", error);
    throw error;
  } finally {
    // Close terminal immediately
    console.log("🧹 Closing terminal...");
    
    try {
      // Try to force close by sending exit command
      await komodo.execute_terminal(
        {
          server: CONFIG.SERVER_NAME,
          terminal: terminalName,
          command: "exit 0",
        },
        { onLine: () => {}, onFinish: () => {} }
      );
      
      // Wait a moment
      await new Promise(resolve => setTimeout(resolve, 300));
      
      // Then delete terminal
      await komodo.write("DeleteTerminal", {
        server: CONFIG.SERVER_NAME,
        name: terminalName,
      });
      
      console.log("✅ Terminal closed and deleted");
    } catch (e) {
      console.log(`⚠️  Cleanup error: ${e?.message || "unknown"}`);
      
      // If it fails, try direct deletion
      try {
        await komodo.write("DeleteTerminal", {
          server: CONFIG.SERVER_NAME,
          name: terminalName,
        });
      } catch {
        // Ignore final deletion errors
      }
    }
  }
}

await runBackup();