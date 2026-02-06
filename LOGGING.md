# Logging and Monitoring Guide - DDD

Complete guide to logging, monitoring, and troubleshooting database backups in DockerDatabaseDumper (DDD).

## Log Files

### Primary Log File

**Location**: `/backups/backup.log` (inside container) or `dump/backup.log` (on host)

**Content**:
- Backup start/end timestamps
- Database-by-database execution details
- Success/failure status per database
- File sizes and locations
- Rotation operations
- Error messages and warnings

**Rotation**: Automatic when file exceeds 10MB (old log saved as `backup.log.old`)

### Custom Log Location

Specify custom log file path:

```bash
docker run --rm \
  -v $(pwd)/config:/config:ro \
  -v $(pwd)/dump:/backups \
  -v $(pwd)/logs:/logs \
  ddd:latest /app/backup.sh \
  --log-file /logs/custom-backup.log
```

### SMTP Log (Email)

**Location**: `/tmp/msmtp.log` (temporary, only when email is enabled)

**Content**:
- SMTP connection attempts
- Authentication status
- Email sending results
- TLS negotiation details

## Log Format

### Standard Log Entry

```
[2024-11-23 03:00:15] Backup MySQL: myapp (production_db)
[2024-11-23 03:00:18]   Created: dump-2024-11-23_03-00.sql.gz (245M)
```

### Debug Log Entry (with --verbose)

```
[2024-11-23 03:00:15] [DEBUG] Processing MySQL #0: myapp
[2024-11-23 03:00:15] [DEBUG] Executing: mysqldump -h myapp_db -P 3306 -u root
[2024-11-23 03:00:18] [DEBUG] Rotatiing backups for myapp (retention: 7 days)
[2024-11-23 03:00:18] [DEBUG] No old backups to remove
```

### Error Log Entry

```
[2024-11-23 03:00:20] [ERROR] Failed to backup analytics_db
[2024-11-23 03:00:20] [ERROR] Connection refused to host postgres_analytics:5432
```

## Monitoring

### Check Last Backup Status

```bash
# View last 50 lines of log
tail -50 /srv/docker/ddd/dump/backup.log

# Check if last backup was successful
tail -20 /srv/docker/ddd/dump/backup.log | grep -q "All backups completed successfully" && echo "OK" || echo "FAILED"

# Get backup statistics
tail -100 /srv/docker/ddd/dump/backup.log | grep "Statistics:"
```

### Monitor Backup Size Trends

```bash
# Total backup directory size
du -sh /srv/docker/ddd/dump/

# Size per database
du -sh /srv/docker/ddd/dump/*/

# Recent backup sizes
find /srv/docker/ddd/dump/ -name "dump-*.gz" -mtime -7 -exec du -h {} \; | sort
```

### Check Backup Age

```bash
# Find backups older than 24 hours
find /srv/docker/ddd/dump/ -name "dump-*.gz" -mtime +1

# Last backup timestamp per database
for db in /srv/docker/ddd/dump/*/; do
    echo "$(basename $db): $(ls -t $db/dump-*.gz 2>/dev/null | head -1 | xargs stat -c %y 2>/dev/null || echo 'No backups')"
done
```

## Centralized Logging

### Syslog Integration

Send logs to syslog:

```bash
# In cron script
docker run --rm \
  ... \
  ddd:latest /app/backup.sh 2>&1 | logger -t ddd-backup
```

View in syslog:
```bash
grep ddd-backup /var/log/syslog
```

### Log Aggregation (ELK, Splunk, etc.)

Mount log directory and configure external tools to ingest:

```bash
# Mount logs to accessible location
-v /var/log/db-backups:/backups/logs:rw
```

Then configure your log aggregation tool to monitor `/var/log/db-backups/`.

### Docker Logging Driver

Use Docker's logging capabilities:

```bash
docker run --rm \
  --log-driver=syslog \
  --log-opt syslog-address=tcp://logserver:514 \
  --log-opt tag="ddd-backup" \
  ...
  ddd:latest /app/backup.sh
```

