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
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# Logging function
log() {
    echo "[$(TZ=Asia/Singapore date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
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
    if sudo -u postgres pg_isready -q; then
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
        if sudo -u postgres pg_isready -q; then
            log "PostgreSQL is ready"
            return 0
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
    ENV_FILE="/etc/dbhub/.env"
    ENV_BACKUP_FILE="/etc/dbhub/.env.backup.$(TZ=Asia/Singapore date +%Y%m%d%H%M%S)"
    
    # Create directory if it doesn't exist
    if [ ! -d "/etc/dbhub" ]; then
        log "Creating /etc/dbhub directory"
        mkdir -p /etc/dbhub
        chmod 750 /etc/dbhub
    fi
    
    # If .env file exists, back it up
    if [ -f "$ENV_FILE" ]; then
        log "Backing up existing .env file to $ENV_BACKUP_FILE"
        cp "$ENV_FILE" "$ENV_BACKUP_FILE"
    else
        # Create new .env file
        log "Creating new .env file"
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

# Domain settings
DOMAIN_SUFFIX=$DOMAIN_SUFFIX
ENABLE_REMOTE_ACCESS=$ENABLE_REMOTE_ACCESS

# SSL settings
SSL_CERT_VALIDITY=$SSL_CERT_VALIDITY
SSL_COUNTRY=$SSL_COUNTRY
SSL_STATE=$SSL_STATE
SSL_LOCALITY=$SSL_LOCALITY
SSL_ORGANIZATION=$SSL_ORGANIZATION
SSL_COMMON_NAME=$SSL_COMMON_NAME
EOF
    fi
    
    # Set permissions
    chmod 640 "$ENV_FILE"
    
    # Source the environment file
    source "$ENV_FILE"
    
    log "Environment file setup complete"
}

# Function to update system packages
update_system() {
    log "Updating system packages"
    apt-get update
    apt-get upgrade -y
    
    # Install required packages
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
    
    log "System update complete"
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
    if [ "$ENABLE_REMOTE_ACCESS" = true ]; then
        log "Configuring PostgreSQL for remote access"
        sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
    else
        log "Configuring PostgreSQL for local access only"
        sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
    fi
    
    # Configure PostgreSQL authentication
    log "Configuring PostgreSQL authentication"
    
    # Backup original pg_hba.conf
    PG_HBA_BACKUP="/etc/postgresql/$PG_VERSION/main/pg_hba.conf.$(TZ=Asia/Singapore date +%Y%m%d%H%M%S).bak"
    cp /etc/postgresql/$PG_VERSION/main/pg_hba.conf "$PG_HBA_BACKUP"
    
    # Update pg_hba.conf to use SCRAM-SHA-256 authentication
    cat > /etc/postgresql/$PG_VERSION/main/pg_hba.conf << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
EOF
    
    # Add remote access if enabled
    if [ "$ENABLE_REMOTE_ACCESS" = true ]; then
        echo "host    all             all             0.0.0.0/0               scram-sha-256" >> /etc/postgresql/$PG_VERSION/main/pg_hba.conf
    fi
    
    # Configure PostgreSQL settings
    log "Configuring PostgreSQL settings"
    
    # Backup original postgresql.conf
    PG_CONF_BACKUP="/etc/postgresql/$PG_VERSION/main/postgresql.conf.$(TZ=Asia/Singapore date +%Y%m%d%H%M%S).bak"
    cp /etc/postgresql/$PG_VERSION/main/postgresql.conf "$PG_CONF_BACKUP"
    
    # Update postgresql.conf
    sed -i "s/^#password_encryption = .*/password_encryption = 'scram-sha-256'/" /etc/postgresql/$PG_VERSION/main/postgresql.conf
    
    # Restart PostgreSQL to apply configuration changes
    log "Restarting PostgreSQL to apply configuration changes"
    systemctl restart postgresql
    
    # Wait for PostgreSQL to be ready
    log "Waiting for PostgreSQL to be ready..."
    attempt=1
    max_attempts=30
    while ! sudo -u postgres pg_isready -q; do
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
    if [ -n "$POSTGRES_PASSWORD" ]; then
        log "Setting PostgreSQL password"
        sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$POSTGRES_PASSWORD';"
    else
        log "WARNING: POSTGRES_PASSWORD not set. Skipping password configuration."
    fi
    
    # Revoke public schema privileges
    log "Revoking public schema privileges"
    sudo -u postgres psql -c "REVOKE CREATE ON SCHEMA public FROM PUBLIC;"
    
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
    
    # Configure PgBouncer
    log "Creating PgBouncer configuration"
    cat > "/etc/pgbouncer/pgbouncer.ini" << EOF
[databases]
* = host=localhost port=5432

[pgbouncer]
logfile = /var/log/postgresql/pgbouncer.log
pidfile = /var/run/postgresql/pgbouncer.pid
listen_addr = 127.0.0.1
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres
stats_users = postgres
pool_mode = transaction
server_reset_query = DISCARD ALL
max_client_conn = 1000
default_pool_size = 20
min_pool_size = 0
reserve_pool_size = 5
reserve_pool_timeout = 3
max_db_connections = 50
max_user_connections = 50
server_round_robin = 0
EOF
    
    # Create PgBouncer user list
    log "Creating PgBouncer user list"
    
    # Get PostgreSQL password hash
    PG_PASSWORD_HASH=$(sudo -u postgres psql -t -c "SELECT concat('md5', md5('${PG_PASSWORD}' || 'postgres'))")
    
    # Create userlist.txt with proper password hash
    cat > "/etc/pgbouncer/userlist.txt" << EOF
"postgres" "${PG_PASSWORD_HASH}"
EOF
    
    # Set permissions
    chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
    chown postgres:postgres /etc/pgbouncer/userlist.txt
    chmod 640 /etc/pgbouncer/pgbouncer.ini
    chmod 640 /etc/pgbouncer/userlist.txt
    
    log "PgBouncer configuration complete"
}

