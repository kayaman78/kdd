# Email Notifications Setup Guide - DDD

Complete guide to configure email notifications for database backup reports in DockerDatabaseDumper (DDD).

## Features

- HTML email reports with color-coded status (green/yellow/red)
- Detailed backup statistics and database-level results
- Support for authenticated and non-authenticated SMTP
- SSL/TLS/STARTTLS support
- Multiple recipients
- Automatic email on backup completion

## Email Report Preview

The email report includes:
- **Status Banner**: Green (success), Yellow (partial), Red (failed)
- **Summary Grid**: Total databases, successful, failed, retention days
- **Database Details**: Individual status for each database with size and timestamp
- **Disk Usage**: Total backup directory size
- **Timestamp**: Exact backup execution time

## Configuration Options

### Basic Configuration

Minimum required parameters:

```bash
--enable-email \
--smtp-host smtp.example.com \
--smtp-from backups@example.com \
--smtp-to admin@example.com
```

### Full Configuration

All available parameters:

```bash
--enable-email \
--smtp-host smtp.gmail.com \
--smtp-port 587 \
--smtp-user your-email@gmail.com \
--smtp-pass your-app-password \
--smtp-from backups@example.com \
--smtp-to admin@example.com \
--smtp-to monitor@example.com \
--smtp-tls auto
```

## SMTP Provider Examples

### Gmail

**Requirements:**
- Enable 2-Factor Authentication
- Generate App Password: https://myaccount.google.com/apppasswords

```bash
docker run --rm \
  -v $(pwd)/config:/config:ro \
  -v $(pwd)/dump:/backups \
  --network bridge \
  ddd:latest /app/backup.sh \
  --enable-email \
  --smtp-host smtp.gmail.com \
  --smtp-port 587 \
  --smtp-user your-email@gmail.com \
  --smtp-pass your-app-password \
  --smtp-from your-email@gmail.com \
  --smtp-to recipient@example.com \
  --smtp-tls on
```

### Office 365 / Outlook

```bash
--enable-email \
--smtp-host smtp.office365.com \
--smtp-port 587 \
--smtp-user your-email@outlook.com \
--smtp-pass your-password \
--smtp-from your-email@outlook.com \
--smtp-to recipient@example.com \
--smtp-tls on
```

### SendGrid

```bash
--enable-email \
--smtp-host smtp.sendgrid.net \
--smtp-port 587 \
--smtp-user apikey \
--smtp-pass your-sendgrid-api-key \
--smtp-from verified-sender@yourdomain.com \
--smtp-to recipient@example.com \
--smtp-tls on
```

### Mailgun

```bash
--enable-email \
--smtp-host smtp.mailgun.org \
--smtp-port 587 \
--smtp-user postmaster@yourdomain.mailgun.org \
--smtp-pass your-mailgun-password \
--smtp-from backups@yourdomain.com \
--smtp-to recipient@example.com \
--smtp-tls on
```

### Amazon SES

```bash
--enable-email \
--smtp-host email-smtp.us-east-1.amazonaws.com \
--smtp-port 587 \
--smtp-user your-ses-smtp-username \
--smtp-pass your-ses-smtp-password \
--smtp-from verified@yourdomain.com \
--smtp-to recipient@example.com \
--smtp-tls on
```

### Local/Corporate SMTP (No Authentication)

```bash
--enable-email \
--smtp-host mail.company.local \
--smtp-port 25 \
--smtp-from backups@company.local \
--smtp-to sysadmin@company.local \
--smtp-tls off
```

## TLS/SSL Options

| Value | Description | Use Case |
|-------|-------------|----------|
| `auto` | Automatic detection (default) | Most providers |
| `on` | Always use TLS | Gmail, Office365, most modern servers |
| `off` | No encryption | Local servers, testing |

## Multiple Recipients

Send to multiple people:

```bash
--smtp-to admin@example.com \
--smtp-to backup-team@example.com \
--smtp-to monitoring@example.com
```

## Cron Configuration with Email

### Basic Setup

Create wrapper script `/usr/local/bin/ddd-backup.sh`:

```bash
#!/bin/bash

docker run --rm \
  -e PUID=1000 \
  -e PGID=1000 \
  -v /srv/docker/ddd/config:/config:ro \
  -v /srv/docker/ddd/dump:/backups \
  -v /srv/docker:/srv/docker:ro \
  --network bridge \
  ddd:latest /app/backup.sh \
  --enable-email \
  --smtp-host smtp.gmail.com \
  --smtp-port 587 \
  --smtp-user backups@example.com \
  --smtp-pass "your-app-password" \
  --smtp-from backups@example.com \
  --smtp-to admin@example.com \
  --smtp-tls on
```

Make executable:
```bash
sudo chmod +x /usr/local/bin/ddd-backup.sh
```

### Environment Variables (More Secure)

Instead of hardcoding passwords, use environment file:

Create `/srv/docker/ddd/.env`:
```bash
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=backups@example.com
SMTP_PASS=your-app-password
SMTP_FROM=backups@example.com
SMTP_TO=admin@example.com
SMTP_TLS=on
```

Protect the file:
```bash
sudo chmod 600 /srv/docker/ddd/.env
```

