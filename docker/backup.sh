#!/bin/bash
# =============================================================================
# KDD - Database Backup Script
# =============================================================================
# Executes backups for all databases in config.yaml
# Supports: MySQL/MariaDB, PostgreSQL, MongoDB
#
# Configuration via environment variables:
#   RETENTION_DAYS - Backup retention (default: 7)
#   ENABLE_EMAIL   - Send email report (default: false)
#   SMTP_HOST      - SMTP server
#   SMTP_PORT      - SMTP port (default: 587)
#   SMTP_USER      - SMTP username
#   SMTP_PASS      - SMTP password
#   SMTP_FROM      - From email address
#   SMTP_TO        - To email addresses (comma-separated)
#   SMTP_TLS       - TLS mode: auto|on|off (default: auto)
# =============================================================================

set -u
set -o pipefail

CONFIG="/config/config.yaml"
BACKUPS_DIR="/backups"
LOG_FILE="/backups/backup.log"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")

# Configuration from environment
RETENTION_DAYS=${RETENTION_DAYS:-7}
ENABLE_EMAIL=${ENABLE_EMAIL:-false}
SMTP_HOST=${SMTP_HOST:-}
SMTP_PORT=${SMTP_PORT:-587}
SMTP_USER=${SMTP_USER:-}
SMTP_PASS=${SMTP_PASS:-}
SMTP_FROM=${SMTP_FROM:-}
SMTP_TO=${SMTP_TO:-}
SMTP_TLS=${SMTP_TLS:-auto}

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------

init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0) -gt 10485760 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
    echo "========================================" >> "$LOG_FILE"
    echo "KDD Backup: $(date +'%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
}

log() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE"
}

# -----------------------------------------------------------------------------
# EMAIL FUNCTIONS
# -----------------------------------------------------------------------------

configure_msmtp() {
    local config="/tmp/.msmtprc"
    cat > "$config" <<EOF
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
    chmod 600 "$config"
    export MSMTP_CONFIG="$config"
}

