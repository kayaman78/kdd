#!/bin/bash
# =============================================================================
# Database Backup Script with Email Notifications
# =============================================================================
# Executes backups for all databases configured in config.yaml
# Supports: MySQL/MariaDB, PostgreSQL, MongoDB
#
# Features:
# - Email notifications with HTML report (optional)
# - Detailed logging to file
# - SMTP authentication (optional)
# - SSL/TLS support
#
# Output: /backups/STACK_NAME/dump-YYYY-MM-DD_HH-MM.{sql.gz|archive.gz}
# Logs: /backups/backup.log (or custom path via --log-file)
# Retention: Keeps last 7 days of backups per database (configurable)
#
# Usage from cron:
#   docker run --rm \
#     -v /var/run/docker.sock:/var/run/docker.sock:ro \
#     -v /srv/docker/db-backup/config:/config:ro \
#     -v /srv/docker/db-backup/dump:/backups \
#     --network bridge \
#     db-backup-tool:latest /app/backup.sh
#
# Options:
#   --verbose              Show detailed debug output
#   --retention N          Keep backups for N days (default: 7)
#   --log-file PATH        Custom log file path (default: /backups/backup.log)
#   --enable-email         Send email notification after backup
#   --smtp-host HOST       SMTP server hostname
#   --smtp-port PORT       SMTP server port (default: 587)
#   --smtp-user USER       SMTP authentication username (optional)
#   --smtp-pass PASS       SMTP authentication password (optional)
#   --smtp-from EMAIL      From email address
#   --smtp-to EMAIL        To email address (can be repeated)
#   --smtp-tls auto|on|off TLS mode (default: auto)
#
# For reuse on new servers:
# - Modify RETENTION_DAYS to change backup retention policy
# - Network must match your Docker containers' network
# - Configure SMTP settings for email notifications
# =============================================================================

# Do NOT use set -e to prevent script exit on first error
# We want to continue backing up other databases even if one fails
set -u  # Exit only on undefined variables
set -o pipefail  # Propagate errors in pipes

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
CONFIG="/config/config.yaml"
BACKUPS_DIR="/backups"
LOG_FILE="/backups/backup.log"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
RETENTION_DAYS=7
VERBOSE=false

# Email configuration
ENABLE_EMAIL=false
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASS=""
SMTP_FROM=""
SMTP_TO=()
SMTP_TLS="auto"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --retention)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        --enable-email)
            ENABLE_EMAIL=true
            shift
            ;;
        --smtp-host)
            SMTP_HOST="$2"
            shift 2
            ;;
        --smtp-port)
            SMTP_PORT="$2"
            shift 2
            ;;
        --smtp-user)
            SMTP_USER="$2"
            shift 2
            ;;
        --smtp-pass)
            SMTP_PASS="$2"
            shift 2
            ;;
        --smtp-from)
            SMTP_FROM="$2"
            shift 2
            ;;
        --smtp-to)
            SMTP_TO+=("$2")
            shift 2
            ;;
        --smtp-tls)
            SMTP_TLS="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# -----------------------------------------------------------------------------
# LOGGING FUNCTIONS
# -----------------------------------------------------------------------------

# Initialize log file
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Rotate log if larger than 10MB
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 10485760 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
    
    echo "==========================================" >> "$LOG_FILE"
    echo "Backup started: $(date +'%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo "==========================================" >> "$LOG_FILE"
}

# Log to both stdout and file
log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
    echo "$message"
    echo "$message" >> "$LOG_FILE"
}

# Verbose logging
log_verbose() {
    if [ "$VERBOSE" = true ]; then
        local message="[$(date +'%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
        echo "$message"
        echo "$message" >> "$LOG_FILE"
    else
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [DEBUG] $*" >> "$LOG_FILE"
    fi
}

# Error logging
log_error() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    echo "$message" >&2
    echo "$message" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# EMAIL FUNCTIONS
# -----------------------------------------------------------------------------

