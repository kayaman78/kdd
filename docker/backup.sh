#!/bin/bash
# =============================================================================
# KDD - Database Backup Script
# =============================================================================
# Executes backups for all databases in config.yaml
# Supports: MySQL/MariaDB, PostgreSQL, MongoDB
#
# Configuration via environment variables:
#   RETENTION_DAYS   - Backup retention (default: 7)
#   SIZE_DROP_WARN   - % size drop vs previous backup that triggers a warning (default: 20)
#   ENABLE_EMAIL     - Send email report (default: false)
#   SMTP_HOST        - SMTP server
#   SMTP_PORT        - SMTP port (default: 587)
#   SMTP_USER        - SMTP username
#   SMTP_PASS        - SMTP password
#   SMTP_FROM        - From email address
#   SMTP_TO          - To email addresses (comma-separated)
#   SMTP_TLS         - TLS mode: auto|on|off (default: auto)
#   SERVER_NAME      - Server name for email subject (default: KDD)
#   JOB_NAME         - Job name for email header (default: Backup Report)
# =============================================================================

set -u
set -o pipefail

CONFIG="/config/config.yaml"
BACKUPS_DIR="/backups"
LOG_DIR="/backups/log"
LOG_FILE="$LOG_DIR/backup_$(date +%Y%m%d).log"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")

RETENTION_DAYS=${RETENTION_DAYS:-7}
SIZE_DROP_WARN=${SIZE_DROP_WARN:-20}
ENABLE_EMAIL=${ENABLE_EMAIL:-false}
SMTP_HOST=${SMTP_HOST:-}
SMTP_PORT=${SMTP_PORT:-587}
SMTP_USER=${SMTP_USER:-}
SMTP_PASS=${SMTP_PASS:-}
SMTP_FROM=${SMTP_FROM:-}
SMTP_TO=${SMTP_TO:-}
SMTP_TLS=${SMTP_TLS:-auto}
SERVER_NAME=${SERVER_NAME:-KDD}
JOB_NAME=${JOB_NAME:-Backup Report}

# Telegram (optional)
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_TOKEN=${TELEGRAM_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}

# ntfy (optional)
NTFY_ENABLED=${NTFY_ENABLED:-false}
NTFY_URL=${NTFY_URL:-}
NTFY_TOPIC=${NTFY_TOPIC:-}

# Attach log to push notifications
NOTIFY_ATTACH_LOG=${NOTIFY_ATTACH_LOG:-false}

NETWORK_FILTER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --network-filter) NETWORK_FILTER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------