## Alerting

### Email Alerts (Built-in)

Use the email notification feature (see [EMAIL_NOTIFICATIONS.md](EMAIL_NOTIFICATIONS.md)):

```bash
--enable-email \
--smtp-to alerts@example.com
```

### Monitoring Tools Integration

#### Healthchecks.io

Ping Healthchecks.io before/after backup:

```bash
#!/bin/bash
HC_UUID="your-healthchecks-uuid"

# Signal start
curl -m 10 --retry 5 https://hc-ping.com/${HC_UUID}/start

# Run backup
docker run --rm ... db-backup-tool:latest /app/backup.sh

# Signal success/failure
if [ $? -eq 0 ]; then
    curl -m 10 --retry 5 https://hc-ping.com/${HC_UUID}
else
    curl -m 10 --retry 5 https://hc-ping.com/${HC_UUID}/fail
fi
```

#### UptimeRobot / StatusCake

Create HTTP endpoint that checks backup status:

```bash
# Simple health check script
#!/bin/bash
BACKUP_LOG="/srv/docker/db-backup/dump/backup.log"

if [ ! -f "$BACKUP_LOG" ]; then
    echo "CRITICAL: No backup log found"
    exit 2
fi

LAST_BACKUP=$(tail -100 "$BACKUP_LOG" | grep "All backups completed successfully" | tail -1)

if [ -z "$LAST_BACKUP" ]; then
    echo "CRITICAL: Last backup failed"
    exit 2
fi

echo "OK: Backups running normally"
exit 0
```

#### Prometheus + Grafana

Export metrics using node_exporter's textfile collector:

```bash
#!/bin/bash
METRICS_FILE="/var/lib/node_exporter/textfile_collector/db_backup.prom"

# Run backup and capture stats
docker run --rm ... ddd:latest /app/backup.sh > /tmp/backup_output.log
EXIT_CODE=$?

# Parse log for statistics
SUCCESSFUL=$(grep "Successful backups:" /tmp/backup_output.log | awk '{print $NF}')
FAILED=$(grep "Failed backups:" /tmp/backup_output.log | awk '{print $NF}')

# Write Prometheus metrics
cat > "$METRICS_FILE" <<EOF
# HELP db_backup_last_run_timestamp Unix timestamp of last backup run
# TYPE db_backup_last_run_timestamp gauge
db_backup_last_run_timestamp $(date +%s)

# HELP db_backup_last_run_success Whether last backup was successful (1=yes, 0=no)
# TYPE db_backup_last_run_success gauge
db_backup_last_run_success $([ $EXIT_CODE -eq 0 ] && echo 1 || echo 0)

# HELP db_backup_databases_successful Number of successfully backed up databases
# TYPE db_backup_databases_successful gauge
db_backup_databases_successful ${SUCCESSFUL:-0}

# HELP db_backup_databases_failed Number of failed database backups
# TYPE db_backup_databases_failed gauge
db_backup_databases_failed ${FAILED:-0}
EOF
```

## Troubleshooting with Logs

### Common Issues

#### Issue: Permission Denied

**Log Entry:**
```
[ERROR] Failed to backup myapp
```

**Solution:**
```bash
# Check PUID/PGID match your user
id -u && id -g

# Verify file permissions
ls -ln /srv/docker/ddd/dump/
```

#### Issue: Network Connection Failed

**Log Entry:**
```
[ERROR] Connection refused to host db_container:3306
```

**Solution:**
```bash
# Verify container is running
docker ps | grep db_container

# Check network
docker inspect db_container | grep NetworkMode

# Test connectivity
docker run --rm --network bridge busybox ping -c 3 db_container
```

#### Issue: Authentication Failed

**Log Entry:**
```
[ERROR] Access denied for user 'root'@'%'
```

**Solution:**
```bash
# Verify credentials in config.yaml
cat /srv/docker/ddd/config/config.yaml

# Test credentials manually
docker exec db_container mysql -u root -pPASSWORD -e "SELECT 1"
```