Wrapper script:
```bash
#!/bin/bash
source /srv/docker/ddd/.env

docker run --rm \
  -e PUID=1000 \
  -e PGID=1000 \
  -v /srv/docker/ddd/config:/config:ro \
  -v /srv/docker/ddd/dump:/backups \
  -v /srv/docker:/srv/docker:ro \
  --network bridge \
  ddd:latest /app/backup.sh \
  --enable-email \
  --smtp-host "$SMTP_HOST" \
  --smtp-port "$SMTP_PORT" \
  --smtp-user "$SMTP_USER" \
  --smtp-pass "$SMTP_PASS" \
  --smtp-from "$SMTP_FROM" \
  --smtp-to "$SMTP_TO" \
  --smtp-tls "$SMTP_TLS"
```

### Cron Job

```bash
sudo crontab -e
```

Add:
```cron
# Daily backup at 3 AM with email notification
0 3 * * * /usr/local/bin/ddd-backup.sh >> /var/log/ddd-backup.log 2>&1
```

## Testing Email Configuration

Test email sending without running full backup:

```bash
# Quick test with verbose output
docker run --rm \
  -v $(pwd)/config:/config:ro \
  -v $(pwd)/dump:/backups \
  --network bridge \
  ddd:latest /app/backup.sh \
  --enable-email \
  --smtp-host smtp.gmail.com \
  --smtp-port 587 \
  --smtp-user your-email@gmail.com \
  --smtp-pass your-app-password \
  --smtp-from your-email@gmail.com \
  --smtp-to your-email@gmail.com \
  --smtp-tls on \
  --verbose
```

Check logs for SMTP errors:
```bash
# Inside container or after run
cat /tmp/msmtp.log
```

## Troubleshooting

### Problem: No Email Received

**Check:**
1. Verify SMTP credentials are correct
2. Check spam/junk folder
3. Review logs: `/tmp/msmtp.log`
4. Test with `--verbose` flag
5. Verify sender email is allowed to send (SPF/DKIM)

**Debug:**
```bash
# Check msmtp configuration
docker run --rm -it ddd:latest cat /tmp/.msmtprc

# Test SMTP connection manually
docker run --rm -it ddd:latest \
  msmtp --host=smtp.gmail.com --port=587 --tls=on --tls-starttls=on --debug
```

### Problem: Authentication Failed

**Solutions:**
- Gmail: Use App Password, not regular password
- Office365: Enable SMTP AUTH in admin center
- Corporate: Check if IP whitelisting is required
- Check username format (email vs username)

### Problem: TLS/SSL Errors

**Try different TLS modes:**
```bash
--smtp-tls auto    # Let msmtp decide
--smtp-tls on      # Force TLS
--smtp-tls off     # Disable TLS (not recommended)
```

### Problem: Email Sent but Not Formatted

**Check:**
- Email client supports HTML
- Not blocked by email security software
- Content-Type header is set correctly

### Problem: "Relay Access Denied"

**Solution:**
- Verify SMTP server allows sending from your IP
- Check if authentication is required
- Verify sender email is authorized

## Email Report Customization

The HTML email template is embedded in `backup.sh`. To customize:

1. Locate `generate_html_report()` function
2. Modify CSS styles:
   - Colors: Change hex codes (e.g., `#28a745` for green)
   - Fonts: Modify `font-family` values
   - Layout: Adjust padding, margins, grid
3. Add/remove sections as needed

## Security Best Practices

1. **Never commit passwords to git**
   - Use `.env` files (add to `.gitignore`)
   - Or use secrets management systems

2. **Protect configuration files**
   ```bash
   chmod 600 /srv/docker/db-backup/.env
   chmod 600 /srv/docker/db-backup/config/config.yaml
   ```

3. **Use App Passwords** instead of real passwords when available

4. **Enable 2FA** on email accounts used for notifications

5. **Monitor email logs** for unauthorized access attempts

6. **Use TLS** whenever possible (`--smtp-tls on`)

7. **Limit recipients** to only necessary people

## Advanced: Custom Email Templates

To use a completely custom HTML template:

1. Create template file: `/srv/docker/ddd/email-template.html`
2. Modify `generate_html_report()` to read from file
3. Use variables: `{{TOTAL}}`, `{{FAILED}}`, `{{TIMESTAMP}}`
4. Mount template file in docker run:
   ```bash
   -v /srv/docker/ddd/email-template.html:/app/email-template.html:ro
   ```

## Email Notification Flow

```
Backup Starts
     ↓
Execute Database Backups
     ↓
Track Success/Failure per DB
     ↓
Generate HTML Report
     ↓
Configure msmtp
     ↓
Send Email(s)
     ↓
Cleanup & Exit
```

## FAQ

**Q: Can I disable email for specific backups?**  
A: Yes, simply omit `--enable-email` flag when running backup.sh

**Q: Can I send to different emails based on success/failure?**  
A: Not currently. Use email filtering rules instead.

**Q: Does email affect backup performance?**  
A: Minimal impact. Email is sent after all backups complete.

**Q: Can I use a different email server per database?**  
A: No, one SMTP configuration per backup run.

**Q: What if email sending fails?**  
A: Backup still completes. Email failure is logged but doesn't stop backup.

**Q: Can I get email for successful backups only?**  
A: Not currently. Modify script to check `$failed_backups` before sending.

## Support

For email configuration issues:
- Check msmtp documentation: https://marlam.de/msmtp/
- Review SMTP provider documentation
- Test with standard email client first
- Open issue on GitHub with sanitized logs

---

**Remember**: Email notifications are optional. Backups work perfectly fine without them!