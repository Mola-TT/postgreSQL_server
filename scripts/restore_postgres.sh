#!/bin/bash

# PostgreSQL Restore Script
# This script restores PostgreSQL databases from backups

# Configuration
BACKUP_DIR="/var/backups/postgresql"
LOG_FILE="/var/log/dbhub/restore.log"
HOSTNAME=$(hostname)

# Ensure log directory exists
mkdir -p $(dirname $LOG_FILE)
touch $LOG_FILE

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
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
    SUBJECT="$HOSTNAME Alert: $1"
    MESSAGE="$2"
    
    if [ -n "$EMAIL_RECIPIENT" ] && [ -n "$EMAIL_SENDER" ] && [ -n "$SMTP_SERVER" ] && [ -n "$SMTP_PORT" ] && [ -n "$SMTP_USER" ] && [ -n "$SMTP_PASS" ]; then
        log "Sending email alert: $SUBJECT"
        curl --ssl-reqd \
            --url "smtps://$SMTP_SERVER:$SMTP_PORT" \
            --user "$SMTP_USER:$SMTP_PASS" \
            --mail-from "$EMAIL_SENDER" \
            --mail-rcpt "$EMAIL_RECIPIENT" \
            --upload-file - << EOF
From: Database Restore <$EMAIL_SENDER>
To: Admin <$EMAIL_RECIPIENT>
Subject: $SUBJECT

$MESSAGE

Timestamp: $(date +'%Y-%m-%d %H:%M:%S')
Hostname: $HOSTNAME
EOF
    else
        log "Email configuration not found. Alert not sent: $SUBJECT"
    fi
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log "This script must be run as root"
    exit 1
fi

# Check if PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
    log "PostgreSQL is not running. Cannot perform restore."
    send_alert "Restore Failed" "PostgreSQL service is not running. Restore could not be performed."
    exit 1
fi

# Function to list available backups
list_backups() {
    log "Listing available backups"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        log "Backup directory does not exist: $BACKUP_DIR"
        return 1
    fi
    
    echo "Available backup dates:"
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" | sort -r | while read backup_date; do
        date_dir=$(basename "$backup_date")
        echo "  $date_dir"
    done
    
    echo ""
    echo "Use 'latest' to restore from the most recent backup"
}

# Function to list databases in a backup
list_databases_in_backup() {
    local backup_date="$1"
    
    if [ "$backup_date" == "latest" ] && [ -L "$BACKUP_DIR/latest" ]; then
        backup_date=$(basename $(readlink -f "$BACKUP_DIR/latest"))
    fi
    
    local backup_path="$BACKUP_DIR/$backup_date"
    
    if [ ! -d "$backup_path" ]; then
        log "Backup directory does not exist: $backup_path"
        return 1
    fi
    
    echo "Databases in backup $backup_date:"
    find "$backup_path" -name "*.sql.gz" | grep -v "globals_" | while read backup_file; do
        filename=$(basename "$backup_file")
        db_name=$(echo "$filename" | cut -d'_' -f1)
        echo "  $db_name"
    done
}