init_log() {
    mkdir -p "$LOG_DIR"
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
# VERIFY FUNCTIONS
#
# Each function verifies a freshly created backup file.
# Returns: "OK" | "WARN:<reason>" | "FAIL:<reason>"
#
# Strategy:
#   MySQL/PG  — gzip integrity + completion marker in last 5 lines of dump
#   MongoDB   — gzip integrity (mongodump --archive writes atomically)
#   All       — size drop vs previous backup (warn if drop > SIZE_DROP_WARN%)
# -----------------------------------------------------------------------------

_check_size_drop() {
    local gz_file="$1"
    local target_dir="$2"
    local base_pattern="$3"   # glob to find previous backup, e.g. "dump-*.sql.gz"

    local curr_size
    curr_size=$(stat -c%s "$gz_file" 2>/dev/null || echo 0)

    local prev_backup
    prev_backup=$(find "$target_dir" -name "$base_pattern" \
        ! -newer "$gz_file" ! -samefile "$gz_file" \
        2>/dev/null | sort | tail -1)

    if [ -n "$prev_backup" ]; then
        local prev_size
        prev_size=$(stat -c%s "$prev_backup" 2>/dev/null || echo 0)
        if [ "$prev_size" -gt 0 ]; then
            local threshold=$(( prev_size * (100 - SIZE_DROP_WARN) / 100 ))
            if [ "$curr_size" -lt "$threshold" ]; then
                local prev_h curr_h
                prev_h=$(du -h "$prev_backup" | cut -f1)
                curr_h=$(du -h "$gz_file" | cut -f1)
                echo "WARN:size drop ${prev_h}→${curr_h}"
                return 1
            fi
        fi
    fi
    return 0
}

verify_mysql_backup() {
    local gz_file="$1"
    local target_dir="$2"

    # gzip integrity
    if ! gzip -t "$gz_file" 2>/dev/null; then
        echo "FAIL:gzip corrupt"; return 1
    fi

    # Completion marker — mysqldump always writes this as the last meaningful line
    local last_lines
    last_lines=$(zcat "$gz_file" 2>/dev/null | tail -5)
    if ! echo "$last_lines" | grep -q "Dump completed"; then
        echo "FAIL:dump incomplete (missing completion marker)"; return 1
    fi

    # Size drop
    local size_result
    if ! _check_size_drop "$gz_file" "$target_dir" "dump-*.sql.gz"; then
        size_result=$(echo "WARN")
        echo "WARN:size drop detected"
        return 0
    fi

    echo "OK"
}

verify_postgres_backup() {
    local gz_file="$1"
    local target_dir="$2"

    if ! gzip -t "$gz_file" 2>/dev/null; then
        echo "FAIL:gzip corrupt"; return 1
    fi

    local last_lines
    last_lines=$(zcat "$gz_file" 2>/dev/null | tail -5)
    if ! echo "$last_lines" | grep -q "PostgreSQL database dump complete"; then
        echo "FAIL:dump incomplete (missing completion marker)"; return 1
    fi

    if ! _check_size_drop "$gz_file" "$target_dir" "dump-*.sql.gz"; then
        echo "WARN:size drop detected"
        return 0
    fi

    echo "OK"
}

verify_mongo_backup() {
    local gz_file="$1"
    local target_dir="$2"

    # mongodump --archive writes atomically — gzip + non-empty is sufficient
    if ! gzip -t "$gz_file" 2>/dev/null; then
        echo "FAIL:gzip corrupt"; return 1
    fi

    if [ ! -s "$gz_file" ]; then
        echo "FAIL:empty archive"; return 1
    fi

    if ! _check_size_drop "$gz_file" "$target_dir" "dump-*.archive.gz"; then
        echo "WARN:size drop detected"
        return 0
    fi

    echo "OK"
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
body{font-family:Arial,sans-serif;max-width:850px;margin:20px auto;padding:20px}
.header{background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);color:white;padding:30px;border-radius:8px;text-align:center}
.status{background:${status_color};color:white;padding:20px;margin:20px 0;border-radius:8px;text-align:center}
.summary{background:#f8f9fa;padding:20px;border-radius:8px;margin:20px 0}
table{width:100%;border-collapse:collapse;margin-top:16px;font-size:13px}
th{padding:9px 8px;border:1px solid #ddd;background:#f2f2f2;text-align:left}
td{padding:8px;border:1px solid #ddd}
.footer{text-align:center;margin-top:30px;color:#666;font-size:12px}
</style>
</head>
<body>
<div class="header"><h1>${JOB_NAME}</h1></div>
<div class="status"><h2>${status_text}</h2></div>
<div class="summary">
<h3>Summary</h3>
<p>Total: ${total} | Success: ${success} | Failed: ${failed}</p>
<p>Retention: ${RETENTION_DAYS} days | Timestamp: ${TIMESTAMP}</p>
</div>
<table>
<thead>
<tr>
  <th>Name</th>
  <th>Type</th>
  <th>Size</th>
  <th style="text-align:center">Backup</th>
  <th style="text-align:center">Verify</th>
</tr>
</thead>
<tbody>
EOF
}

add_db_to_report() {
    local name="$1"
    local type="$2"
    local backup_status="$3"
    local size="$4"
    local verify_status="$5"

    local backup_color="#d4edda" backup_icon="✅"
    local verify_color="#d4edda" verify_icon="✅"
    local verify_label="$verify_status"

    [ "$backup_status" = "failed" ] && backup_color="#f8d7da" && backup_icon="❌"

    case "${verify_status%%:*}" in
        OK)      verify_color="#d4edda"; verify_icon="✅" ;;
        WARN)    verify_color="#fff3cd"; verify_icon="⚠️"; verify_label="${verify_status#*:}" ;;
        FAIL)    verify_color="#f8d7da"; verify_icon="❌"; verify_label="${verify_status#*:}" ;;
        skipped) verify_color="#f2f2f2"; verify_icon="—"; verify_label="skipped" ;;
    esac

    cat <<EOF
<tr>
  <td>${name}</td>
  <td>${type}</td>
  <td>$([ "$backup_status" = "success" ] && echo "$size" || echo "—")</td>
  <td style="text-align:center;background-color:${backup_color}">${backup_icon} ${backup_status}</td>
  <td style="text-align:center;background-color:${verify_color}">${verify_icon} ${verify_label}</td>
</tr>
EOF
}