generate_html_report() {
    local total="$1"
    local failed="$2"
    local success=$((total - failed))
    local status_color="#28a745"
    local status_text="SUCCESS"
    
    if [ $failed -gt 0 ]; then
        [ $success -eq 0 ] && status_color="#dc3545" && status_text="FAILED"
        [ $success -gt 0 ] && status_color="#ffc107" && status_text="PARTIAL"
    fi
    
    cat <<EOF
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8">
<style>
body{font-family:Arial,sans-serif;max-width:800px;margin:20px auto;padding:20px}
.header{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:white;padding:30px;border-radius:8px;text-align:center}
.status{background:${status_color};color:white;padding:20px;margin:20px 0;border-radius:8px;text-align:center}
.summary{background:#f8f9fa;padding:20px;border-radius:8px;margin:20px 0}
.item{background:white;padding:15px;margin:10px 0;border-radius:6px;border-left:4px solid #28a745}
.item.failed{border-left-color:#dc3545}
.footer{text-align:center;margin-top:30px;color:#666;font-size:14px}
</style>
</head>
<body>
<div class="header"><h1>KDD Backup Report</h1></div>
<div class="status"><h2>${status_text}</h2></div>
<div class="summary">
<h3>Summary</h3>
<p>Total: ${total} | Success: ${success} | Failed: ${failed}</p>
<p>Retention: ${RETENTION_DAYS} days | Timestamp: ${TIMESTAMP}</p>
</div>
<div class="content">
EOF
}

add_db_to_report() {
    local name="$1"
    local type="$2"
    local status="$3"
    local size="$4"
    local class="item"
    [ "$status" = "failed" ] && class="item failed"
    
    cat <<EOF
<div class="${class}">
<h3>${name}</h3>
<p>Type: ${type} | Status: ${status} $([ "$status" = "success" ] && echo "| Size: ${size}")</p>
</div>
EOF
}

close_html_report() {
    local disk=$(du -sh "$BACKUPS_DIR" 2>/dev/null | cut -f1 || echo "N/A")
    cat <<EOF
</div>
<div class="footer">
<p>Location: ${BACKUPS_DIR} | Disk: ${disk}</p>
<p>$(date +'%Y-%m-%d %H:%M:%S %Z')</p>
</div>
</body></html>
EOF
}

send_email() {
    local subject="$1"
    local html="$2"
    
    [ "$ENABLE_EMAIL" != "true" ] && return 0
    [ -z "$SMTP_HOST" ] || [ -z "$SMTP_FROM" ] || [ -z "$SMTP_TO" ] && return 1
    
    configure_msmtp
    
    IFS=',' read -ra recipients <<< "$SMTP_TO"
    for recipient in "${recipients[@]}"; do
        (
            echo "From: $SMTP_FROM"
            echo "To: $recipient"
            echo "Subject: $subject"
            echo "Content-Type: text/html; charset=UTF-8"
            echo ""
            echo "$html"
        ) | msmtp --file="$MSMTP_CONFIG" "$recipient" 2>&1 | tee -a "$LOG_FILE"
    done
}

# -----------------------------------------------------------------------------
# BACKUP FUNCTIONS
# -----------------------------------------------------------------------------

rotate_backups() {
    local target="$1"
    find "$target" -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

init_log

log "KDD - Starting backup"
log "Retention: $RETENTION_DAYS days"

[ ! -f "$CONFIG" ] && log_error "config.yaml not found" && exit 1

mkdir -p "$BACKUPS_DIR"

total_backups=0
failed_backups=0
backup_details=""

html_report=$(generate_html_report 0 0)

# -----------------------------------------------------------------------------
# MYSQL
# -----------------------------------------------------------------------------

mysql_count=$(yq e '.mysql | length' "$CONFIG")

if [ "$mysql_count" -gt 0 ]; then
    log "Processing MySQL/MariaDB ($mysql_count databases)"
    
    for i in $(seq 0 $((mysql_count-1))); do
        name=$(yq e ".mysql[$i].name" "$CONFIG")
        host=$(yq e ".mysql[$i].host" "$CONFIG")
        port=$(yq e ".mysql[$i].port" "$CONFIG")
        user=$(yq e ".mysql[$i].user" "$CONFIG")
        pass=$(yq e ".mysql[$i].password" "$CONFIG")
        db=$(yq e ".mysql[$i].dbname" "$CONFIG")
        
        target="$BACKUPS_DIR/$name"
        mkdir -p "$target"
        
        filename="dump-${TIMESTAMP}.sql.gz"
        filepath="$target/$filename"
        
        log "  Backing up: $name"
        
        if mysqldump -h "$host" -P "$port" -u "$user" -p"$pass" \
            --single-transaction --routines --triggers --events \
            "$db" 2>/dev/null | gzip > "$filepath"; then
            
            size=$(du -h "$filepath" | cut -f1)
            log "    Success: $size"
            ((total_backups++))
            backup_details+=$(add_db_to_report "$name" "MySQL" "success" "$size")
            rotate_backups "$target"
        else
            log_error "  Failed: $name"
            ((failed_backups++))
            backup_details+=$(add_db_to_report "$name" "MySQL" "failed" "N/A")
            rm -f "$filepath"
        fi
    done
fi

# -----------------------------------------------------------------------------
# POSTGRESQL
# -----------------------------------------------------------------------------

pg_count=$(yq e '.postgres | length' "$CONFIG")

if [ "$pg_count" -gt 0 ]; then
    log "Processing PostgreSQL ($pg_count databases)"
    
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
        
        log "  Backing up: $name"
        
        export PGPASSWORD="$pass"
        
        if pg_dump -h "$host" -p "$port" -U "$user" -d "$db" \
            --no-password --clean --if-exists 2>/dev/null | gzip > "$filepath"; then
            
            size=$(du -h "$filepath" | cut -f1)
            log "    Success: $size"
            ((total_backups++))
            backup_details+=$(add_db_to_report "$name" "PostgreSQL" "success" "$size")
            rotate_backups "$target"
        else
            log_error "  Failed: $name"
            ((failed_backups++))
            backup_details+=$(add_db_to_report "$name" "PostgreSQL" "failed" "N/A")
            rm -f "$filepath"
        fi
        
        unset PGPASSWORD
    done
fi

# -----------------------------------------------------------------------------
# MONGODB
# -----------------------------------------------------------------------------

mongo_count=$(yq e '.mongo | length' "$CONFIG")

if [ "$mongo_count" -gt 0 ]; then
    log "Processing MongoDB ($mongo_count databases)"
    
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
        
        log "  Backing up: $name"
        
        if mongodump --host="$host" --port="$port" --username="$user" \
            --password="$pass" --authenticationDatabase="$authdb" \
            --db="$db" --archive="$filepath" --gzip 2>/dev/null; then
            
            if [ -s "$filepath" ]; then
                size=$(du -h "$filepath" | cut -f1)
                log "    Success: $size"
                ((total_backups++))
                backup_details+=$(add_db_to_report "$name" "MongoDB" "success" "$size")
                rotate_backups "$target"
            else
                log_error "  Failed: empty file"
                ((failed_backups++))
                backup_details+=$(add_db_to_report "$name" "MongoDB" "failed" "N/A")
                rm -f "$filepath"
            fi
        else
            log_error "  Failed: $name"
            ((failed_backups++))
            backup_details+=$(add_db_to_report "$name" "MongoDB" "failed" "N/A")
            rm -f "$filepath"
        fi
    done
fi

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------

total=$((total_backups + failed_backups))

log "Backup completed"
log "Success: $total_backups | Failed: $failed_backups"

# Send email
if [ "$ENABLE_EMAIL" = "true" ]; then
    html_report=$(generate_html_report "$total" "$failed_backups")
    html_report+="$backup_details"
    html_report+=$(close_html_report)
    
    if [ $failed_backups -eq 0 ]; then
        subject="[SUCCESS] KDD Backup - $TIMESTAMP"
    elif [ $total_backups -eq 0 ]; then
        subject="[FAILED] KDD Backup - $TIMESTAMP"
    else
        subject="[PARTIAL] KDD Backup - $TIMESTAMP"
    fi
    
    send_email "$subject" "$html_report"
fi

[ $failed_backups -gt 0 ] && exit 1
exit 0