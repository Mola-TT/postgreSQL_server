#!/bin/bash

# PgBouncer installation and configuration functions

# Function to install PgBouncer
install_pgbouncer() {
    log "Installing PgBouncer"
    apt-get update
    apt-get install -y pgbouncer
}

# Function to configure PgBouncer
configure_pgbouncer() {
    log "Configuring PgBouncer"
    
    # Check if PgBouncer configuration directory exists
    PGB_CONF_DIR="/etc/pgbouncer"
    if [ ! -d "$PGB_CONF_DIR" ]; then
        log "Creating PgBouncer configuration directory: $PGB_CONF_DIR"
        mkdir -p "$PGB_CONF_DIR"
    fi
    
    # Check if PgBouncer is properly installed
    if ! command_exists pgbouncer; then
        log "PgBouncer not found, attempting to reinstall"
        apt-get install --reinstall -y pgbouncer
    fi
    
    # Backup PgBouncer configuration file
    PGB_CONF_FILE="$PGB_CONF_DIR/pgbouncer.ini"
    backup_file "$PGB_CONF_FILE"
    
    # Create PgBouncer configuration file
    log "Creating PgBouncer configuration file"
    cat > "$PGB_CONF_FILE" << EOF
[databases]
* = host=localhost port=5432

[pgbouncer]
listen_addr = *
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres
stats_users = postgres
pool_mode = transaction
server_reset_query = DISCARD ALL
max_client_conn = 1000
default_pool_size = 20
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
EOF
    
    # Create PgBouncer userlist file
    log "Creating PgBouncer userlist file"
    PGB_USERS_FILE="$PGB_CONF_DIR/userlist.txt"
    
    # Generate encrypted password for PgBouncer
    log "Generating encrypted password for PgBouncer"
    
    # Check if PostgreSQL is running before generating password
    if pg_isready -q; then
        # Generate MD5 hash for PgBouncer
        PG_MD5_PASSWORD=$(echo -n "$PG_PASSWORD$postgres" | md5sum | cut -d ' ' -f 1)
        echo "\"postgres\" \"md5$PG_MD5_PASSWORD\"" > "$PGB_USERS_FILE"
        
        # If demo database is enabled, add demo user to PgBouncer
        if [ "$CREATE_DEMO_DB" = "true" ]; then
            DEMO_MD5_PASSWORD=$(echo -n "$DEMO_DB_PASSWORD$DEMO_DB_USER" | md5sum | cut -d ' ' -f 1)
            echo "\"$DEMO_DB_USER\" \"md5$DEMO_MD5_PASSWORD\"" >> "$PGB_USERS_FILE"
        fi
    else
        # PostgreSQL is not running, create a basic userlist file
        log "PostgreSQL is not running, creating basic userlist file"
        echo "\"postgres\" \"md5$(echo -n "${PG_PASSWORD}postgres" | md5sum | cut -d ' ' -f 1)\"" > "$PGB_USERS_FILE"
        
        # Create a script to update the userlist file later
        create_pgbouncer_update_script
    fi
    
    # Set permissions for PgBouncer files
    chmod 640 "$PGB_CONF_FILE" "$PGB_USERS_FILE"
    chown postgres:postgres "$PGB_CONF_FILE" "$PGB_USERS_FILE"
    
    # Create PgBouncer update script
    create_pgbouncer_update_script
    
    # Create systemd timer for PgBouncer userlist update
    log "Creating systemd timer for PgBouncer userlist update"
    
    # Create systemd service file
    cat > /etc/systemd/system/pgbouncer-update.service << EOF
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
    
    # Create systemd timer file
    cat > /etc/systemd/system/pgbouncer-update.timer << EOF
[Unit]
Description=Run PgBouncer userlist update daily

[Timer]
OnBootSec=5min
OnUnitActiveSec=1d

[Install]
WantedBy=timers.target
EOF
    
    # Enable and start the timer
    systemctl daemon-reload
    systemctl enable pgbouncer-update.timer
    
    # Restart PgBouncer
    restart_service "pgbouncer"
}

# Function to create PgBouncer update script
create_pgbouncer_update_script() {
    log "Creating PgBouncer update script"
    
    # Create script to update PgBouncer userlist
    cat > /usr/local/bin/update_pgbouncer_users.sh << 'EOF'
#!/bin/bash

# Script to update PgBouncer userlist with PostgreSQL users

# Configuration
PG_VERSION=$(ls /etc/postgresql/ | sort -V | tail -n 1)
PGB_USERS_FILE="/etc/pgbouncer/userlist.txt"
LOG_FILE="/var/log/pgbouncer_update.log"

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if PostgreSQL is running
if ! pg_isready -q; then
    log "PostgreSQL is not running, cannot update PgBouncer userlist"
    exit 1
fi

# Create temporary file
TEMP_FILE=$(mktemp)

# Get list of PostgreSQL users and their passwords
log "Retrieving PostgreSQL users"
sudo -u postgres psql -t -c "SELECT usename, passwd FROM pg_shadow" | while read -r user password; do
    # Clean up user and password
    user=$(echo "$user" | tr -d ' ')
    password=$(echo "$password" | tr -d ' ')
    
    # Skip if user or password is empty
    if [ -z "$user" ] || [ -z "$password" ]; then
        continue
    fi
    
    # Add user to temporary file
    echo "\"$user\" \"$password\"" >> "$TEMP_FILE"
done

# Check if temporary file was created successfully
if [ ! -s "$TEMP_FILE" ]; then
    log "ERROR: Failed to retrieve PostgreSQL users"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Backup existing userlist file
if [ -f "$PGB_USERS_FILE" ]; then
    cp "$PGB_USERS_FILE" "${PGB_USERS_FILE}.bak"
fi

# Update userlist file
mv "$TEMP_FILE" "$PGB_USERS_FILE"
chown postgres:postgres "$PGB_USERS_FILE"
chmod 640 "$PGB_USERS_FILE"

log "PgBouncer userlist updated successfully"

# Reload PgBouncer if it's running
if systemctl is-active pgbouncer > /dev/null 2>&1; then
    log "Reloading PgBouncer"
    systemctl reload pgbouncer || systemctl restart pgbouncer
fi

exit 0
EOF
    
    # Make script executable
    chmod +x /usr/local/bin/update_pgbouncer_users.sh
}

# Function to add a user to PgBouncer
add_pgbouncer_user() {
    local username="$1"
    local password="$2"
    
    log "Adding user $username to PgBouncer"
    
    # Check if PgBouncer userlist file exists
    PGB_USERS_FILE="/etc/pgbouncer/userlist.txt"
    if [ ! -f "$PGB_USERS_FILE" ]; then
        log "Creating PgBouncer userlist file"
        touch "$PGB_USERS_FILE"
        chown postgres:postgres "$PGB_USERS_FILE"
        chmod 640 "$PGB_USERS_FILE"
    fi
    
    # Generate MD5 hash for PgBouncer
    local md5_password=$(echo -n "$password$username" | md5sum | cut -d ' ' -f 1)
    
    # Check if user already exists in userlist
    if grep -q "\"$username\"" "$PGB_USERS_FILE"; then
        # Update existing user
        sed -i "s/\"$username\".*$/\"$username\" \"md5$md5_password\"/" "$PGB_USERS_FILE"
    else
        # Add new user
        echo "\"$username\" \"md5$md5_password\"" >> "$PGB_USERS_FILE"
    fi
    
    # Reload PgBouncer if it's running
    if systemctl is-active pgbouncer > /dev/null 2>&1; then
        log "Reloading PgBouncer"
        systemctl reload pgbouncer || systemctl restart pgbouncer
    fi
} 