close_html_report() {
    local verify_ok="$1"
    local verify_warn="$2"
    local verify_err="$3"
    local disk=$(du -sh "$BACKUPS_DIR" 2>/dev/null | cut -f1 || echo "N/A")
    cat <<EOF
</tbody></table>
<div class="footer">
<p>Verify ✅ ${verify_ok} &nbsp;⚠️ ${verify_warn} &nbsp;❌ ${verify_err}</p>
<p>Verify checks: gzip integrity + dump completion marker + size trend (warn if drop &gt; ${SIZE_DROP_WARN}%)</p>
<p>Log: ${LOG_FILE} | Location: ${BACKUPS_DIR} | Disk used: ${disk}</p>
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
# NOTIFICATION FUNCTIONS
# Each channel is fully independent. All use the same compact text summary.
# -----------------------------------------------------------------------------

build_text_summary() {
    local icon="✅"
    [ $failed_backups -gt 0 ] && icon="❌"
    [ $failed_backups -eq 0 ] && [ $verify_warn -gt 0 ] && icon="⚠️"
    [ $verify_err -gt 0 ] && icon="❌"

    local db_lines=""
    [ "$mysql_count" -gt 0 ] && db_lines+="MySQL ${mysql_ok}✅ ${mysql_fail}❌\n"
    [ "$pg_count"    -gt 0 ] && db_lines+="PostgreSQL ${pg_ok}✅ ${pg_fail}❌\n"
    [ "$mongo_count" -gt 0 ] && db_lines+="MongoDB ${mongo_ok}✅ ${mongo_fail}❌\n"

    printf "%s KDD Backup — %s | %s\n%sVerify %s✅ %s⚠️ %s❌" \
        "$icon" "$SERVER_NAME" "$TIMESTAMP" \
        "$db_lines" \
        "$verify_ok" "$verify_warn" "$verify_err"
}

send_telegram() {
    [ "$TELEGRAM_ENABLED" != "true" ] && return 0
    if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        log "⚠️  WARNING: Telegram enabled but TOKEN or CHAT_ID missing — skipping"
        return 1
    fi

    local text api
    text=$(build_text_summary)
    api="https://api.telegram.org/bot${TELEGRAM_TOKEN}"

    if [ "$NOTIFY_ATTACH_LOG" = "true" ] && [ -f "$LOG_FILE" ]; then
        curl -sf -X POST "${api}/sendDocument" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "caption=${text}" \
            -F "document=@${LOG_FILE}" \
            > /dev/null 2>&1 \
            && log "📨 Telegram: sent with log attachment." \
            || log "⚠️  WARNING: Telegram delivery failed."
    else
        curl -sf -X POST "${api}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${text}\"}" \
            > /dev/null 2>&1 \
            && log "📨 Telegram: sent." \
            || log "⚠️  WARNING: Telegram delivery failed."
    fi
}

send_ntfy() {
    [ "$NTFY_ENABLED" != "true" ] && return 0
    if [ -z "$NTFY_URL" ] || [ -z "$NTFY_TOPIC" ]; then
        log "⚠️  WARNING: ntfy enabled but URL or TOPIC missing — skipping"
        return 1
    fi

    local text priority=3
    text=$(build_text_summary)
    { [ $failed_backups -gt 0 ] || [ $verify_err -gt 0 ]; } && priority=5

    if [ "$NOTIFY_ATTACH_LOG" = "true" ] && [ -f "$LOG_FILE" ]; then
        curl -sf -X PUT "${NTFY_URL}/${NTFY_TOPIC}" \
            -H "Title: KDD Backup — ${SERVER_NAME}" \
            -H "Priority: ${priority}" \
            -H "Filename: $(basename "$LOG_FILE")" \
            --data-binary "@${LOG_FILE}" \
            > /dev/null 2>&1 \
            && log "📨 ntfy: sent with log attachment." \
            || log "⚠️  WARNING: ntfy delivery failed."
    else
        curl -sf -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
            -H "Title: KDD Backup — ${SERVER_NAME}" \
            -H "Priority: ${priority}" \
            -d "$text" \
            > /dev/null 2>&1 \
            && log "📨 ntfy: sent." \
            || log "⚠️  WARNING: ntfy delivery failed."
    fi
}

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------

rotate_backups() {
    local target="$1"
    find "$target" -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
}

_do_verify() {
    local db_type="$1"   # mysql | postgres | mongo
    local gz_file="$2"
    local target_dir="$3"
    local result=""

    case "$db_type" in
        mysql)    result=$(verify_mysql_backup   "$gz_file" "$target_dir") ;;
        postgres) result=$(verify_postgres_backup "$gz_file" "$target_dir") ;;
        mongo)    result=$(verify_mongo_backup   "$gz_file" "$target_dir") ;;
    esac
    echo "$result"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