# Configure msmtp
configure_msmtp() {
    log_verbose "Configuring SMTP client"
    
    local msmtp_config="/tmp/.msmtprc"
    
    cat > "$msmtp_config" <<EOF
defaults
auth $([ -n "$SMTP_USER" ] && echo "on" || echo "off")
tls $SMTP_TLS
tls_starttls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /tmp/msmtp.log

account default
host $SMTP_HOST
port $SMTP_PORT
from $SMTP_FROM
$([ -n "$SMTP_USER" ] && echo "user $SMTP_USER")
$([ -n "$SMTP_PASS" ] && echo "password $SMTP_PASS")
EOF
    
    chmod 600 "$msmtp_config"
    export MSMTP_CONFIG="$msmtp_config"
    
    log_verbose "SMTP configuration created"
}

# Generate HTML email report
generate_html_report() {
    local total="$1"
    local failed="$2"
    local success=$((total - failed))
    local status_color="#28a745"
    local status_text="SUCCESS"
    
    if [ $failed -gt 0 ]; then
        if [ $success -eq 0 ]; then
            status_color="#dc3545"
            status_text="FAILED"
        else
            status_color="#ffc107"
            status_text="PARTIAL SUCCESS"
        fi
    fi
    
    cat <<EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 30px; border-radius: 8px; text-align: center; }
        .header h1 { margin: 0; font-size: 28px; }
        .header p { margin: 10px 0 0 0; opacity: 0.9; }
        .status { background: ${status_color}; color: white; padding: 20px; margin: 20px 0; border-radius: 8px; text-align: center; }
        .status h2 { margin: 0; font-size: 24px; }
        .summary { background: #f8f9fa; padding: 20px; border-radius: 8px; margin: 20px 0; }
        .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 15px; margin-top: 15px; }
        .summary-item { background: white; padding: 15px; border-radius: 6px; text-align: center; border-left: 4px solid #667eea; }
        .summary-item .value { font-size: 32px; font-weight: bold; color: #667eea; }
        .summary-item .label { color: #666; margin-top: 5px; font-size: 14px; }
        .database-list { margin: 20px 0; }
        .database-item { background: white; padding: 15px; margin: 10px 0; border-radius: 6px; border-left: 4px solid #28a745; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .database-item.failed { border-left-color: #dc3545; }
        .database-item h3 { margin: 0 0 10px 0; color: #333; font-size: 18px; }
        .database-item .detail { color: #666; font-size: 14px; margin: 5px 0; }
        .database-item .detail strong { color: #333; }
        .footer { text-align: center; margin-top: 30px; padding-top: 20px; border-top: 2px solid #e9ecef; color: #666; font-size: 14px; }
        .timestamp { color: #999; font-size: 12px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Database Backup Report</h1>
        <p>Automated backup execution summary</p>
    </div>
    
    <div class="status">
        <h2>${status_text}</h2>
    </div>
    
    <div class="summary">
        <h2 style="margin-top: 0;">Backup Summary</h2>
        <div class="summary-grid">
            <div class="summary-item">
                <div class="value">${total}</div>
                <div class="label">Total Databases</div>
            </div>
            <div class="summary-item">
                <div class="value" style="color: #28a745;">${success}</div>
                <div class="label">Successful</div>
            </div>
            <div class="summary-item">
                <div class="value" style="color: #dc3545;">${failed}</div>
                <div class="label">Failed</div>
            </div>
            <div class="summary-item">
                <div class="value">${RETENTION_DAYS}</div>
                <div class="label">Retention (days)</div>
            </div>
        </div>
    </div>
    
    <div class="database-list">
        <h2>Database Details</h2>
EOF
}

# Add database entry to report
add_database_to_report() {
    local name="$1"
    local type="$2"
    local status="$3"
    local size="$4"
    local class="database-item"
    
    [ "$status" = "failed" ] && class="database-item failed"
    
    cat <<EOF
        <div class="${class}">
            <h3>${name}</h3>
            <div class="detail"><strong>Type:</strong> ${type}</div>
            <div class="detail"><strong>Status:</strong> ${status}</div>
            $([ "$status" = "success" ] && echo "<div class=\"detail\"><strong>Size:</strong> ${size}</div>")
            <div class="detail"><strong>Timestamp:</strong> ${TIMESTAMP}</div>
        </div>
EOF
}

# Close HTML report
close_html_report() {
    local disk_usage="$1"
    
    cat <<EOF
    </div>
    
    <div class="footer">
        <p><strong>Backup Location:</strong> ${BACKUPS_DIR}</p>
        <p><strong>Total Disk Usage:</strong> ${disk_usage}</p>
        <p class="timestamp">Report generated: $(date +'%Y-%m-%d %H:%M:%S %Z')</p>
    </div>
</body>
</html>
EOF
}

# Send email notification
send_email() {
    local subject="$1"
    local html_body="$2"
    
    if [ "$ENABLE_EMAIL" = false ]; then
        log_verbose "Email notifications disabled, skipping"
        return 0
    fi
    
    if [ -z "$SMTP_HOST" ] || [ -z "$SMTP_FROM" ] || [ ${#SMTP_TO[@]} -eq 0 ]; then
        log_error "Email enabled but SMTP settings incomplete"
        return 1
    fi
    
    log "Sending email notification..."
    
    configure_msmtp
    
    local email_file="/tmp/email_$.html"
    echo "$html_body" > "$email_file"
    
    for recipient in "${SMTP_TO[@]}"; do
        log_verbose "Sending to: $recipient"
        
        (
            echo "From: $SMTP_FROM"
            echo "To: $recipient"
            echo "Subject: $subject"
            echo "Content-Type: text/html; charset=UTF-8"
            echo ""
            cat "$email_file"
        ) | msmtp --file="$MSMTP_CONFIG" "$recipient" 2>&1 | tee -a "$LOG_FILE"
        
        if [ ${PIPESTATUS[1]} -eq 0 ]; then
            log "Email sent successfully to $recipient"
        else
            log_error "Failed to send email to $recipient"
            log_verbose "Check msmtp log: /tmp/msmtp.log"
        fi
    done
    
    rm -f "$email_file"
}

# -----------------------------------------------------------------------------
# BACKUP FUNCTIONS
# -----------------------------------------------------------------------------

# Rotate backups: keep only last N days
rotate_backups() {
    local target_dir="$1"
    local stack_name=$(basename "$target_dir")
    
    log_verbose "Rotating backups for $stack_name (retention: $RETENTION_DAYS days)"
    
    local deleted=0
    while IFS= read -r old_file; do
        log "Removing old backup: $(basename "$old_file")"
        rm -f "$old_file"
        ((deleted++))
    done < <(find "$target_dir" -type f -mtime +${RETENTION_DAYS} 2>/dev/null || true)
    
    if [ $deleted -eq 0 ]; then
        log_verbose "No old backups to remove"
    else
        log_verbose "Removed $deleted old backups"
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# MAIN EXECUTION
# -----------------------------------------------------------------------------

# Initialize logging
init_log

log "=== Universal DB Backup ==="
log "Timestamp: $TIMESTAMP"
log "Retention: $RETENTION_DAYS days"
log "Email notifications: $([ "$ENABLE_EMAIL" = true ] && echo "enabled" || echo "disabled")"
log "=========================================="
echo

# Verify config.yaml exists
if [ ! -f "$CONFIG" ]; then
    log_error "config.yaml not found at /config!"
    log_error "Run ./setup.sh first to generate configuration"
    exit 1
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUPS_DIR"

# Initialize counters and HTML report
total_backups=0
failed_backups=0
backup_details=""

# Start HTML report
html_report=$(generate_html_report 0 0)

# -----------------------------------------------------------------------------
# MYSQL / MARIADB
# -----------------------------------------------------------------------------
log ">> MySQL / MariaDB"
mysql_count=$(yq e '.mysql | length' "$CONFIG")
log_verbose "Found $mysql_count MySQL/MariaDB databases in config"

if [ "$mysql_count" -gt 0 ]; then
    for i in $(seq 0 $((mysql_count-1))); do
        name=$(yq e ".mysql[$i].name" "$CONFIG")
        host=$(yq e ".mysql[$i].host" "$CONFIG")
        port=$(yq e ".mysql[$i].port" "$CONFIG")
        user=$(yq e ".mysql[$i].user" "$CONFIG")
        pass=$(yq e ".mysql[$i].password" "$CONFIG")
        db=$(yq e ".mysql[$i].dbname" "$CONFIG")
        
        log_verbose "Processing MySQL #$i: $name"
        
        target="$BACKUPS_DIR/$name"
        mkdir -p "$target"
        
        filename="dump-${TIMESTAMP}.sql.gz"
        filepath="$target/$filename"
        
        log "Backup MySQL: $name ($db)"
        
        if mysqldump \
            -h "$host" \
            -P "$port" \
            -u "$user" \
            -p"$pass" \
            --single-transaction \
            --routines \
            --triggers \
            --events \
            "$db" 2>/dev/null | gzip > "$filepath"; then
            
            size=$(du -h "$filepath" | cut -f1)
            log "  Created: $filename ($size)"
            ((total_backups++))
            backup_details+=$(add_database_to_report "$name" "MySQL" "success" "$size")
            rotate_backups "$target"
        else
            log_error "Failed to backup $name"
            ((failed_backups++))
            backup_details+=$(add_database_to_report "$name" "MySQL" "failed" "N/A")
            rm -f "$filepath"
        fi
        
        log_verbose "Completed MySQL #$i: $name"
        echo
    done
else
    log "No MySQL databases configured"
fi

log_verbose "MySQL section completed"
echo


# -----------------------------------------------------------------------------
# POSTGRESQL
# -----------------------------------------------------------------------------
log ">> PostgreSQL"
pg_count=$(yq e '.postgres | length' "$CONFIG")

if [ "$pg_count" -gt 0 ]; then
    for i in $(seq 0 $((pg_count-1))); do
        name=$(yq e ".postgres[$i].name" "$CONFIG")
        host=$(yq e ".postgres[$i].host" "$CONFIG")
        port=$(yq e ".postgres[$i].port" "$CONFIG")
        user=$(yq e ".postgres[$i].user" "$CONFIG")
        pass=$(yq e ".postgres[$i].password" "$CONFIG")
        db=$(yq e ".postgres[$i].dbname" "$CONFIG")
        
        target="$BACKUPS_DIR/$name"
        mkdir -p "$target"
        
        filename="dump-${TIMESTAMP}.sql.gz"
        filepath="$target/$filename"
        
        log "Backup PostgreSQL: $name ($db)"
        
        export PGPASSWORD="$pass"
        
        log_verbose "Executing pg_dump on host=$host port=$port user=$user db=$db"
        
        if pg_dump \
            -h "$host" \
            -p "$port" \
            -U "$user" \
            -d "$db" \
            --no-password \
            --clean \
            --if-exists 2>&1 | tee /tmp/pg_dump_error.log | gzip > "$filepath"; then
            
            size=$(du -h "$filepath" | cut -f1)
            log "  Created: $filename ($size)"
            ((total_backups++))
            backup_details+=$(add_database_to_report "$name" "PostgreSQL" "success" "$size")
            rotate_backups "$target"
        else
            log_error "Failed to backup $name"
            log_verbose "Error output: $(cat /tmp/pg_dump_error.log)"
            ((failed_backups++))
            backup_details+=$(add_database_to_report "$name" "PostgreSQL" "failed" "N/A")
            rm -f "$filepath"
        fi
        
        unset PGPASSWORD
        echo
    done
else
    log "No PostgreSQL databases configured"
fi
echo


# -----------------------------------------------------------------------------
# MONGODB
# -----------------------------------------------------------------------------
log ">> MongoDB"
mongo_count=$(yq e '.mongo | length' "$CONFIG")

if [ "$mongo_count" -gt 0 ]; then
    for i in $(seq 0 $((mongo_count-1))); do
        name=$(yq e ".mongo[$i].name" "$CONFIG")
        host=$(yq e ".mongo[$i].host" "$CONFIG")
        port=$(yq e ".mongo[$i].port" "$CONFIG")
        user=$(yq e ".mongo[$i].user" "$CONFIG")
        pass=$(yq e ".mongo[$i].password" "$CONFIG")
        authdb=$(yq e ".mongo[$i].authdb" "$CONFIG")
        db=$(yq e ".mongo[$i].dbname" "$CONFIG")
        
        target="$BACKUPS_DIR/$name"
        mkdir -p "$target"
        
        filename="dump-${TIMESTAMP}.archive.gz"
        filepath="$target/$filename"
        
        log "Backup MongoDB: $name ($db)"
        
        log_verbose "Executing mongodump on host=$host port=$port user=$user db=$db"
        
        if mongodump \
            --host="$host" \
            --port="$port" \
            --username="$user" \
            --password="$pass" \
            --authenticationDatabase="$authdb" \
            --db="$db" \
            --archive="$filepath" \
            --gzip 2>&1; then
            
            if [ -s "$filepath" ]; then
                size=$(du -h "$filepath" | cut -f1)
                log "  Created: $filename ($size)"
                ((total_backups++))
                backup_details+=$(add_database_to_report "$name" "MongoDB" "success" "$size")
                rotate_backups "$target"
            else
                log_error "Backup file is empty for $name"
                ((failed_backups++))
                backup_details+=$(add_database_to_report "$name" "MongoDB" "failed" "N/A")
                rm -f "$filepath"
            fi
        else
            log_error "Failed to backup $name"
            ((failed_backups++))
            backup_details+=$(add_database_to_report "$name" "MongoDB" "failed" "N/A")
            rm -f "$filepath"
        fi
        echo
    done
else
    log "No MongoDB databases configured"
fi
echo


# -----------------------------------------------------------------------------
# REDIS (DISABLED BY DEFAULT)
# -----------------------------------------------------------------------------
log ">> Redis"
redis_count=$(yq e '.redis | length' "$CONFIG")

if [ "$redis_count" -gt 0 ]; then
    log "Redis backup not implemented (typically cache-only)"
else
    log "No Redis databases configured"
fi
echo


# -----------------------------------------------------------------------------
# FINAL SUMMARY AND EMAIL
# -----------------------------------------------------------------------------
total_db_count=$((total_backups + failed_backups))
disk_usage=$(du -sh "$BACKUPS_DIR" 2>/dev/null | cut -f1 || echo "N/A")

log "=========================================="
log "Backup completed!"
log "=========================================="
log ""
log "Statistics:"
log "  - Successful backups:  $total_backups"
log "  - Failed backups:      $failed_backups"
log "  - Backup directory:    $BACKUPS_DIR"
log "  - Retention:           $RETENTION_DAYS days"
log "  - Total disk usage:    $disk_usage"
log ""

# Generate and send email report
if [ "$ENABLE_EMAIL" = true ]; then
    log "Generating email report..."
    
    html_report=$(generate_html_report "$total_db_count" "$failed_backups")
    html_report+="$backup_details"
    html_report+=$(close_html_report "$disk_usage")
    
    if [ $failed_backups -eq 0 ]; then
        email_subject="[SUCCESS] Database Backup - $TIMESTAMP"
    elif [ $total_backups -eq 0 ]; then
        email_subject="[FAILED] Database Backup - $TIMESTAMP"
    else
        email_subject="[PARTIAL] Database Backup - $TIMESTAMP"
    fi
    
    send_email "$email_subject" "$html_report"
fi

# Exit with error if any backups failed
if [ $failed_backups -gt 0 ]; then
    log "Some backups failed. Check logs above."
    exit 1
fi

log "All backups completed successfully"
exit 0