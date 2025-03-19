#!/bin/bash

# Server Initialization Script
# This script installs and configures PostgreSQL and PgBouncer

# SECURITY NOTICE: For sensitive information like passwords, use environment variables
# Create a .env file based on the template and source it before running this script

# Exit on error
set -e

# Error handler
error_handler() {
    echo "Error occurred at line $1"
    exit 1
}

# Set up error handling
trap 'error_handler $LINENO' ERR

# Configuration variables
PG_VERSION="17"  # Updated to PostgreSQL 17
DOMAIN_SUFFIX="example.com"
ENABLE_REMOTE_ACCESS=false

# Email settings for alerts
EMAIL_RECIPIENT="admin@example.com"
EMAIL_SENDER="dbserver@example.com"
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="smtp_user"
SMTP_PASS="smtp_password"
SMTP_USE_TLS="false"

# SSL certificate settings
SSL_CERT_VALIDITY=365
SSL_COUNTRY="US"
SSL_STATE="State"
SSL_LOCALITY="City"
SSL_ORGANIZATION="Organization"
SSL_COMMON_NAME="db.example.com"

# Log settings
LOG_DIR="/var/log/dbhub"
LOG_FILE="$LOG_DIR/server_init.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

# Logging function
log() {
    local timestamp=$(TZ=Asia/Singapore date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1"
    echo "[$timestamp] $1" >> "$LOG_FILE" 2>/dev/null || true
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a package is installed
package_installed() {
    dpkg -l "$1" | grep -q "^ii" >/dev/null 2>&1
}

# Function to check PostgreSQL logs for errors
check_postgresql_logs() {
    log "Checking PostgreSQL logs for errors"
    
    # Find the most recent PostgreSQL log file
    local log_files=$(find /var/log/postgresql -name "postgresql-*.log" -type f 2>/dev/null | sort -r)
    
    if [ -z "$log_files" ]; then
        log "No PostgreSQL log files found in /var/log/postgresql"
        
        # Check alternative locations
        log_files=$(find /var/lib/postgresql/$PG_VERSION/main/log -name "postgresql-*.log" -type f 2>/dev/null | sort -r)
        
        if [ -z "$log_files" ]; then
            log "No PostgreSQL log files found in alternative locations"
            return 1
        fi
    fi
    
    # Get the most recent log file
    local recent_log=$(echo "$log_files" | head -n 1)
    log "Most recent PostgreSQL log file: $recent_log"
    
    # Check for common error patterns
    if grep -q "could not bind IPv4 socket" "$recent_log"; then
        log "ERROR: PostgreSQL cannot bind to its port. Another process may be using port 5432."
        log "Checking for processes using port 5432..."
        if command_exists lsof; then
            lsof -i :5432 || log "No process found using port 5432 with lsof"
        fi
        if command_exists netstat; then
            netstat -tuln | grep 5432 || log "No process found using port 5432 with netstat"
        fi
    elif grep -q "could not access directory" "$recent_log"; then
        log "ERROR: PostgreSQL cannot access its data directory. Checking permissions..."
        ls -la /var/lib/postgresql/$PG_VERSION/main/
    elif grep -q "database system is shut down" "$recent_log"; then
        log "ERROR: PostgreSQL database system is shut down. Trying to initialize..."
        pg_ctlcluster $PG_VERSION main start || log "Failed to start PostgreSQL cluster with pg_ctlcluster"
    fi
    
    # Display the last 20 lines of the log
    log "Last 20 lines of PostgreSQL log:"
    tail -n 20 "$recent_log" | while read line; do
        log "  $line"
    done
}

# Function to fix common PostgreSQL startup issues
fix_postgresql_startup() {
    log "Attempting to fix PostgreSQL startup issues"
    
    # Check if data directory exists
    if [ ! -d "/var/lib/postgresql/$PG_VERSION/main" ]; then
        log "PostgreSQL data directory does not exist. Creating it..."
        mkdir -p "/var/lib/postgresql/$PG_VERSION/main"
        chown postgres:postgres "/var/lib/postgresql/$PG_VERSION/main"
    fi
    
    # Check permissions on data directory
    log "Checking permissions on PostgreSQL data directory"
    if [ "$(stat -c '%U:%G' /var/lib/postgresql/$PG_VERSION/main)" != "postgres:postgres" ]; then
        log "Fixing permissions on PostgreSQL data directory"
        chown -R postgres:postgres "/var/lib/postgresql/$PG_VERSION/main"
    fi
    
    # Check if PostgreSQL is initialized
    if [ ! -f "/var/lib/postgresql/$PG_VERSION/main/PG_VERSION" ]; then
        log "PostgreSQL data directory is not initialized. Initializing..."
        sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/initdb -D "/var/lib/postgresql/$PG_VERSION/main"
    fi
    
    # Try to start PostgreSQL manually
    log "Attempting to start PostgreSQL manually"
    sudo -u postgres pg_ctl -D "/var/lib/postgresql/$PG_VERSION/main" -l "/var/log/postgresql/postgresql-$PG_VERSION-manual.log" start
    
    # Wait a bit and check if it's running
    sleep 10
    if pg_isready -h localhost -q; then
        log "PostgreSQL started successfully with manual start"
        return 0
    else
        log "PostgreSQL still not running after manual start"
        return 1
    fi
}

# Function to wait for PostgreSQL to be ready
wait_for_postgresql() {
    local max_attempts=30
    local attempt=1
    
    log "Waiting for PostgreSQL to be ready..."
    
    while [ $attempt -le $max_attempts ]; do
        if [ -n "$PG_PASSWORD" ]; then
            if PGPASSWORD="$PG_PASSWORD" pg_isready -h localhost -U postgres -q 2>/dev/null; then
                log "PostgreSQL is ready"
                return 0
            fi
        else
            # If PG_PASSWORD is not set, try without it
            if pg_isready -h localhost -q; then
                log "PostgreSQL is ready"
                return 0
            fi
        fi
        
        log "PostgreSQL not ready yet (attempt $attempt/$max_attempts). Waiting..."
        sleep 5
        attempt=$((attempt + 1))
    done
    
    log "ERROR: PostgreSQL did not become ready after $max_attempts attempts"
    
    # Check logs and try to fix issues
    check_postgresql_logs
    
    # Try to fix startup issues
    if fix_postgresql_startup; then
        log "Successfully fixed PostgreSQL startup issues"
        return 0
    else
        log "Failed to fix PostgreSQL startup issues"
        log "Please check the PostgreSQL logs and configuration manually"
        return 1
    fi
}

# Function to create or load environment file
setup_env_file() {
    # First check for local .env file in current directory
    LOCAL_ENV_FILE="./.env"
    
    if [ -f "$LOCAL_ENV_FILE" ]; then
        log "Found local .env file in current directory"
        ENV_FILE="$LOCAL_ENV_FILE"
    else
        # Use system-wide env file
        ENV_FILE="/etc/dbhub/.env"
        
        # Create directory if it doesn't exist
        if [ ! -d "/etc/dbhub" ]; then
            log "Creating /etc/dbhub directory"
            mkdir -p /etc/dbhub
            chmod 750 /etc/dbhub
        fi
    fi
    
    ENV_BACKUP_FILE="${ENV_FILE}.backup.$(TZ=Asia/Singapore date +%Y%m%d%H%M%S)"
    
    # If .env file exists, back it up
    if [ -f "$ENV_FILE" ]; then
        log "Backing up existing .env file to $ENV_BACKUP_FILE"
        cp "$ENV_FILE" "$ENV_BACKUP_FILE"
        log "Loading environment variables from $ENV_FILE"
        set -a
        source "$ENV_FILE"
        set +a
        log "Environment variables loaded"
    else
        # Create new .env file
        log "Creating new .env file at $ENV_FILE"
        cat > "$ENV_FILE" << EOF
# Database settings
PG_VERSION=$PG_VERSION
PG_PASSWORD=$(openssl rand -base64 16)
PGBOUNCER_PASSWORD=$(openssl rand -base64 16)

# Demo database settings
CREATE_DEMO_DB=true
DEMO_DB_NAME=demo
DEMO_DB_USER=demo
DEMO_DB_PASSWORD=demo

# Email settings
EMAIL_RECIPIENT=$EMAIL_RECIPIENT
EMAIL_SENDER=$EMAIL_SENDER
SMTP_SERVER=$SMTP_SERVER
SMTP_PORT=$SMTP_PORT
SMTP_USER=$SMTP_USER
SMTP_PASS=$SMTP_PASS
SMTP_USE_TLS=$SMTP_USE_TLS

# Domain settings
DOMAIN_SUFFIX=$DOMAIN_SUFFIX
ENABLE_REMOTE_ACCESS=true

# SSL settings
SSL_CERT_VALIDITY=$SSL_CERT_VALIDITY
SSL_COUNTRY=$SSL_COUNTRY
SSL_STATE=$SSL_STATE
SSL_LOCALITY=$SSL_LOCALITY
SSL_ORGANIZATION=$SSL_ORGANIZATION
SSL_COMMON_NAME=$SSL_COMMON_NAME
EOF
        log "Loading environment variables from newly created $ENV_FILE"
        set -a
        source "$ENV_FILE"
        set +a
        log "Environment variables loaded"
    fi
    
    # Set permissions
    chmod 640 "$ENV_FILE"
    
    log "Environment file setup complete"
    
    # Display important settings
    log "PostgreSQL version: $PG_VERSION"
    log "Remote access enabled: $ENABLE_REMOTE_ACCESS"
    log "Demo database enabled: $CREATE_DEMO_DB"
    
    # Debug: Print email settings to verify they're loaded
    log "Email settings loaded:"
    log "  EMAIL_RECIPIENT: $EMAIL_RECIPIENT"
    log "  EMAIL_SENDER: $EMAIL_SENDER"
    log "  SMTP_SERVER: $SMTP_SERVER"
    log "  SMTP_PORT: $SMTP_PORT"
}

# Function to update system packages
update_system() {
    log "Updating system packages"
    apt-get update
    apt-get upgrade -y
    
    log "System update complete"
}

# Function to install required packages
install_required_packages() {
    log "Installing required packages"
    apt-get install -y \
        curl \
        wget \
        gnupg2 \
        lsb-release \
        apt-transport-https \
        ca-certificates \
        software-properties-common \
        sudo \
        ufw \
        fail2ban \
        unattended-upgrades
    
    log "Required packages installed"
}

# Function to install PostgreSQL and PgBouncer
install_postgresql() {
    log "Installing PostgreSQL $PG_VERSION and PgBouncer"
    
    # Add PostgreSQL repository key
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/postgresql.gpg > /dev/null
    
    # Add PostgreSQL repository
    echo "deb [signed-by=/etc/apt/trusted.gpg.d/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
    
    # Update package lists
    apt-get update
    
    # Install PostgreSQL and PgBouncer
    apt-get install -y postgresql-$PG_VERSION postgresql-client-$PG_VERSION pgbouncer
    
    # Wait for PostgreSQL to initialize
    log "Waiting for PostgreSQL to initialize..."
    sleep 10
    
    # Check if PostgreSQL is running properly
    if ! sudo -u postgres pg_isready -q; then
        log "PostgreSQL is not running properly after installation. Attempting to fix..."
        fix_postgresql_cluster
    fi
    
    log "PostgreSQL and PgBouncer installation complete"
}

# Function to configure PostgreSQL
configure_postgresql() {
    log "Configuring PostgreSQL"
    
    # Check if PostgreSQL is running
    if ! systemctl is-active --quiet postgresql; then
        log "PostgreSQL service is not running. Attempting to start..."
        systemctl start postgresql
        sleep 5
        
        if ! systemctl is-active --quiet postgresql; then
            log "Failed to start PostgreSQL service. Attempting to fix cluster..."
            fix_postgresql_cluster
            
            if ! systemctl is-active --quiet postgresql; then
                log "ERROR: Failed to start PostgreSQL service after fix attempts"
                return 1
            fi
        fi
    fi
    
    # Enable PostgreSQL to start on boot
    systemctl enable postgresql
    log "$(systemctl is-enabled postgresql)"
    
    # Configure PostgreSQL for local or remote access
    log "Configuring PostgreSQL network settings"
    
    # Backup original postgresql.conf
    PG_CONF_BACKUP="/etc/postgresql/$PG_VERSION/main/postgresql.conf.$(TZ=Asia/Singapore date +%Y%m%d%H%M%S).bak"
    cp /etc/postgresql/$PG_VERSION/main/postgresql.conf "$PG_CONF_BACKUP"
    
    # Update postgresql.conf
    # Always configure PostgreSQL to listen on all interfaces for better flexibility
    # Security will be controlled via pg_hba.conf
    sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
    log "PostgreSQL configured to listen on all interfaces"
    
    # Configure authentication
    log "Configuring PostgreSQL authentication"
    
    # Enable password encryption using SCRAM-SHA-256
    sed -i "s/#password_encryption = md5/password_encryption = scram-sha-256/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
    
    # Security will be controlled via pg_hba.conf
    
    # Backup original pg_hba.conf
    PG_HBA_BACKUP="/etc/postgresql/$PG_VERSION/main/pg_hba.conf.$(TZ=Asia/Singapore date +%Y%m%d%H%M%S).bak"
    cp /etc/postgresql/$PG_VERSION/main/pg_hba.conf "$PG_HBA_BACKUP"
    
    # Update pg_hba.conf to initially use peer authentication for postgres user
    # This allows us to set the password without having one yet
    # IMPORTANT: We temporarily use 'peer' authentication for the postgres user to allow 
    # setting the password. After the password is set, we switch to 'scram-sha-256' for
    # compatibility with PgBouncer.
    cat > /etc/postgresql/$PG_VERSION/main/pg_hba.conf << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
EOF
    
    # Add remote access if enabled
    if [ "$ENABLE_REMOTE_ACCESS" = true ]; then
        log "Enabling remote access in PostgreSQL configuration"
        echo "host    all             all             0.0.0.0/0               scram-sha-256" >> /etc/postgresql/$PG_VERSION/main/pg_hba.conf
        log "Remote access enabled in PostgreSQL configuration"
    else
        log "Remote access is disabled. PostgreSQL will only accept local connections."
    fi
    
    # Restart PostgreSQL to apply configuration changes
    log "Restarting PostgreSQL to apply configuration changes"
    systemctl restart postgresql
    
    # Wait for PostgreSQL to be ready
    log "Waiting for PostgreSQL to be ready..."
    attempt=1
    max_attempts=30
    while ! pg_isready -h localhost -q; do
        if [ $attempt -ge $max_attempts ]; then
            log "ERROR: PostgreSQL did not become ready after $max_attempts attempts"
            return 1
        fi
        log "PostgreSQL not ready yet (attempt $attempt/$max_attempts). Waiting..."
        attempt=$((attempt + 1))
        sleep 5
    done
    
    log "PostgreSQL is now ready"
    
    # Set PostgreSQL password
    if [ -n "$PG_PASSWORD" ]; then
        log "Setting PostgreSQL password"
        # Use peer authentication to set the password (no password needed)
        sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$PG_PASSWORD'"
        log "PostgreSQL password set successfully"
        
        # Now update pg_hba.conf to use scram-sha-256 for postgres user for PgBouncer compatibility
        log "Updating pg_hba.conf to use SCRAM-SHA-256 for postgres user"
        sed -i 's/local\s\+all\s\+postgres\s\+peer/local all postgres scram-sha-256/' /etc/postgresql/$PG_VERSION/main/pg_hba.conf
        log "Restarting PostgreSQL to apply authentication changes"
        systemctl restart postgresql
        sleep 3
        log "PostgreSQL restarted with updated authentication configuration"
        
        # Grant postgres user access to pg_shadow for PgBouncer auth_query
        log "Granting postgres user access to pg_shadow for PgBouncer SASL authentication"
        if [ -n "$PG_PASSWORD" ]; then
            PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -c "ALTER USER postgres WITH SUPERUSER;"
        else
            log "WARNING: PG_PASSWORD not set, skipping access grant"
        fi
        
        # Revoke public schema privileges
        log "Revoking public schema privileges"
        if [ -n "$PG_PASSWORD" ]; then
            PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -c "REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
        else
            log "WARNING: PG_PASSWORD not set, skipping privilege revocation"
        fi
    else
        log "WARNING: PG_PASSWORD not set. Skipping password configuration."
    fi
    
    log "PostgreSQL configuration complete"
    return 0
}

# Function to configure PgBouncer
configure_pgbouncer() {
    log "Configuring PgBouncer"
    
    # Check if PgBouncer configuration directory exists
    if [ ! -d "/etc/pgbouncer" ]; then
        log "PgBouncer configuration directory does not exist. Creating it."
        mkdir -p "/etc/pgbouncer"
    fi
    
    # Check if PgBouncer is installed properly
    if ! command_exists pgbouncer || ! systemctl is-enabled pgbouncer; then
        log "PgBouncer not installed properly. Reinstalling."
        apt-get install --reinstall -y pgbouncer
        sleep 5
    fi
    
    # Wait for PostgreSQL to be ready before configuring PgBouncer
    wait_for_postgresql
    
    # Ensure SSL directory and certificates exist
    SSL_DIR="/etc/postgresql/ssl"
    if [ ! -d "$SSL_DIR" ]; then
        log "Creating PostgreSQL SSL directory"
        mkdir -p "$SSL_DIR"
        
        # Create self-signed SSL certificate if it doesn't exist
        if [ ! -f "$SSL_DIR/server.crt" ] || [ ! -f "$SSL_DIR/server.key" ]; then
            log "Generating self-signed SSL certificate for PgBouncer"
            apt-get install -y openssl
            
            openssl req -new -x509 -days "${SSL_CERT_VALIDITY:-365}" -nodes \
                -out "$SSL_DIR/server.crt" \
                -keyout "$SSL_DIR/server.key" \
                -subj "/C=${SSL_COUNTRY:-US}/ST=${SSL_STATE:-State}/L=${SSL_LOCALITY:-City}/O=${SSL_ORGANIZATION:-Organization}/CN=${SSL_COMMON_NAME:-localhost}"
            
            chmod 640 "$SSL_DIR/server.key"
            chmod 644 "$SSL_DIR/server.crt"
            chown postgres:postgres "$SSL_DIR/server.key" "$SSL_DIR/server.crt"
            
            log "Self-signed SSL certificate generated"
        else
            log "SSL certificates already exist"
        fi
    else
        log "PostgreSQL SSL directory already exists"
    fi
    
    # Function to get SCRAM hash for PostgreSQL user
    get_user_hash() {
        local username="$1"
        
        # Try using PGPASSWORD to avoid password prompts
        if [ -n "$PG_PASSWORD" ]; then
            local hash=$(PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -tAc "SELECT concat('SCRAM-SHA-256$', split_part(rolpassword, '$', 2), '$', split_part(rolpassword, '$', 3), '$', split_part(rolpassword, '$', 4)) FROM pg_authid WHERE rolname='$username'" 2>/dev/null)
            
            # Check if we got a valid hash
            if [ -n "$hash" ] && [[ "$hash" == SCRAM-SHA-256* ]]; then
                echo "$hash"
                return 0
            fi
            
            # If the above failed, try the peer auth method as fallback
            hash=$(sudo -u postgres psql -tAc "SELECT concat('SCRAM-SHA-256$', split_part(rolpassword, '$', 2), '$', split_part(rolpassword, '$', 3), '$', split_part(rolpassword, '$', 4)) FROM pg_authid WHERE rolname='$username'" 2>/dev/null)
            
            # Check if we got a valid hash with peer auth
            if [ -n "$hash" ] && [[ "$hash" == SCRAM-SHA-256* ]]; then
                echo "$hash"
                return 0
            fi
            
            # If both methods failed, use plain text password as last resort
            log "WARNING: Failed to get SCRAM hash for user $username. Using plain password as fallback."
            echo "$PG_PASSWORD"
            return 1
        else
            log "WARNING: PG_PASSWORD not set, cannot generate hash for $username"
            return 1
        fi
    }
    
    # Ensure postgres user has access to pg_shadow for auth_query
    log "Ensuring postgres user has appropriate permissions for auth_query"
    sudo -u postgres psql -c "ALTER USER postgres WITH SUPERUSER;"
    
    # Create a backup of PgBouncer configuration if it exists
    if [ -f "/etc/pgbouncer/pgbouncer.ini" ]; then
        BACKUP_FILE="/etc/pgbouncer/pgbouncer.ini.$(date +'%Y%m%d%H%M%S').bak"
        log "Creating backup of existing PgBouncer configuration: $BACKUP_FILE"
        cp "/etc/pgbouncer/pgbouncer.ini" "$BACKUP_FILE"
    fi
    
    # Create a backup of userlist.txt if it exists
    if [ -f "/etc/pgbouncer/userlist.txt" ]; then
        USERLIST_BACKUP="/etc/pgbouncer/userlist.txt.$(date +'%Y%m%d%H%M%S').bak"
        log "Creating backup of existing PgBouncer userlist: $USERLIST_BACKUP"
        cp "/etc/pgbouncer/userlist.txt" "$USERLIST_BACKUP"
    fi
    
    # Configure PgBouncer - updated with admin_users and stats_users using proper quoting
    log "Creating PgBouncer configuration"
    cat > "/etc/pgbouncer/pgbouncer.ini" << EOF
[databases]
* = host=localhost port=5432
postgres = host=localhost port=5432 dbname=postgres user=postgres password=$PG_PASSWORD

[pgbouncer]
logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid
listen_addr = *
listen_port = ${PGBOUNCER_PORT:-6432}
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=\$1
auth_user = postgres
admin_users = postgres
stats_users = postgres
pool_mode = ${POOL_MODE:-transaction}
server_reset_query = DISCARD ALL
max_client_conn = ${MAX_CLIENT_CONN:-1000}
default_pool_size = ${DEFAULT_POOL_SIZE:-20}
min_pool_size = 0
reserve_pool_size = ${RESERVE_POOL_SIZE:-5}
reserve_pool_timeout = 3
max_db_connections = 50
max_user_connections = 50
server_round_robin = 0

# Ignore PostgreSQL parameters not supported by PgBouncer
ignore_startup_parameters = extra_float_digits

# SSL settings
client_tls_sslmode = allow
client_tls_key_file = /etc/postgresql/ssl/server.key
client_tls_cert_file = /etc/postgresql/ssl/server.crt
EOF
    
    # Create log directory for PgBouncer if it doesn't exist
    log "Ensuring PgBouncer log directory exists"
    mkdir -p /var/log/postgresql
    touch /var/log/postgresql/pgbouncer.log
    chown postgres:postgres /var/log/postgresql/pgbouncer.log
    
    # Create run directory for PgBouncer if it doesn't exist
    log "Ensuring PgBouncer run directory exists"
    mkdir -p /var/run/postgresql
    chown postgres:postgres /var/run/postgresql
    
    log "PgBouncer configured to listen on all interfaces (listen_addr = *)"
    log "PgBouncer SSL support enabled with client_tls_sslmode = allow"
    log "PgBouncer authentication set to scram-sha-256 to match PostgreSQL"
    log "PgBouncer auth_query added to properly support SASL authentication"
    log "PgBouncer configured to ignore unsupported startup parameter: extra_float_digits"
    
    # Generate PostgreSQL SCRAM-SHA-256 hash for postgres user
    log "Creating new PgBouncer userlist with SCRAM-SHA-256 hashes"
    POSTGRES_PASSWORD_HASH=$(get_user_hash "postgres")
    
    # Check if hash generation was successful
    if [[ "$POSTGRES_PASSWORD_HASH" == SCRAM-SHA-256* ]]; then
        log "Successfully generated SCRAM hash for postgres user"
        echo "\"postgres\" \"$POSTGRES_PASSWORD_HASH\"" > "/etc/pgbouncer/userlist.txt"
    else
        log "WARNING: Failed to generate SCRAM hash. Using plain text password as fallback."
        # Use plain text password as fallback (less secure but more compatible)
        echo "\"postgres\" \"$PG_PASSWORD\"" > "/etc/pgbouncer/userlist.txt"
    fi
    
    # Add demo user if exists
    if [ "${CREATE_DEMO_DB}" = "true" ] && [ -n "${DEMO_DB_USER}" ]; then
        log "Adding demo user to PgBouncer userlist"
        if [ "$(get_postgres_result "SELECT 1 FROM pg_roles WHERE rolname='${DEMO_DB_USER}'")" = "1" ]; then
            DEMO_PASSWORD_HASH=$(get_user_hash "${DEMO_DB_USER}")
            echo "\"${DEMO_DB_USER}\" \"$DEMO_PASSWORD_HASH\"" >> /etc/pgbouncer/userlist.txt
            log "Demo user added to PgBouncer userlist"
        else
            log "Demo user not found in PostgreSQL, skipping"
        fi
    fi
    
    # Set permissions
    chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
    chown postgres:postgres /etc/pgbouncer/userlist.txt
    chmod 640 /etc/pgbouncer/pgbouncer.ini
    chmod 640 /etc/pgbouncer/userlist.txt
    
    # Verify userlist.txt is not empty
    if [ ! -s "/etc/pgbouncer/userlist.txt" ]; then
        log "WARNING: PgBouncer userlist.txt is empty. Creating with plain text password as fallback."
        echo "\"postgres\" \"$PG_PASSWORD\"" > "/etc/pgbouncer/userlist.txt"
        chown postgres:postgres /etc/pgbouncer/userlist.txt
        chmod 640 /etc/pgbouncer/userlist.txt
    fi
    
    log "PgBouncer configuration complete"
    
    # Verify the auth_query setup
    log "Verifying PostgreSQL permissions for auth_query"
    
    # Check permissions using PGPASSWORD to avoid password issues
    has_permission=$(PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -tAc "SELECT has_table_privilege('postgres', 'pg_shadow', 'SELECT')" 2>/dev/null)
    
    if [ "$has_permission" != "t" ]; then
        log "WARNING: postgres user does not have SELECT permission on pg_shadow."
        log "Granting necessary permissions for auth_query"
        PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -c "ALTER USER postgres WITH SUPERUSER;"
    else
        log "postgres user has proper permissions for auth_query"
    fi
    
    # Restart PgBouncer to apply changes
    log "Restarting PgBouncer"
    if ! systemctl restart pgbouncer; then
        log "ERROR: PgBouncer failed to restart with systemctl. Checking logs..."
        
        # Display more detailed diagnostics
        log "PgBouncer service status:"
        systemctl status pgbouncer || true
        
        log "PgBouncer config and permissions:"
        ls -la /etc/pgbouncer/ || true
        
        log "PgBouncer log file:"
        ls -la /var/log/postgresql/pgbouncer.log || true
        cat /var/log/postgresql/pgbouncer.log 2>/dev/null || true
        
        log "Checking systemd journal for PgBouncer errors:"
        journalctl -u pgbouncer --no-pager -n 20 || true
        
        # Try starting manually with verbose output
        log "Attempting to start PgBouncer manually with verbose logging"
        systemctl stop pgbouncer || true
        sleep 3
        
        # Try running PgBouncer directly with verbose output
        log "Running PgBouncer directly for debugging:"
        sudo -u postgres pgbouncer -v -d -u postgres /etc/pgbouncer/pgbouncer.ini || true
        
        # Try restarting with service again after logging
        log "Attempting to restart PgBouncer service again"
        systemctl restart pgbouncer || log "PgBouncer restart failed again. Please check configuration manually."
    else
        log "PgBouncer successfully restarted"
    fi
}

# Function to configure firewall
configure_firewall() {
    log "Configuring firewall"
    
    # Check if UFW is installed
    if ! command_exists ufw; then
        log "UFW not installed. Installing..."
        apt-get install -y ufw
    fi
    
    # Check if firewall should be enabled
    if [ "${ENABLE_FIREWALL:-true}" = "true" ]; then
        log "Configuring UFW firewall"
        
        # Allow SSH
        ufw allow ssh
        
        # Allow PostgreSQL
        if [ "${ENABLE_REMOTE_ACCESS:-false}" = "true" ]; then
            log "Enabling remote access to PostgreSQL (port 5432)"
            ufw allow 5432/tcp
            
            log "Enabling remote access to PgBouncer (port ${PGBOUNCER_PORT:-6432})"
            ufw allow ${PGBOUNCER_PORT:-6432}/tcp
        else
            log "Remote access disabled. Only allowing local connections."
        fi
        
        # Enable UFW if not already enabled
        if ! ufw status | grep -q "Status: active"; then
            log "Enabling UFW firewall"
            echo "y" | ufw enable
        fi
        
        log "UFW firewall configured"
    else
        log "Firewall configuration skipped as ENABLE_FIREWALL is set to false"
    fi
}

# Function to configure fail2ban
configure_fail2ban() {
    log "Configuring fail2ban"
    
    # Create PostgreSQL jail configuration
    cat > "/etc/fail2ban/jail.d/postgresql.conf" << EOF
[postgresql]
enabled = true
port = 5432
filter = postgresql
logpath = /var/log/postgresql/postgresql-*-main.log
maxretry = 5
bantime = 3600
EOF
    
    # Create PostgreSQL filter
    cat > "/etc/fail2ban/filter.d/postgresql.conf" << EOF
[Definition]
failregex = ^.*authentication failed for user.*$
            ^.*no pg_hba.conf entry for host.*$
ignoreregex =
EOF
    
    # Restart fail2ban
    systemctl restart fail2ban
    
    log "fail2ban configuration complete"
}

# Function to create a demo database and user
create_demo_database() {
    log "Creating demo database and user"
    
    # Wait for PostgreSQL to be ready
    wait_for_postgresql
    
    # Check if demo database creation is enabled
    if [ "${CREATE_DEMO_DB}" != "true" ]; then
        log "Demo database creation is disabled. Skipping."
        return 0
    fi
    
    # Use values from .env file
    local db_name="${DEMO_DB_NAME:-demo}"
    local user_name="${DEMO_DB_USER:-demo}"
    local password="${DEMO_DB_PASSWORD:-demo}"
    
    log "Using demo database name: $db_name"
    log "Using demo username: $user_name"
    
    # Create demo database
    log "Creating demo database"
    if [ "$(PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" 2>/dev/null)" != "1" ]; then
        PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -c "CREATE DATABASE $db_name"
        log "Demo database created"
    else
        log "Demo database already exists"
    fi
    
    # Create demo user
    log "Creating demo user"
    if [ "$(PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$user_name'" 2>/dev/null)" != "1" ]; then
        PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -c "CREATE USER $user_name WITH PASSWORD '$password'"
        log "Demo user created"
    else
        PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -c "ALTER USER $user_name WITH PASSWORD '$password'"
        log "Demo user password updated"
    fi
    
    # Grant privileges
    PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE $db_name TO $user_name"
    log "Privileges granted to demo user"
    
    log "Demo database and user created"
    log "Demo username: $user_name"
    log "Demo password: $password"
}

# Function to set up monitoring scripts
setup_monitoring() {
    log "Setting up monitoring scripts"
    
    # Create scripts directory
    mkdir -p /opt/dbhub/scripts
    
    # Create log directory for scripts
    mkdir -p /var/log/dbhub
    chown postgres:postgres /var/log/dbhub
    
    # Copy monitoring scripts
    cp scripts/server_monitor.sh /opt/dbhub/scripts/
    cp scripts/backup_postgres.sh /opt/dbhub/scripts/
    cp scripts/restore_postgres.sh /opt/dbhub/scripts/
    cp scripts/db_user_manager.sh /opt/dbhub/scripts/
    cp scripts/update_pgbouncer_users.sh /opt/dbhub/scripts/
    
    # Set permissions
    chmod +x /opt/dbhub/scripts/*.sh
    chown postgres:postgres /opt/dbhub/scripts/*.sh
    
    # Create symbolic links for commonly used scripts
    ln -sf /opt/dbhub/scripts/db_user_manager.sh /usr/local/bin/db-user
    ln -sf /opt/dbhub/scripts/update_pgbouncer_users.sh /usr/local/bin/pgbouncer-users
    
    # Set up cron jobs
    log "Setting up cron jobs"
    
    # Add server monitoring cron job (every 15 minutes)
    (crontab -l 2>/dev/null || echo "") | grep -v "server_monitor.sh" | { cat; echo "*/15 * * * * /opt/dbhub/scripts/server_monitor.sh > /dev/null 2>&1"; } | crontab -
    
    # Add backup cron job (daily at 2 AM)
    (crontab -l 2>/dev/null || echo "") | grep -v "backup_postgres.sh" | { cat; echo "0 2 * * * /opt/dbhub/scripts/backup_postgres.sh > /dev/null 2>&1"; } | crontab -
    
    # Add PgBouncer user update cron job (daily at 3 AM)
    (crontab -l 2>/dev/null || echo "") | grep -v "update_pgbouncer_users.sh" | { cat; echo "0 3 * * * /opt/dbhub/scripts/update_pgbouncer_users.sh > /dev/null 2>&1"; } | crontab -
    
    log "Monitoring setup completed"
}

# Function to run diagnostics
run_diagnostics() {
    log "Running PostgreSQL diagnostics"
    
    # Check if PostgreSQL is installed
    if command_exists psql; then
        log "PostgreSQL client is installed: $(psql --version)"
    else
        log "ERROR: PostgreSQL client is not installed"
    fi
    
    # Check PostgreSQL service status
    log "PostgreSQL service status:"
    systemctl status postgresql || log "Failed to get PostgreSQL service status"
    
    # Check PostgreSQL cluster status
    log "PostgreSQL cluster status:"
    pg_lsclusters || log "Failed to list PostgreSQL clusters"
    
    # Check PostgreSQL data directory
    log "PostgreSQL data directory:"
    ls -la /var/lib/postgresql/$PG_VERSION/main/ || log "Failed to list PostgreSQL data directory"
    
    # Check PostgreSQL configuration directory
    log "PostgreSQL configuration directory:"
    ls -la /etc/postgresql/$PG_VERSION/main/ || log "Failed to list PostgreSQL configuration directory"
    
    # Check PostgreSQL log directory
    log "PostgreSQL log directory:"
    ls -la /var/log/postgresql/ || log "Failed to list PostgreSQL log directory"
    
    # Check if PostgreSQL port is in use
    log "Checking if PostgreSQL port is in use:"
    lsof -i :5432 || log "No process found using port 5432 with lsof"
    
    # Check if PostgreSQL is accepting connections
    log "Checking if PostgreSQL is accepting connections:"
    sudo -u postgres pg_isready || log "PostgreSQL is not accepting connections"
    
    # Check PostgreSQL logs for errors
    check_postgresql_logs
    
    # If PostgreSQL is not running, try to fix it
    if ! pg_isready -h localhost -q; then
        log "PostgreSQL is not running properly. Attempting to fix..."
        fix_postgresql_cluster
        
        # Check again after fix attempt
        if ! pg_isready -h localhost -q; then
            log "ERROR: PostgreSQL is still not running properly after fix attempts"
            log "Please check the logs and run the diagnostics command for more information"
            exit 1
        fi
    fi
}

# Function to fix PostgreSQL cluster issues
fix_postgresql_cluster() {
    log "Fixing PostgreSQL cluster issues"
    
    # Check if cluster exists but is down
    if pg_lsclusters | grep -q "down"; then
        log "PostgreSQL cluster exists but is down. Attempting to start it..."
        
        # Try to start the cluster
        if pg_ctlcluster $PG_VERSION main start; then
            log "Successfully started PostgreSQL cluster"
            return 0
        else
            log "Failed to start PostgreSQL cluster with pg_ctlcluster. Trying alternative methods..."
        fi
    fi
    
    # Check if data directory is initialized
    if [ -f "/var/lib/postgresql/$PG_VERSION/main/PG_VERSION" ]; then
        log "PostgreSQL data directory is initialized but cluster won't start. Checking permissions..."
        
        # Fix permissions
        chown -R postgres:postgres /var/lib/postgresql/$PG_VERSION/main
        chmod 700 /var/lib/postgresql/$PG_VERSION/main
        
        # Try starting with pg_ctl directly
        log "Starting PostgreSQL with pg_ctl directly..."
        sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/pg_ctl -D /var/lib/postgresql/$PG_VERSION/main start
        
        # Wait a bit and check if it's running
        sleep 5
        if sudo -u postgres pg_isready -q; then
            log "Successfully started PostgreSQL with pg_ctl"
            return 0
        else
            log "Failed to start PostgreSQL with pg_ctl"
        fi
    else
        log "PostgreSQL data directory is not properly initialized. Initializing..."
        
        # Initialize the data directory
        sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/initdb -D /var/lib/postgresql/$PG_VERSION/main
        
        # Try to start the cluster
        pg_ctlcluster $PG_VERSION main start
        
        # Wait a bit and check if it's running
        sleep 5
        if sudo -u postgres pg_isready -q; then
            log "Successfully initialized and started PostgreSQL cluster"
            return 0
        else
            log "Failed to initialize and start PostgreSQL cluster"
        fi
    fi
    
    # If we get here, try recreating the cluster
    log "Attempting to recreate PostgreSQL cluster..."
    
    # Stop PostgreSQL service
    systemctl stop postgresql
    
    # Backup existing data if it exists
    if [ -d "/var/lib/postgresql/$PG_VERSION/main" ]; then
        BACKUP_DIR="/var/lib/postgresql/$PG_VERSION/main_backup_$(TZ=Asia/Singapore date +%Y%m%d%H%M%S)"
        log "Backing up existing data directory to $BACKUP_DIR"
        mv /var/lib/postgresql/$PG_VERSION/main $BACKUP_DIR
    fi
    
    # Create new cluster
    log "Creating new PostgreSQL cluster..."
    pg_createcluster $PG_VERSION main
    
    # Start the cluster
    pg_ctlcluster $PG_VERSION main start
    
    # Wait a bit and check if it's running
    sleep 5
    if sudo -u postgres pg_isready -q; then
        log "Successfully recreated and started PostgreSQL cluster"
        return 0
    else
        log "Failed to recreate and start PostgreSQL cluster"
        return 1
    fi
}

# Function to send email
send_email() {
    local subject="$1"
    local message="$2"
    
    # Add [DBHub] prefix to subject if not already present
    if [[ ! "$subject" == \[DBHub\]* ]]; then
        subject="[DBHub] $subject"
    fi
    
    if [ -n "$EMAIL_RECIPIENT" ] && [ -n "$EMAIL_SENDER" ] && [ -n "$SMTP_SERVER" ] && [ -n "$SMTP_PORT" ] && [ -n "$SMTP_USER" ] && [ -n "$SMTP_PASS" ]; then
        log "Sending email to $EMAIL_RECIPIENT: $subject"
        log "Using SMTP server: $SMTP_SERVER:$SMTP_PORT"
        
        # Create email content
        local email_content="From: $EMAIL_SENDER
To: $EMAIL_RECIPIENT
Subject: $subject
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: 8bit

$message

--
This is an automated message from your DBHub.cc server.
Time: $(TZ=${TIMEZONE:-Asia/Singapore} date +'%Y-%m-%d %H:%M:%S')
"
        
        # Determine protocol based on SMTP_USE_TLS
        local protocol="smtp"
        if [ "${SMTP_USE_TLS}" = "true" ]; then
            protocol="smtps"
            log "Using secure SMTP connection (TLS)"
        fi
        
        # Send email using curl with appropriate protocol
        if curl --silent --show-error --url "${protocol}://$SMTP_SERVER:$SMTP_PORT" \
             --ssl-reqd \
             --mail-from "$EMAIL_SENDER" \
             --mail-rcpt "$EMAIL_RECIPIENT" \
             --user "$SMTP_USER:$SMTP_PASS" \
             --upload-file - <<< "$email_content"; then
            log "Email sent successfully to $EMAIL_RECIPIENT"
            return 0
        else
            log "Failed to send email to $EMAIL_RECIPIENT"
            log "SMTP Server: $SMTP_SERVER"
            log "SMTP Port: $SMTP_PORT"
            log "SMTP User: $SMTP_USER"
            log "Protocol: $protocol"
            return 1
        fi
    else
        log "Email configuration not complete, skipping email notification"
        log "Please set EMAIL_RECIPIENT, EMAIL_SENDER, SMTP_SERVER, SMTP_PORT, SMTP_USER, and SMTP_PASS in your .env file"
        log "Current values:"
        log "  EMAIL_RECIPIENT: $EMAIL_RECIPIENT"
        log "  EMAIL_SENDER: $EMAIL_SENDER"
        log "  SMTP_SERVER: $SMTP_SERVER"
        log "  SMTP_PORT: $SMTP_PORT"
        log "  SMTP_USER: $SMTP_USER"
        log "  SMTP_PASS: ${SMTP_PASS:+[set]}"
        return 1
    fi
}

# Function to send completion notification
send_completion_notification() {
    log "Sending completion notification email"
    
    # Get server IP
    local server_ip=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    
    # Create message
    local message="
PostgreSQL Server Setup Complete!

Your PostgreSQL server has been successfully set up and configured.

Server Information:
------------------
PostgreSQL Version: $PG_VERSION
Host: $(hostname -f)
IP Address: $server_ip
PostgreSQL Port: 5432
PgBouncer Port: 6432
Remote Access: $([ "$ENABLE_REMOTE_ACCESS" = true ] && echo "Enabled" || echo "Disabled")

Admin Connection:
----------------
Username: postgres
Password: $PG_PASSWORD

Demo Database:
-------------
Database: ${DEMO_DB_NAME:-demo}
Username: ${DEMO_DB_USER:-demo}
Password: ${DEMO_DB_PASSWORD:-demo}

Connection Strings:
-----------------
Local PostgreSQL: postgresql://postgres:$PG_PASSWORD@localhost:5432/postgres
Local PgBouncer: postgresql://postgres:$PG_PASSWORD@localhost:6432/postgres
External PostgreSQL: postgresql://${DEMO_DB_USER:-demo}:${DEMO_DB_PASSWORD:-demo}@$server_ip:5432/${DEMO_DB_NAME:-demo}
External PgBouncer: postgresql://${DEMO_DB_USER:-demo}:${DEMO_DB_PASSWORD:-demo}@$server_ip:6432/${DEMO_DB_NAME:-demo}

Configuration Files:
------------------
PostgreSQL Config: /etc/postgresql/$PG_VERSION/main/postgresql.conf
PgBouncer Config: /etc/pgbouncer/pgbouncer.ini
Environment File: $ENV_FILE
Log Directory: $LOG_DIR

Setup completed at: $(TZ=Asia/Singapore date +'%Y-%m-%d %H:%M:%S')
"
    
    # Send email
    send_email "PostgreSQL Server Setup Complete" "$message"
}

# Function to make all modules and scripts executable
make_all_executable() {
    log "Making all modules and scripts executable"
    
    # Make main script executable
    chmod +x "${0}"
    log "Made main script executable"
    
    # Make all scripts in scripts directory executable
    if [ -d "scripts" ]; then
        chmod +x scripts/*.sh
        log "Made all scripts in scripts directory executable"
    else
        log "Scripts directory not found"
    fi
    
    # Make all modules in modules directory executable
    if [ -d "modules" ]; then
        chmod +x modules/*.sh
        log "Made all modules in modules directory executable"
    else
        log "Modules directory not found"
    fi
    
    log "All modules and scripts are now executable"
}

# Function to run postgres commands with password environment variable to avoid prompts
run_postgres_command() {
    local command="$1"
    local db_name="${2:-postgres}"  # Default to postgres database
    
    # First try with peer authentication
    sudo -u postgres psql -d "$db_name" -c "$command" 2>/dev/null
    local result=$?
    
    # If command successful, return
    if [ $result -eq 0 ]; then
        return 0
    fi
    
    # Try running with PGPASSWORD if peer auth failed
    if [ -n "$PG_PASSWORD" ]; then
        PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -d "$db_name" -c "$command" 2>/dev/null
        result=$?
        
        if [ $result -eq 0 ]; then
            return 0
        else
            log "ERROR: Failed to execute PostgreSQL command with both peer and password auth"
            log "Command was: $command"
            return $result
        fi
    else
        log "ERROR: PG_PASSWORD not set and peer auth failed, cannot execute PostgreSQL command"
        log "Command was: $command"
        return 1
    fi
}

# Function to get query result from postgres
get_postgres_result() {
    local query="$1"
    local db_name="${2:-postgres}"  # Default to postgres database
    
    # First try with peer authentication
    local result=$(sudo -u postgres psql -d "$db_name" -tAc "$query" 2>/dev/null)
    local exit_code=$?
    
    # If command successful, return result
    if [ $exit_code -eq 0 ]; then
        echo "$result"
        return 0
    fi
    
    # Try running with PGPASSWORD if peer auth failed
    if [ -n "$PG_PASSWORD" ]; then
        result=$(PGPASSWORD="$PG_PASSWORD" psql -h localhost -U postgres -d "$db_name" -tAc "$query" 2>/dev/null)
        exit_code=$?
        
        if [ $exit_code -eq 0 ]; then
            echo "$result"
            return 0
        else
            log "ERROR: Failed to execute PostgreSQL query with both peer and password auth"
            log "Query was: $query"
            return $exit_code
        fi
    else
        log "ERROR: PG_PASSWORD not set and peer auth failed, cannot execute PostgreSQL query"
        log "Query was: $query"
        return 1
    fi
}

# Function to clear logs before initialization
clear_logs() {
    log "Starting log cleanup process"
    
    # Clear PostgreSQL log files
    log "Clearing PostgreSQL logs..."
    if [ -d "/var/log/postgresql" ]; then
        rm -f /var/log/postgresql/pgbouncer.log
        rm -f /var/log/postgresql/postgresql-*-main.log
        touch /var/log/postgresql/pgbouncer.log
        if getent passwd postgres > /dev/null; then
            chown postgres:postgres /var/log/postgresql/pgbouncer.log
            chmod 640 /var/log/postgresql/pgbouncer.log
        fi
        log "PostgreSQL logs cleared"
    else
        log "PostgreSQL log directory not found, will be created during installation"
    fi

    # Clear DBHub logs
    log "Clearing DBHub logs..."
    if [ -d "/var/log/dbhub" ]; then
        rm -f /var/log/dbhub/server_init.log
        rm -f /var/log/dbhub/*.log
        touch "$LOG_FILE"  # Recreate the current log file
        log "DBHub logs cleared"
    else
        log "DBHub log directory created (was not present)"
    fi

    # Clear systemd journal logs for PostgreSQL and PgBouncer
    log "Clearing journal logs for PostgreSQL and PgBouncer..."
    if command_exists journalctl; then
        journalctl --vacuum-time=1s --unit=postgresql 2>/dev/null || log "No PostgreSQL journal logs found"
        journalctl --vacuum-time=1s --unit=pgbouncer 2>/dev/null || log "No PgBouncer journal logs found"
        log "Journal logs cleared"
    else
        log "journalctl not available, skipping journal cleanup"
    fi

    # Clear any connection info files
    log "Clearing connection info files..."
    rm -f connection_info.txt
    log "Connection info files cleared"
    
    log "Log cleanup process completed"
}

# Main function
main() {
    # Clear logs first
    clear_logs
    
    log "Starting server initialization"
    
    # Make all modules and scripts executable
    make_all_executable
    
    # Setup environment file
    setup_env_file
    
    # Show loaded variables
    log "Using PG_VERSION: $PG_VERSION"
    log "Using PG_PASSWORD: ${PG_PASSWORD:+[password set]}"
    log "Using ENABLE_REMOTE_ACCESS: $ENABLE_REMOTE_ACCESS"
    
    # Update system
    update_system
    
    # Install required packages
    install_required_packages
    
    # Install PostgreSQL and PgBouncer
    install_postgresql
    
    # Check if PostgreSQL is running properly
    if ! pg_isready -h localhost -q; then
        log "PostgreSQL is not running properly. Attempting to fix..."
        fix_postgresql_cluster
        
        # Check again after fix attempt
        if ! pg_isready -h localhost -q; then
            log "ERROR: PostgreSQL is still not running properly after fix attempts"
            log "Please check the logs and run the diagnostics command for more information"
            exit 1
        fi
    fi
    
    # Configure PostgreSQL
    configure_postgresql
    
    # Configure PgBouncer
    configure_pgbouncer
    
    # Configure firewall
    configure_firewall
    
    # Create demo database
    create_demo_database
    
    # Setup monitoring
    setup_monitoring
    
    # Restart services
    log "Restarting PostgreSQL and PgBouncer"
    
    # Restart PostgreSQL and wait for it to be ready
    systemctl restart postgresql || {
        log "Failed to restart PostgreSQL with systemctl. Trying to start manually."
        sudo -u postgres pg_ctl -D "/var/lib/postgresql/$PG_VERSION/main" -l "/var/log/postgresql/postgresql-$PG_VERSION-manual.log" start
    }
    
    if ! wait_for_postgresql; then
        log "ERROR: PostgreSQL failed to start after configuration. Running diagnostics..."
        run_diagnostics
        log "Please fix the issues and try again."
        exit 1
    fi
    
    # Restart PgBouncer
    systemctl restart pgbouncer || {
        log "WARNING: Failed to restart PgBouncer. Continuing..."
    }
    
    log "Server initialization complete"
    log "PostgreSQL version $PG_VERSION installed and configured"
    log "PgBouncer installed and configured"
    
    # Print summary
    echo ""
    echo "=== Server Initialization Summary ==="
    echo "PostgreSQL version: $PG_VERSION"
    echo "PostgreSQL port: 5432"
    echo "PgBouncer port: 6432"
    echo "Remote access: $ENABLE_REMOTE_ACCESS"
    echo "Log directory: $LOG_DIR"
    echo "Environment file: $ENV_FILE"
    echo "Monitoring scripts: /opt/dbhub/scripts/"
    echo "===================================="
    
    # Create connection info file
    CONNECTION_INFO_FILE="connection_info.txt"
    cat > "$CONNECTION_INFO_FILE" << EOF
PostgreSQL Server Connection Information
=======================================

PostgreSQL Version: $PG_VERSION
Host: $(hostname -f)
Port: 5432

Admin Connection:
----------------
Username: postgres
Password: $PG_PASSWORD
Connection String: postgresql://postgres:$PG_PASSWORD@localhost:5432/postgres

PgBouncer Connection:
-------------------
Port: 6432
Connection String: postgresql://postgres:$PG_PASSWORD@localhost:6432/postgres

Demo Database:
-------------
Database: ${DEMO_DB_NAME:-demo}
Username: ${DEMO_DB_USER:-demo}
Password: ${DEMO_DB_PASSWORD:-demo}
Connection String: postgresql://${DEMO_DB_USER:-demo}:${DEMO_DB_PASSWORD:-demo}@localhost:5432/${DEMO_DB_NAME:-demo}
PgBouncer Connection String: postgresql://${DEMO_DB_USER:-demo}:${DEMO_DB_PASSWORD:-demo}@localhost:6432/${DEMO_DB_NAME:-demo}

External Connection:
------------------
Host: $(curl -s ifconfig.me || hostname -I | awk '{print $1}')
PostgreSQL Port: 5432
PgBouncer Port: 6432
Connection String: postgresql://${DEMO_DB_USER:-demo}:${DEMO_DB_PASSWORD:-demo}@$(curl -s ifconfig.me || hostname -I | awk '{print $1}'):5432/${DEMO_DB_NAME:-demo}
PgBouncer Connection String: postgresql://${DEMO_DB_USER:-demo}:${DEMO_DB_PASSWORD:-demo}@$(curl -s ifconfig.me || hostname -I | awk '{print $1}'):6432/${DEMO_DB_NAME:-demo}

Generated: $(TZ=${TIMEZONE:-Asia/Singapore} date +'%Y-%m-%d %H:%M:%S')
EOF
    
    log "Connection information saved to $CONNECTION_INFO_FILE"
    
    # Display external connection information
    log "External connection information:"
    log "Host: $(curl -s ifconfig.me || hostname -I | awk '{print $1}')"
    log "PostgreSQL Port: 5432"
    log "PgBouncer Port: 6432"
    log "Demo Database: ${DEMO_DB_NAME:-demo}"
    log "Demo Username: ${DEMO_DB_USER:-demo}"
    log "Demo Password: ${DEMO_DB_PASSWORD:-demo}"
    
    # Reload environment variables to ensure we have the latest values
    if [ -f "$ENV_FILE" ]; then
        log "Reloading environment variables before sending notification"
        set -a
        source "$ENV_FILE"
        set +a
    fi
    
    # Send completion notification email
    send_completion_notification
}

# Display usage information
usage() {
    echo "Server Initialization Script"
    echo "Usage:"
    echo "  $0 install                - Install and configure PostgreSQL and PgBouncer"
    echo "  $0 diagnostics            - Run diagnostics on PostgreSQL installation"
    echo "  $0 help                   - Display this help message"
}

# Parse command line arguments
case "$1" in
    install)
        main
        ;;
    diagnostics)
        run_diagnostics
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