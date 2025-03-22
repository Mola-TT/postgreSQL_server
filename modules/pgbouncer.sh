# PgBouncer Module

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
        # Use PostgreSQL's built-in password encryption for PgBouncer
        log "Using PostgreSQL's password encryption for PgBouncer"
        
        # Create temporary SQL file for secure password generation
        TMP_SQL=$(mktemp)
        cat > "$TMP_SQL" << EOF
SELECT 'postgres' AS username, concat('md5', md5('$PG_PASSWORD' || 'postgres')) AS password;
EOF
        
        if [ "$CREATE_DEMO_DB" = "true" ] && [ -n "$DEMO_DB_USER" ] && [ -n "$DEMO_DB_PASSWORD" ]; then
            cat >> "$TMP_SQL" << EOF
SELECT '$DEMO_DB_USER' AS username, concat('md5', md5('$DEMO_DB_PASSWORD' || '$DEMO_DB_USER')) AS password;
EOF
        fi
        
        # Generate userlist using PostgreSQL
        sudo -u postgres psql -t -f "$TMP_SQL" | while read -r username password; do
            # Clean up username and password
            username=$(echo "$username" | tr -d ' ')
            password=$(echo "$password" | tr -d ' ')
            
            # Add to userlist file
            echo "\"$username\" \"$password\"" >> "$PGB_USERS_FILE.new"
        done
        
        # Check if new userlist file was created successfully
        if [ -s "$PGB_USERS_FILE.new" ]; then
            mv "$PGB_USERS_FILE.new" "$PGB_USERS_FILE"
        else
            log "ERROR: Failed to generate PgBouncer userlist"
            # Fallback to basic method if PostgreSQL method fails
            generate_pgbouncer_userlist_basic
        fi
        
        # Clean up
        rm -f "$TMP_SQL"
    else
        log "PostgreSQL is not running, using basic password encryption method"
        generate_pgbouncer_userlist_basic
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

# Function to generate basic PgBouncer userlist
generate_pgbouncer_userlist_basic() {
    log "Generating basic PgBouncer userlist"
    
    # Generate MD5 hash for postgres user
    local postgres_md5=$(echo -n "$PG_PASSWORD$postgres" | md5sum | cut -d ' ' -f 1)
    echo "\"postgres\" \"md5$postgres_md5\"" > "$PGB_USERS_FILE"
    
    # Add demo user if enabled
    if [ "$CREATE_DEMO_DB" = "true" ] && [ -n "$DEMO_DB_USER" ] && [ -n "$DEMO_DB_PASSWORD" ]; then
        local demo_md5=$(echo -n "$DEMO_DB_PASSWORD$DEMO_DB_USER" | md5sum | cut -d ' ' -f 1)
        echo "\"$DEMO_DB_USER\" \"md5$demo_md5\"" >> "$PGB_USERS_FILE"
    fi
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

# Get list of PostgreSQL users and their passwords using a more secure method
log "Retrieving PostgreSQL users"

# Create temporary SQL file
TMP_SQL=$(mktemp)
cat > "$TMP_SQL" << EOSQL
SELECT usename, 
       CASE WHEN substr(passwd, 1, 3) = 'md5' 
            THEN passwd 
            ELSE concat('md5', md5(passwd || usename)) 
       END AS password
FROM pg_shadow;
EOSQL

# Execute SQL and process results
sudo -u postgres psql -t -f "$TMP_SQL" | while read -r user password; do
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

# Clean up
rm -f "$TMP_SQL"

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
    
    # Use PostgreSQL to generate secure password hash if available
    if pg_isready -q; then
        local secure_password=$(sudo -u postgres psql -t -c "SELECT concat('md5', md5('$password' || '$username'))")
        secure_password=$(echo "$secure_password" | tr -d ' ')
        
        # Check if user already exists in userlist
        if grep -q "\"$username\"" "$PGB_USERS_FILE"; then
            # Update existing user
            sed -i "s/\"$username\".*$/\"$username\" \"$secure_password\"/" "$PGB_USERS_FILE"
        else
            # Add new user
            echo "\"$username\" \"$secure_password\"" >> "$PGB_USERS_FILE"
        fi
    else
        # Fallback to basic method if PostgreSQL is not available
        local md5_password=$(echo -n "$password$username" | md5sum | cut -d ' ' -f 1)
        
        # Check if user already exists in userlist
        if grep -q "\"$username\"" "$PGB_USERS_FILE"; then
            # Update existing user
            sed -i "s/\"$username\".*$/\"$username\" \"md5$md5_password\"/" "$PGB_USERS_FILE"
        else
            # Add new user
            echo "\"$username\" \"md5$md5_password\"" >> "$PGB_USERS_FILE"
        fi
    fi
    
    # Reload PgBouncer if it's running
    if systemctl is-active pgbouncer > /dev/null 2>&1; then
        log "Reloading PgBouncer"
        systemctl reload pgbouncer || systemctl restart pgbouncer
    fi
} 