# Function to configure firewall
configure_firewall() {
    log "Configuring firewall"
    
    # Enable UFW
    ufw --force enable
    
    # Allow SSH
    ufw allow ssh
    
    # Allow PostgreSQL ports
    log "Opening PostgreSQL ports in firewall"
    ufw allow 5432/tcp
    ufw allow 6432/tcp
    
    log "Firewall configuration complete"
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
    if ! sudo -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname='$db_name'" | grep -q 1; then
        sudo -u postgres psql -c "CREATE DATABASE $db_name;"
        log "Demo database created"
    else
        log "Demo database already exists"
    fi
    
    # Create demo user
    log "Creating demo user"
    if ! sudo -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='$user_name'" | grep -q 1; then
        sudo -u postgres psql -c "CREATE USER $user_name WITH PASSWORD '$password';"
        log "Demo user created"
    else
        sudo -u postgres psql -c "ALTER USER $user_name WITH PASSWORD '$password';"
        log "Demo user password updated"
    fi
    
    # Grant privileges
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $db_name TO $user_name;"
    log "Privileges granted to demo user"
    
    # Add demo user to PgBouncer
    # Get PostgreSQL password hash for demo user
    DEMO_PASSWORD_HASH=$(sudo -u postgres psql -t -c "SELECT concat('md5', md5('${password}' || '${user_name}'))")
    
    # Add to userlist.txt
    echo "\"$user_name\" \"${DEMO_PASSWORD_HASH}\"" >> /etc/pgbouncer/userlist.txt
    
    log "Demo database and user created"
    log "Demo username: $user_name"
    log "Demo password: $password"
}

# Function to set up monitoring scripts
setup_monitoring() {
    log "Setting up monitoring scripts"
    
    # Create scripts directory
    mkdir -p /opt/dbhub/scripts
    
    # Copy monitoring scripts
    cp scripts/server_monitor.sh /opt/dbhub/scripts/
    cp scripts/backup_postgres.sh /opt/dbhub/scripts/
    cp scripts/restore_postgres.sh /opt/dbhub/scripts/
    cp scripts/db_user_manager.sh /opt/dbhub/scripts/
    cp scripts/update_pgbouncer_users.sh /opt/dbhub/scripts/
    
    # Set permissions
    chmod +x /opt/dbhub/scripts/*.sh
    
    # Set up cron jobs
    log "Setting up cron jobs"
    
    # Add server monitoring cron job (every 15 minutes)
    (crontab -l 2>/dev/null || echo "") | grep -v "server_monitor.sh" | { cat; echo "*/15 * * * * /opt/dbhub/scripts/server_monitor.sh > /dev/null 2>&1"; } | crontab -
    
    # Add backup cron job (daily at 2 AM)
    (crontab -l 2>/dev/null || echo "") | grep -v "backup_postgres.sh" | { cat; echo "0 2 * * * /opt/dbhub/scripts/backup_postgres.sh > /dev/null 2>&1"; } | crontab -
    
    # Add PgBouncer user update cron job (daily at 3 AM)
    (crontab -l 2>/dev/null || echo "") | grep -v "update_pgbouncer_users.sh" | { cat; echo "0 3 * * * /opt/dbhub/scripts/update_pgbouncer_users.sh > /dev/null 2>&1"; } | crontab -
    
    log "Monitoring setup complete"
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
    if ! sudo -u postgres pg_isready -q; then
        log "Attempting to fix PostgreSQL cluster..."
        fix_postgresql_cluster
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

# Main function
main() {
    log "Starting server initialization"
    
    # Setup environment file
    setup_env_file
    
    # Update system
    update_system
    
    # Install PostgreSQL and PgBouncer
    install_postgresql
    
    # Check if PostgreSQL is running properly
    if ! sudo -u postgres pg_isready -q; then
        log "PostgreSQL is not running properly. Attempting to fix..."
        fix_postgresql_cluster
        
        # Check again after fix attempt
        if ! sudo -u postgres pg_isready -q; then
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
    echo "Environment file: /etc/dbhub/.env"
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

Generated: $(TZ=Asia/Singapore date +'%Y-%m-%d %H:%M:%S')
EOF
    
    log "Connection information saved to $CONNECTION_INFO_FILE"
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