# Function to restore a database
restore_database() {
    local backup_date="$1"
    local db_name="$2"
    local new_db_name="${3:-$db_name}"
    
    if [ "$backup_date" == "latest" ] && [ -L "$BACKUP_DIR/latest" ]; then
        backup_date=$(basename $(readlink -f "$BACKUP_DIR/latest"))
    fi
    
    local backup_path="$BACKUP_DIR/$backup_date"
    
    if [ ! -d "$backup_path" ]; then
        log "Backup directory does not exist: $backup_path"
        send_alert "Restore Failed" "Backup directory does not exist: $backup_path"
        return 1
    fi
    
    # Find the backup file for the specified database
    local backup_file=$(find "$backup_path" -name "${db_name}_*.sql.gz" | sort | tail -n 1)
    
    if [ -z "$backup_file" ]; then
        log "No backup found for database $db_name in $backup_path"
        send_alert "Restore Failed" "No backup found for database $db_name in $backup_path"
        return 1
    fi
    
    log "Restoring database $db_name from $backup_file to $new_db_name"
    
    # Check if the target database exists
    local db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$new_db_name'")
    
    if [ "$db_exists" = "1" ]; then
        log "Database $new_db_name already exists. Dropping it."
        sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$new_db_name'"
        sudo -u postgres psql -c "DROP DATABASE \"$new_db_name\""
    fi
    
    # Create the new database
    log "Creating database $new_db_name"
    sudo -u postgres psql -c "CREATE DATABASE \"$new_db_name\""
    
    # Restore the database
    log "Restoring data to $new_db_name"
    if gunzip -c "$backup_file" | sudo -u postgres psql -d "$new_db_name"; then
        log "Successfully restored database $db_name to $new_db_name"
        send_alert "Restore Completed" "Successfully restored database $db_name to $new_db_name from backup $backup_date"
        return 0
    else
        log "Failed to restore database $db_name to $new_db_name"
        send_alert "Restore Failed" "Failed to restore database $db_name to $new_db_name from backup $backup_date"
        return 1
    fi
}

# Function to restore global objects (roles, tablespaces)
restore_globals() {
    local backup_date="$1"
    
    if [ "$backup_date" == "latest" ] && [ -L "$BACKUP_DIR/latest" ]; then
        backup_date=$(basename $(readlink -f "$BACKUP_DIR/latest"))
    fi
    
    local backup_path="$BACKUP_DIR/$backup_date"
    
    if [ ! -d "$backup_path" ]; then
        log "Backup directory does not exist: $backup_path"
        send_alert "Restore Failed" "Backup directory does not exist: $backup_path"
        return 1
    fi
    
    # Find the globals backup file
    local globals_file=$(find "$backup_path" -name "globals_*.sql.gz" | sort | tail -n 1)
    
    if [ -z "$globals_file" ]; then
        log "No globals backup found in $backup_path"
        send_alert "Restore Failed" "No globals backup found in $backup_path"
        return 1
    fi
    
    log "Restoring global objects from $globals_file"
    
    # Restore global objects
    if gunzip -c "$globals_file" | sudo -u postgres psql -d postgres; then
        log "Successfully restored global objects"
        send_alert "Restore Completed" "Successfully restored global objects from backup $backup_date"
        return 0
    else
        log "Failed to restore global objects"
        send_alert "Restore Failed" "Failed to restore global objects from backup $backup_date"
        return 1
    fi
}

# Display usage information
usage() {
    echo "PostgreSQL Restore Script"
    echo "Usage:"
    echo "  $0 list-backups                                  - List available backup dates"
    echo "  $0 list-databases <backup_date>                  - List databases in a specific backup"
    echo "  $0 restore-db <backup_date> <db_name> [new_name] - Restore a database (optionally to a new name)"
    echo "  $0 restore-globals <backup_date>                 - Restore global objects (roles, tablespaces)"
    echo "  $0 help                                          - Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0 list-backups"
    echo "  $0 list-databases latest"
    echo "  $0 restore-db latest mydb"
    echo "  $0 restore-db 2023-01-01_12-00-00 mydb mydb_restored"
    echo "  $0 restore-globals latest"
}

# Main script logic
case "$1" in
    list-backups)
        list_backups
        ;;
    list-databases)
        if [ $# -ne 2 ]; then
            echo "Error: Missing backup date"
            usage
            exit 1
        fi
        list_databases_in_backup "$2"
        ;;
    restore-db)
        if [ $# -lt 3 ]; then
            echo "Error: Missing arguments for restore-db"
            usage
            exit 1
        fi
        restore_database "$2" "$3" "$4"
        ;;
    restore-globals)
        if [ $# -ne 2 ]; then
            echo "Error: Missing backup date"
            usage
            exit 1
        fi
        restore_globals "$2"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Error: Unknown command '$1'"
        usage
        exit 1
        ;;
esac

exit 0 