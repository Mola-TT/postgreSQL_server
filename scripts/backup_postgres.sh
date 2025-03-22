#!/bin/bash

# PostgreSQL Backup Script
# This script creates backups of PostgreSQL databases with rotation and compression

# Configuration
BACKUP_DIR="/var/backups/postgres"
LOG_FILE="/var/log/dbhub/backup.log"
RETENTION_DAYS=7  # Number of days to keep backups
DATE=$(TZ=Asia/Singapore date +%Y-%m-%d_%H-%M-%S)
HOSTNAME=$(hostname)

# Ensure log directory exists
mkdir -p $(dirname $LOG_FILE)
touch $LOG_FILE

# Logging function
log() {
    echo "[$(TZ=Asia/Singapore date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Load environment variables for email configuration
for ENV_FILE in "./.env" "../.env" "/etc/dbhub/.env"; do
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        break
    fi
done

# Alert function
send_alert() {
    local subject="$1"
    local message="$2"
    
    # Prepare email content
    local email_content="Subject: [BACKUP ALERT] $subject
From: $EMAIL_SENDER
To: $EMAIL_RECIPIENT

$message

Hostname: $HOSTNAME
Timestamp: $(TZ=Asia/Singapore date +'%Y-%m-%d %H:%M:%S')
"
    
    if [ -n "$EMAIL_RECIPIENT" ] && [ -n "$EMAIL_SENDER" ] && [ -n "$SMTP_SERVER" ] && [ -n "$SMTP_PORT" ] && [ -n "$SMTP_USER" ] && [ -n "$SMTP_PASS" ]; then
        log "Sending email alert: $subject"
        curl --ssl-reqd \
            --url "smtps://$SMTP_SERVER:$SMTP_PORT" \
            --user "$SMTP_USER:$SMTP_PASS" \
            --mail-from "$EMAIL_SENDER" \
            --mail-rcpt "$EMAIL_RECIPIENT" \
            --upload-file - << EOF
$email_content
EOF
    else
        log "Email configuration not found. Alert not sent: $subject"
    fi
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log "This script must be run as root"
    exit 1
fi

# Check if PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
    log "PostgreSQL is not running. Cannot perform backup."
    send_alert "Backup Failed" "PostgreSQL service is not running. Backup could not be performed."
    exit 1
fi

# Create backup directory if it doesn't exist
if [ ! -d "$BACKUP_DIR" ]; then
    log "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
fi

# Create a directory for today's backup
DAILY_BACKUP_DIR="$BACKUP_DIR/$DATE"
mkdir -p "$DAILY_BACKUP_DIR"
chmod 700 "$DAILY_BACKUP_DIR"

log "Starting PostgreSQL backup to $DAILY_BACKUP_DIR"

# Get list of databases
DATABASES=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';")

# Backup each database
for DB in $DATABASES; do
    DB=$(echo $DB | tr -d ' ')
    BACKUP_FILE="$DAILY_BACKUP_DIR/${DB}_${DATE}.sql.gz"
    
    log "Backing up database: $DB"
    
    # Perform the backup with compression
    if sudo -u postgres pg_dump "$DB" | gzip > "$BACKUP_FILE"; then
        log "Successfully backed up database: $DB to $BACKUP_FILE"
        chmod 600 "$BACKUP_FILE"
    else
        ERROR_MSG="Failed to backup database: $DB"
        log "$ERROR_MSG"
        send_alert "Backup Failed" "$ERROR_MSG"
    fi
done

# Backup global objects (roles, tablespaces)
GLOBALS_BACKUP_FILE="$DAILY_BACKUP_DIR/globals_${DATE}.sql.gz"
log "Backing up global objects"

if sudo -u postgres pg_dumpall --globals-only | gzip > "$GLOBALS_BACKUP_FILE"; then
    log "Successfully backed up global objects to $GLOBALS_BACKUP_FILE"
    chmod 600 "$GLOBALS_BACKUP_FILE"
else
    ERROR_MSG="Failed to backup global objects"
    log "$ERROR_MSG"
    send_alert "Backup Failed" "$ERROR_MSG"
fi

# Create a symlink to the latest backup
LATEST_LINK="$BACKUP_DIR/latest"
if [ -L "$LATEST_LINK" ]; then
    rm "$LATEST_LINK"
fi
ln -s "$DAILY_BACKUP_DIR" "$LATEST_LINK"

# Remove old backups
log "Removing backups older than $RETENTION_DAYS days"
find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +$RETENTION_DAYS -exec rm -rf {} \;

# Calculate total backup size
TOTAL_SIZE=$(du -sh "$DAILY_BACKUP_DIR" | cut -f1)
log "Backup completed. Total size: $TOTAL_SIZE"

# Send success notification
send_alert "Backup Completed" "PostgreSQL backup completed successfully.\n\nTotal backup size: $TOTAL_SIZE\nBackup location: $DAILY_BACKUP_DIR\n\nDatabases backed up:\n$(echo "$DATABASES" | tr '\n' ' ')"

exit 0 