#### Issue: Disk Space Full

**Log Entry:**
```
[ERROR] No space left on device
```

**Solution:**
```bash
# Check disk usage
df -h /srv/docker/ddd/dump/

# Remove old backups manually if needed
find /srv/docker/ddd/dump/ -name "dump-*.gz" -mtime +30 -delete

# Adjust retention period
--retention 3  # Keep only 3 days
```

### Enable Debug Mode

For detailed troubleshooting:

```bash
docker run --rm \
  -v $(pwd)/config:/config:ro \
  -v $(pwd)/dump:/backups \
  ddd:latest /app/backup.sh --verbose
```

Debug output includes:
- Exact commands being executed
- Detailed error messages
- Network operations
- File operations
- SMTP communication (if email enabled)

## Log Analysis

### Parse Success Rate

```bash
#!/bin/bash
LOGFILE="/srv/docker/ddd/dump/backup.log"

TOTAL=$(grep -c "Backup MySQL\|Backup PostgreSQL\|Backup MongoDB" "$LOGFILE")
SUCCESS=$(grep -c "Created: dump-" "$LOGFILE")
FAILED=$(grep -c "\[ERROR\] Failed to backup" "$LOGFILE")

echo "Total attempts: $TOTAL"
echo "Successful: $SUCCESS"
echo "Failed: $FAILED"
echo "Success rate: $(awk "BEGIN {printf \"%.2f\", ($SUCCESS/$TOTAL)*100}")%"
```

### Generate Weekly Report

```bash
#!/bin/bash
START_DATE=$(date -d '7 days ago' +%Y-%m-%d)
END_DATE=$(date +%Y-%m-%d)

echo "Backup Report: $START_DATE to $END_DATE"
echo "========================================"

# Extract relevant log entries
grep -E "\[$START_DATE|\[$END_DATE" /srv/docker/ddd/dump/backup.log | \
  grep -E "Statistics:|Created:|ERROR" | \
  while read line; do
    echo "$line"
  done

# Calculate total size backed up
TOTAL_SIZE=$(find /srv/docker/ddd/dump/ -name "dump-*.gz" -newermt "$START_DATE" -exec du -b {} + | awk '{sum+=$1} END {print sum/1024/1024/1024}')
echo ""
echo "Total data backed up: ${TOTAL_SIZE}GB"
```

## Best Practices

1. **Regular Log Review**: Check logs weekly for errors or warnings
2. **Monitor Disk Space**: Ensure backup directory has adequate space
3. **Test Restores**: Periodically verify backups can be restored
4. **Retention Policy**: Adjust based on disk space and compliance needs
5. **Email Alerts**: Enable for production environments
6. **Centralized Logging**: Use for enterprise deployments
7. **Metrics Collection**: Track trends over time
8. **Documentation**: Keep notes on any manual interventions

## Log Rotation Management

### Manual Log Rotation

```bash
#!/bin/bash
LOGFILE="/srv/docker/ddd/dump/backup.log"
MAX_SIZE_MB=50

SIZE=$(du -m "$LOGFILE" | cut -f1)

if [ $SIZE -gt $MAX_SIZE_MB ]; then
    mv "$LOGFILE" "$LOGFILE.$(date +%Y%m%d)"
    gzip "$LOGFILE.$(date +%Y%m%d)"
    touch "$LOGFILE"
    chmod 644 "$LOGFILE"
fi
```

### Logrotate Configuration

Create `/etc/logrotate.d/ddd-backup`:

```
/srv/docker/ddd/dump/backup.log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
}
```

## Security Considerations

1. **Protect log files**: `chmod 640 backup.log`
2. **Sanitize logs**: Ensure passwords aren't logged
3. **Secure transmission**: Use TLS for remote logging
4. **Access control**: Limit who can read logs
5. **Compliance**: Retain logs as required by policy

---

**Remember**: Logs are your best tool for troubleshooting. Enable verbose mode when investigating issues!