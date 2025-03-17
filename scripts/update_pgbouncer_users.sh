#!/bin/bash

# Script to update PgBouncer users from PostgreSQL
# This script creates a userlist.txt file for PgBouncer based on PostgreSQL users

# Log file
LOG_FILE="/var/log/dbhub/pgbouncer_update.log"
PGBOUNCER_USERLIST_FILE="/etc/pgbouncer/userlist.txt"
PGBOUNCER_CONFIG_FILE="/etc/pgbouncer/pgbouncer.ini"

# Ensure log directory exists
mkdir -p $(dirname $LOG_FILE)
touch $LOG_FILE

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log "This script must be run as root"
    exit 1
fi

# Check if PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
    log "PostgreSQL is not running. Cannot update PgBouncer users."
    exit 1
fi

# Check if PgBouncer is installed
if ! command -v pgbouncer &> /dev/null; then
    log "PgBouncer is not installed. Please install it first."
    exit 1
fi

# Create backup of existing userlist file
if [ -f "$PGBOUNCER_USERLIST_FILE" ]; then
    BACKUP_FILE="${PGBOUNCER_USERLIST_FILE}.$(date +%Y%m%d%H%M%S).bak"
    cp "$PGBOUNCER_USERLIST_FILE" "$BACKUP_FILE"
    log "Created backup of userlist file: $BACKUP_FILE"
fi

# Generate new userlist file
log "Generating new PgBouncer userlist file"

# Create temporary file
TEMP_USERLIST=$(mktemp)

# Add header
echo "# PgBouncer userlist file - Generated on $(date)" > "$TEMP_USERLIST"
echo "# username password" >> "$TEMP_USERLIST"

# Get users and passwords from PostgreSQL
sudo -u postgres psql -t -c "SELECT usename, passwd FROM pg_shadow WHERE passwd IS NOT NULL" | while read -r user password; do
    # Remove leading/trailing whitespace
    user=$(echo "$user" | xargs)
    password=$(echo "$password" | xargs)
    
    if [ -n "$user" ] && [ -n "$password" ]; then
        echo "\"$user\" \"$password\"" >> "$TEMP_USERLIST"
        log "Added user: $user"
    fi
done

# Move temporary file to final location
mv "$TEMP_USERLIST" "$PGBOUNCER_USERLIST_FILE"
chown postgres:postgres "$PGBOUNCER_USERLIST_FILE"
chmod 640 "$PGBOUNCER_USERLIST_FILE"

log "PgBouncer userlist file updated: $PGBOUNCER_USERLIST_FILE"

# Check if PgBouncer is running and reload if it is
if systemctl is-active --quiet pgbouncer; then
    log "Reloading PgBouncer configuration"
    systemctl reload pgbouncer
    log "PgBouncer configuration reloaded"
else
    log "PgBouncer is not running. Start it with: systemctl start pgbouncer"
fi

log "PgBouncer user update completed successfully"
exit 0 