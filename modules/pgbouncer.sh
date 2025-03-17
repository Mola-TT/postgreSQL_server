#!/bin/bash

# PgBouncer installation and configuration functions

# Function to install PgBouncer
install_pgbouncer() {
    log "Installing PgBouncer"
    
    # Install PgBouncer
    apt-get install -y pgbouncer
}

# Function to configure PgBouncer
configure_pgbouncer() {
    log "Configuring PgBouncer"
    
    # Backup PgBouncer configuration file
    PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"
    backup_file "$PGBOUNCER_CONF"
    
    # Check if PgBouncer configuration directory exists
    if [ ! -d "/etc/pgbouncer" ]; then
        log "Creating PgBouncer configuration directory"
        mkdir -p /etc/pgbouncer
    fi
    
    # Check if PgBouncer is properly installed
    if ! command_exists "pgbouncer"; then
        log "PgBouncer not found, attempting to reinstall"
        apt-get install --reinstall -y pgbouncer
    fi
    
    # Create PgBouncer configuration file
    log "Creating PgBouncer configuration file"
    cat > "$PGBOUNCER_CONF" << EOF
[databases]
* = host=localhost port=5432

[pgbouncer]
listen_addr = *
listen_port = ${PGBOUNCER_PORT:-6432}
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres
stats_users = postgres
pool_mode = transaction
server_reset_query = DISCARD ALL
max_client_conn = ${MAX_CLIENT_CONN:-1000}
default_pool_size = ${DEFAULT_POOL_SIZE:-20}
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
max_db_connections = 50
max_user_connections = 50
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
stats_period = 60
ignore_startup_parameters = extra_float_digits
EOF

    # Create PgBouncer userlist file
    log "Creating PgBouncer userlist file"
    PGBOUNCER_USERLIST="/etc/pgbouncer/userlist.txt"
    
    # Generate encrypted password for PgBouncer
    if service_running "postgresql"; then
        log "Generating encrypted password for PgBouncer"
        
        # Create temporary SQL file
        TMP_SQL=$(mktemp)
        cat > "$TMP_SQL" << EOF
SELECT concat('"', usename, '" "', passwd, '"') FROM pg_shadow;
EOF
        
        # Generate userlist from PostgreSQL
        sudo -u postgres psql -f "$TMP_SQL" -t > "$PGBOUNCER_USERLIST"
        
        # Clean up
        rm "$TMP_SQL"
    else
        log "WARNING: PostgreSQL is not running, creating basic userlist"
        
        # Create basic userlist with postgres user
        echo "\"postgres\" \"$PG_PASSWORD\"" > "$PGBOUNCER_USERLIST"
    fi
    
    # Set proper permissions
    chown postgres:postgres "$PGBOUNCER_USERLIST"
    chmod 640 "$PGBOUNCER_USERLIST"
    
    # Create PgBouncer update script
    log "Creating PgBouncer update script"
    PGBOUNCER_UPDATE_SCRIPT="/usr/local/bin/update_pgbouncer_users.sh"
    
    cat > "$PGBOUNCER_UPDATE_SCRIPT" << 'EOF'
#!/bin/bash

# Script to update PgBouncer userlist from PostgreSQL

# Configuration
USERLIST_FILE="/etc/pgbouncer/userlist.txt"
LOG_FILE="/var/log/pgbouncer_update.log"

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Create log file if it doesn't exist
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

log "Updating PgBouncer userlist"

# Create temporary SQL file
TMP_SQL=$(mktemp)
cat > "$TMP_SQL" << EOSQL
SELECT concat('"', usename, '" "', passwd, '"') FROM pg_shadow;
EOSQL

# Generate userlist from PostgreSQL
if sudo -u postgres psql -f "$TMP_SQL" -t > "${USERLIST_FILE}.new"; then
    # Check if the new file is not empty
    if [ -s "${USERLIST_FILE}.new" ]; then
        # Replace the old file with the new one
        mv "${USERLIST_FILE}.new" "$USERLIST_FILE"
        chown postgres:postgres "$USERLIST_FILE"
        chmod 640 "$USERLIST_FILE"
        log "PgBouncer userlist updated successfully"
        
        # Reload PgBouncer if it's running
        if systemctl is-active pgbouncer > /dev/null 2>&1; then
            systemctl reload pgbouncer
            log "PgBouncer reloaded"
        fi
    else
        log "ERROR: Generated userlist is empty, keeping old file"
        rm "${USERLIST_FILE}.new"
    fi
else
    log "ERROR: Failed to generate userlist from PostgreSQL"
    rm "${USERLIST_FILE}.new" 2>/dev/null
fi

# Clean up
rm "$TMP_SQL"

log "PgBouncer userlist update completed"
EOF

    # Make the script executable
    chmod +x "$PGBOUNCER_UPDATE_SCRIPT"
    
    # Create systemd timer for PgBouncer userlist update
    log "Creating systemd timer for PgBouncer userlist update"
    
    # Create service file
    cat > "/etc/systemd/system/pgbouncer-update.service" << EOF
[Unit]
Description=Update PgBouncer userlist
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update_pgbouncer_users.sh
User=root

[Install]
WantedBy=multi-user.target
EOF

    # Create timer file
    cat > "/etc/systemd/system/pgbouncer-update.timer" << EOF
[Unit]
Description=Run PgBouncer userlist update every hour

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF

    # Enable and start the timer
    systemctl daemon-reload
    systemctl enable pgbouncer-update.timer
    systemctl start pgbouncer-update.timer
    
    # Restart PgBouncer to apply changes
    restart_service "pgbouncer"
} 