init_log

log "🚀 KDD - Starting backup"
log "⚙️  Retention: $RETENTION_DAYS days | Size drop warn threshold: ${SIZE_DROP_WARN}%"
[ -n "$NETWORK_FILTER" ] && log "🌐 Network filter: $NETWORK_FILTER"

[ ! -f "$CONFIG" ] && log_error "config.yaml not found" && exit 1

mkdir -p "$BACKUPS_DIR"

total_backups=0
failed_backups=0
verify_ok=0
verify_warn=0
verify_err=0
backup_details=""
# per-type counters for push summary
mysql_ok=0;  mysql_fail=0
pg_ok=0;     pg_fail=0
mongo_ok=0;  mongo_fail=0

# -----------------------------------------------------------------------------
# MYSQL
# -----------------------------------------------------------------------------

mysql_count=$(yq e '.mysql | length' "$CONFIG")

if [ "$mysql_count" -gt 0 ]; then
    log "🗄️  Processing MySQL/MariaDB ($mysql_count databases)"

    for i in $(seq 0 $((mysql_count-1))); do
        name=$(yq e ".mysql[$i].name" "$CONFIG")
        host=$(yq e ".mysql[$i].host" "$CONFIG")
        port=$(yq e ".mysql[$i].port" "$CONFIG")
        user=$(yq e ".mysql[$i].user" "$CONFIG")
        pass=$(yq e ".mysql[$i].password" "$CONFIG")
        db=$(yq e ".mysql[$i].dbname" "$CONFIG")
        network=$(yq e ".mysql[$i].network" "$CONFIG")

        if [ -n "$NETWORK_FILTER" ] && [ "$network" != "$NETWORK_FILTER" ]; then
            log "  ⏭️  Skipping $name (network: $network, filter: $NETWORK_FILTER)"
            continue
        fi

        target="$BACKUPS_DIR/$name"
        mkdir -p "$target"
        filepath="$target/dump-${TIMESTAMP}.sql.gz"

        log "  📦 Backing up: $name"

        if mysqldump -h "$host" -P "$port" -u "$user" -p"$pass" \
            --single-transaction --routines --triggers --events \
            "$db" 2>/dev/null | gzip > "$filepath"; then

            size=$(du -h "$filepath" | cut -f1)
            log "    ✅ Backup OK: $size"
            ((total_backups++)); ((mysql_ok++))

            log "    🔍 Verifying: $name"
            verify_result=$(_do_verify "mysql" "$filepath" "$target")
            verify_code="${verify_result%%:*}"
            log "    Verify: $verify_result"

            case "$verify_code" in
                OK)   ((verify_ok++)) ;;
                WARN) ((verify_warn++)) ;;
                FAIL) ((verify_err++)) ;;
            esac

            backup_details+=$(add_db_to_report "$name" "MySQL" "success" "$size" "$verify_result")
            rotate_backups "$target"
        else
            log_error "  ❌ Failed: $name"
            ((failed_backups++)); ((mysql_fail++))
            backup_details+=$(add_db_to_report "$name" "MySQL" "failed" "N/A" "skipped")
            rm -f "$filepath"
        fi
    done
