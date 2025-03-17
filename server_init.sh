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
        sudo -u postgres pg_ctl -D /var/lib/postgresql/$PG_VERSION/main init
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
install_postgres() {
    log "Installing PostgreSQL $PG_VERSION and PgBouncer"
    
    # Add PostgreSQL repository
    if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
        log "Adding PostgreSQL repository"
        echo "deb [signed-by=/etc/apt/trusted.gpg.d/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
        wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/postgresql.gpg > /dev/null
        apt-get update
    fi
    
    # Install PostgreSQL and PgBouncer
    apt-get install -y postgresql-$PG_VERSION postgresql-client-$PG_VERSION pgbouncer
    
    # Wait for PostgreSQL to initialize
    sleep 10
    
    log "PostgreSQL and PgBouncer installation complete"
}

# Function to configure PostgreSQL
configure_postgres() {
    log "Configuring PostgreSQL"
    
    # Check if PostgreSQL configuration directory exists
    if [ ! -d "/etc/postgresql/$PG_VERSION/main" ]; then
        log "PostgreSQL configuration directory does not exist. Creating it."
        mkdir -p "/etc/postgresql/$PG_VERSION/main"
        chown postgres:postgres "/etc/postgresql/$PG_VERSION/main"
    fi
    
    # Check if PostgreSQL is installed properly
    if ! command_exists psql || ! systemctl is-enabled postgresql; then
        log "PostgreSQL not installed properly. Reinstalling."
        apt-get install --reinstall -y postgresql-$PG_VERSION
        sleep 10
    fi
    
    # Check if postgresql.conf exists
    if [ ! -f "/etc/postgresql/$PG_VERSION/main/postgresql.conf" ]; then
        log "postgresql.conf does not exist. Creating a basic configuration."
        cat > "/etc/postgresql/$PG_VERSION/main/postgresql.conf" << EOF
# Basic PostgreSQL configuration
data_directory = '/var/lib/postgresql/$PG_VERSION/main'
hba_file = '/etc/postgresql/$PG_VERSION/main/pg_hba.conf'
ident_file = '/etc/postgresql/$PG_VERSION/main/pg_ident.conf'

# Connection settings
listen_addresses = 'localhost'
port = 5432
max_connections = 100
superuser_reserved_connections = 3

# Memory settings
shared_buffers = 128MB
work_mem = 4MB
maintenance_work_mem = 64MB

# Write ahead log
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB

# Background writer
bgwriter_delay = 200ms
bgwriter_lru_maxpages = 100
bgwriter_lru_multiplier = 2.0

# Logging
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 10MB
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0

# Autovacuum
autovacuum = on
autovacuum_max_workers = 3
autovacuum_naptime = 1min
autovacuum_vacuum_threshold = 50
autovacuum_analyze_threshold = 50
autovacuum_vacuum_scale_factor = 0.2
autovacuum_analyze_scale_factor = 0.1
autovacuum_vacuum_cost_delay = 20ms
autovacuum_vacuum_cost_limit = 200

# Statement behavior
search_path = '"$user", public'
default_tablespace = ''
temp_tablespaces = ''
EOF
        chown postgres:postgres "/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    fi
    
    # Configure PostgreSQL to listen on appropriate interfaces
    if [ "$ENABLE_REMOTE_ACCESS" = true ]; then
        log "Configuring PostgreSQL for remote access"
        sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    else
        log "Configuring PostgreSQL for local access only"
        sed -i "s/^#\?listen_addresses.*/listen_addresses = 'localhost'/" "/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    fi
    
    # Configure PostgreSQL authentication
    log "Configuring PostgreSQL authentication"
    cat > "/etc/postgresql/$PG_VERSION/main/pg_hba.conf" << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# "local" is for Unix domain socket connections only
local   all             postgres                                peer
local   all             all                                     md5
# IPv4 local connections:
host    all             all             127.0.0.1/32            md5
# IPv6 local connections:
host    all             all             ::1/128                 md5
EOF
    chown postgres:postgres "/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
    
    # Add remote access if enabled
    if [ "$ENABLE_REMOTE_ACCESS" = true ]; then
        echo "# Allow remote connections from trusted networks:" >> "/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
        echo "host    all             all             0.0.0.0/0               md5" >> "/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
    fi
    
    # Restart PostgreSQL to apply configuration changes
    log "Restarting PostgreSQL to apply configuration changes"
    systemctl restart postgresql || {
        log "Failed to restart PostgreSQL with systemctl. Trying to start manually."
        sudo -u postgres pg_ctl -D "/var/lib/postgresql/$PG_VERSION/main" -l "/var/log/postgresql/postgresql-$PG_VERSION-manual.log" start
    }
    
    # Wait for PostgreSQL to be ready
    if ! wait_for_postgresql; then
        log "ERROR: PostgreSQL failed to start. Exiting."
        exit 1
    fi
    
    # Set PostgreSQL password
    log "Setting PostgreSQL password"
    if ! sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$PG_PASSWORD';" 2>/dev/null; then
        log "Failed to set PostgreSQL password. Trying again after restart."
        systemctl restart postgresql
        sleep 10
        wait_for_postgresql
        sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$PG_PASSWORD';"
    fi
    
    log "PostgreSQL configuration complete"
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
    
    # Allow PostgreSQL if remote access is enabled
    if [ "$ENABLE_REMOTE_ACCESS" = true ]; then
        log "Opening PostgreSQL port in firewall"
        ufw allow 5432/tcp
    fi
    
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
create_demo_db() {
    log "Creating demo database and user"
    
    # Wait for PostgreSQL to be ready
    wait_for_postgresql
    
    # Create demo database
    log "Creating demo database"
    if ! sudo -u postgres psql -c "SELECT 1 FROM pg_database WHERE datname='demo'" | grep -q 1; then
        sudo -u postgres psql -c "CREATE DATABASE demo;"
        log "Demo database created"
    else
        log "Demo database already exists"
    fi
    
    # Create demo user
    log "Creating demo user"
    DEMO_PASSWORD=$(openssl rand -base64 12)
    if ! sudo -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='demo'" | grep -q 1; then
        sudo -u postgres psql -c "CREATE USER demo WITH PASSWORD '$DEMO_PASSWORD';"
        log "Demo user created"
    else
        sudo -u postgres psql -c "ALTER USER demo WITH PASSWORD '$DEMO_PASSWORD';"
        log "Demo user password updated"
    fi
    
    # Grant privileges
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE demo TO demo;"
    log "Privileges granted to demo user"
    
    # Add demo user to PgBouncer
    # Get PostgreSQL password hash for demo user
    DEMO_PASSWORD_HASH=$(sudo -u postgres psql -t -c "SELECT concat('md5', md5('${DEMO_PASSWORD}' || 'demo'))")
    
    # Add to userlist.txt
    echo "\"demo\" \"${DEMO_PASSWORD_HASH}\"" >> /etc/pgbouncer/userlist.txt
    
    log "Demo database and user created"
    log "Demo username: demo"
    log "Demo password: $DEMO_PASSWORD"
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
    
    # Check PostgreSQL port
    log "Checking if PostgreSQL port is in use:"
    if command_exists lsof; then
        lsof -i :5432 || log "No process found using port 5432 with lsof"
    fi
    if command_exists netstat; then
        netstat -tuln | grep 5432 || log "No process found using port 5432 with netstat"
    fi
    
    # Check if PostgreSQL is accepting connections
    log "Checking if PostgreSQL is accepting connections:"
    sudo -u postgres pg_isready -v || log "PostgreSQL is not accepting connections"
    
    # Check PostgreSQL logs
    check_postgresql_logs
    
    log "Diagnostics complete"
}

# Main function
main() {
    log "Starting server initialization"
    
    # Setup environment file
    setup_env_file
    
    # Update system
    update_system
    
    # Install PostgreSQL and PgBouncer
    install_postgres
    
    # Configure PostgreSQL
    configure_postgres || {
        log "ERROR: Failed to configure PostgreSQL. Running diagnostics..."
        run_diagnostics
        log "Please fix the issues and try again."
        exit 1
    }
    
    # Configure PgBouncer
    configure_pgbouncer || {
        log "ERROR: Failed to configure PgBouncer. Running diagnostics..."
        run_diagnostics
        log "Please fix the issues and try again."
        exit 1
    }
    
    # Configure firewall
    configure_firewall
    
    # Configure fail2ban
    configure_fail2ban
    
    # Create demo database
    create_demo_db || {
        log "WARNING: Failed to create demo database. Continuing..."
    }
    
    # Setup monitoring
    setup_monitoring || {
        log "WARNING: Failed to set up monitoring. Continuing..."
    }
    
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
Database: demo
Username: demo
Password: $DEMO_PASSWORD
Connection String: postgresql://demo:$DEMO_PASSWORD@localhost:5432/demo
PgBouncer Connection String: postgresql://demo:$DEMO_PASSWORD@localhost:6432/demo

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