fi

# -----------------------------------------------------------------------------
# POSTGRESQL
# -----------------------------------------------------------------------------

pg_count=$(yq e '.postgres | length' "$CONFIG")

if [ "$pg_count" -gt 0 ]; then
    log "🗄️  Processing PostgreSQL ($pg_count databases)"

    for i in $(seq 0 $((pg_count-1))); do
        name=$(yq e ".postgres[$i].name" "$CONFIG")
        host=$(yq e ".postgres[$i].host" "$CONFIG")
        port=$(yq e ".postgres[$i].port" "$CONFIG")
        user=$(yq e ".postgres[$i].user" "$CONFIG")
        pass=$(yq e ".postgres[$i].password" "$CONFIG")
        db=$(yq e ".postgres[$i].dbname" "$CONFIG")
        network=$(yq e ".postgres[$i].network" "$CONFIG")

        if [ -n "$NETWORK_FILTER" ] && [ "$network" != "$NETWORK_FILTER" ]; then
            log "  ⏭️  Skipping $name (network: $network, filter: $NETWORK_FILTER)"
            continue
        fi

        target="$BACKUPS_DIR/$name"
        mkdir -p "$target"
        filepath="$target/dump-${TIMESTAMP}.sql.gz"

        log "  📦 Backing up: $name"

        export PGPASSWORD="$pass"

        if pg_dump -h "$host" -p "$port" -U "$user" -d "$db" \
            --no-password --clean --if-exists 2>/dev/null | gzip > "$filepath"; then

            size=$(du -h "$filepath" | cut -f1)
            log "    ✅ Backup OK: $size"
            ((total_backups++)); ((pg_ok++))

            log "    🔍 Verifying: $name"
            verify_result=$(_do_verify "postgres" "$filepath" "$target")
            verify_code="${verify_result%%:*}"
            log "    Verify: $verify_result"

            case "$verify_code" in
                OK)   ((verify_ok++)) ;;
                WARN) ((verify_warn++)) ;;
                FAIL) ((verify_err++)) ;;
            esac

            backup_details+=$(add_db_to_report "$name" "PostgreSQL" "success" "$size" "$verify_result")
            rotate_backups "$target"
        else
            log_error "  ❌ Failed: $name"
            ((failed_backups++)); ((pg_fail++))
            backup_details+=$(add_db_to_report "$name" "PostgreSQL" "failed" "N/A" "skipped")
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
    log "🗄️  Processing MongoDB ($mongo_count databases)"

    for i in $(seq 0 $((mongo_count-1))); do
        name=$(yq e ".mongo[$i].name" "$CONFIG")
        host=$(yq e ".mongo[$i].host" "$CONFIG")
        port=$(yq e ".mongo[$i].port" "$CONFIG")
        user=$(yq e ".mongo[$i].user" "$CONFIG")
        pass=$(yq e ".mongo[$i].password" "$CONFIG")
        authdb=$(yq e ".mongo[$i].authdb" "$CONFIG")
        db=$(yq e ".mongo[$i].dbname" "$CONFIG")
        network=$(yq e ".mongo[$i].network" "$CONFIG")

        if [ -n "$NETWORK_FILTER" ] && [ "$network" != "$NETWORK_FILTER" ]; then
            log "  ⏭️  Skipping $name (network: $network, filter: $NETWORK_FILTER)"
            continue
        fi

        target="$BACKUPS_DIR/$name"
        mkdir -p "$target"
        filepath="$target/dump-${TIMESTAMP}.archive.gz"

        log "  📦 Backing up: $name"

        if mongodump --host="$host" --port="$port" --username="$user" \
            --password="$pass" --authenticationDatabase="$authdb" \
            --db="$db" --archive="$filepath" --gzip 2>/dev/null && [ -s "$filepath" ]; then

            size=$(du -h "$filepath" | cut -f1)
            log "    ✅ Backup OK: $size"
            ((total_backups++)); ((mongo_ok++))

            log "    🔍 Verifying: $name"
            verify_result=$(_do_verify "mongo" "$filepath" "$target")
            verify_code="${verify_result%%:*}"
            log "    Verify: $verify_result"

            case "$verify_code" in
                OK)   ((verify_ok++)) ;;
                WARN) ((verify_warn++)) ;;
                FAIL) ((verify_err++)) ;;
            esac

            backup_details+=$(add_db_to_report "$name" "MongoDB" "success" "$size" "$verify_result")
            rotate_backups "$target"
        else
            log_error "  ❌ Failed: $name"
            ((failed_backups++)); ((mongo_fail++))
            backup_details+=$(add_db_to_report "$name" "MongoDB" "failed" "N/A" "skipped")
            rm -f "$filepath"
        fi
    done
fi

# -----------------------------------------------------------------------------
# LOG RETENTION — same policy as backups
# -----------------------------------------------------------------------------

log "🧹 Removing logs older than $RETENTION_DAYS days..."
DELETED_LOGS=0
while IFS= read -r -d '' old_log; do
    rm -f "$old_log"
    ((DELETED_LOGS++))
done < <(
    find "$LOG_DIR" -type f -name "backup_*.log" \
        -mtime +"$((RETENTION_DAYS - 1))" -print0 2>/dev/null
)
log "🧹 Removed $DELETED_LOGS log(s)."

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------

total=$((total_backups + failed_backups))

log "✅ Backup completed — Success: $total_backups | Failed: $failed_backups"
log "🔍 Verify — OK: $verify_ok | Warn: $verify_warn | Fail: $verify_err"

if [ "$ENABLE_EMAIL" = "true" ]; then
    html_report=$(generate_html_report "$total" "$failed_backups")
    html_report+="$backup_details"
    html_report+=$(close_html_report "$verify_ok" "$verify_warn" "$verify_err")

    if [ $failed_backups -eq 0 ] && [ $verify_err -eq 0 ] && [ $verify_warn -eq 0 ]; then
        subject="[✅ SUCCESS] ${SERVER_NAME} Backup - $TIMESTAMP"
    elif [ $failed_backups -eq 0 ] && [ $verify_err -eq 0 ] && [ $verify_warn -gt 0 ]; then
        subject="[⚠️ WARN] ${SERVER_NAME} Backup - $TIMESTAMP"
    elif [ $total_backups -eq 0 ]; then
        subject="[❌ FAILED] ${SERVER_NAME} Backup - $TIMESTAMP"
    else
        subject="[⚠️ PARTIAL] ${SERVER_NAME} Backup - $TIMESTAMP"
    fi

    send_email "$subject" "$html_report"
fi

send_telegram
send_ntfy

[ $failed_backups -gt 0 ] && exit 1
exit 0