#!/bin/bash
# secure_permissions.sh - Script to set secure permissions for PostgreSQL and PgBouncer
# This script ensures that database files, configuration files, and scripts have proper permissions

# Default configuration
LOG_FILE="/var/log/secure_permissions.log"
PG_VERSION=${PG_VERSION:-15}
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"
PG_CONFIG_DIR="/etc/postgresql/${PG_VERSION}/main"
PGBOUNCER_CONFIG_DIR="/etc/pgbouncer"
ENV_FILE="/etc/.env"
SCRIPTS_DIR="/usr/local/bin"

# Log function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --all                     Secure all files and directories"
    echo "  --pg-data                 Secure PostgreSQL data directory"
    echo "  --pg-config               Secure PostgreSQL configuration files"
    echo "  --pgbouncer               Secure PgBouncer configuration files"
    echo "  --env-file                Secure environment file"
    echo "  --scripts                 Secure script files"
    echo "  --help                    Show this help message"
    exit 1
}

# Function to secure PostgreSQL data directory
secure_pg_data() {
    log "Securing PostgreSQL data directory: $PG_DATA_DIR"
    
    if [ ! -d "$PG_DATA_DIR" ]; then
        log "ERROR: PostgreSQL data directory not found: $PG_DATA_DIR"
        return 1
    fi
    
    # Set ownership
    chown -R postgres:postgres "$PG_DATA_DIR"
    log "Set ownership of $PG_DATA_DIR to postgres:postgres"
    
    # Set permissions
    chmod 700 "$PG_DATA_DIR"
    log "Set permissions of $PG_DATA_DIR to 700"
    
    # Set permissions for files in data directory
    find "$PG_DATA_DIR" -type f -exec chmod 600 {} \;
    log "Set permissions of all files in $PG_DATA_DIR to 600"
    
    # Set permissions for directories in data directory
    find "$PG_DATA_DIR" -type d -exec chmod 700 {} \;
    log "Set permissions of all directories in $PG_DATA_DIR to 700"
    
    # Make sure pg_hba.conf and pg_ident.conf have proper permissions if they exist in data dir
    if [ -f "$PG_DATA_DIR/pg_hba.conf" ]; then
        chmod 600 "$PG_DATA_DIR/pg_hba.conf"
        log "Set permissions of $PG_DATA_DIR/pg_hba.conf to 600"
    fi
    
    if [ -f "$PG_DATA_DIR/pg_ident.conf" ]; then
        chmod 600 "$PG_DATA_DIR/pg_ident.conf"
        log "Set permissions of $PG_DATA_DIR/pg_ident.conf to 600"
    fi
    
    log "PostgreSQL data directory secured"
}

# Function to secure PostgreSQL configuration files
secure_pg_config() {
    log "Securing PostgreSQL configuration directory: $PG_CONFIG_DIR"
    
    if [ ! -d "$PG_CONFIG_DIR" ]; then
        log "ERROR: PostgreSQL configuration directory not found: $PG_CONFIG_DIR"
        return 1
    fi
    
    # Set ownership
    chown -R postgres:postgres "$PG_CONFIG_DIR"
    log "Set ownership of $PG_CONFIG_DIR to postgres:postgres"
    
    # Set permissions for the configuration directory
    chmod 750 "$PG_CONFIG_DIR"
    log "Set permissions of $PG_CONFIG_DIR to 750"
    
    # Set permissions for configuration files
    find "$PG_CONFIG_DIR" -type f -exec chmod 640 {} \;
    log "Set permissions of all files in $PG_CONFIG_DIR to 640"
    
    # Set tighter permissions for pg_hba.conf and pg_ident.conf
    if [ -f "$PG_CONFIG_DIR/pg_hba.conf" ]; then
        chmod 640 "$PG_CONFIG_DIR/pg_hba.conf"
        log "Set permissions of $PG_CONFIG_DIR/pg_hba.conf to 640"
    fi
    
    if [ -f "$PG_CONFIG_DIR/pg_ident.conf" ]; then
        chmod 640 "$PG_CONFIG_DIR/pg_ident.conf"
        log "Set permissions of $PG_CONFIG_DIR/pg_ident.conf to 640"
    fi
    
    if [ -f "$PG_CONFIG_DIR/postgresql.conf" ]; then
        chmod 640 "$PG_CONFIG_DIR/postgresql.conf"
        log "Set permissions of $PG_CONFIG_DIR/postgresql.conf to 640"
    fi
    
    # Set permissions for .pem files (SSL)
    find "$PG_CONFIG_DIR" -name "*.pem" -exec chmod 600 {} \;
    log "Set permissions of all .pem files in $PG_CONFIG_DIR to 600"
    
    log "PostgreSQL configuration files secured"
}

# Function to secure PgBouncer configuration files
secure_pgbouncer() {
    log "Securing PgBouncer configuration directory: $PGBOUNCER_CONFIG_DIR"
    
    if [ ! -d "$PGBOUNCER_CONFIG_DIR" ]; then
        log "ERROR: PgBouncer configuration directory not found: $PGBOUNCER_CONFIG_DIR"
        return 1
    fi
    
    # Set ownership
    chown -R postgres:postgres "$PGBOUNCER_CONFIG_DIR"
    log "Set ownership of $PGBOUNCER_CONFIG_DIR to postgres:postgres"
    
    # Set permissions for the configuration directory
    chmod 750 "$PGBOUNCER_CONFIG_DIR"
    log "Set permissions of $PGBOUNCER_CONFIG_DIR to 750"
    
    # Set permissions for configuration files
    find "$PGBOUNCER_CONFIG_DIR" -type f -exec chmod 640 {} \;
    log "Set permissions of all files in $PGBOUNCER_CONFIG_DIR to 640"
    
    # Set tighter permissions for pgbouncer.ini and userlist.txt
    if [ -f "$PGBOUNCER_CONFIG_DIR/pgbouncer.ini" ]; then
        chmod 640 "$PGBOUNCER_CONFIG_DIR/pgbouncer.ini"
        log "Set permissions of $PGBOUNCER_CONFIG_DIR/pgbouncer.ini to 640"
    fi
    
    if [ -f "$PGBOUNCER_CONFIG_DIR/userlist.txt" ]; then
        chmod 640 "$PGBOUNCER_CONFIG_DIR/userlist.txt"
        log "Set permissions of $PGBOUNCER_CONFIG_DIR/userlist.txt to 640"
    fi
    
    log "PgBouncer configuration files secured"
}

# Function to secure environment file
secure_env_file() {
    log "Securing environment file: $ENV_FILE"
    
    if [ ! -f "$ENV_FILE" ]; then
        log "WARNING: Environment file not found: $ENV_FILE"
        return 0
    fi
    
    # Set ownership
    chown root:postgres "$ENV_FILE"
    log "Set ownership of $ENV_FILE to root:postgres"
    
    # Set permissions
    chmod 640 "$ENV_FILE"
    log "Set permissions of $ENV_FILE to 640"
    
    log "Environment file secured"
}

# Function to secure script files
secure_scripts() {
    log "Securing script files in $SCRIPTS_DIR"
    
    # Make sure scripts directory exists
    if [ ! -d "$SCRIPTS_DIR" ]; then
        log "WARNING: Scripts directory not found: $SCRIPTS_DIR"
        return 0
    fi
    
    # List of script files
    local script_files=(
        "server_monitor.sh"
        "pgbouncer_monitor.sh"
        "db_performance_monitor.sh"
        "db_backup.sh"
        "restore_postgres.sh"
        "db_user_manager.sh"
        "update_pgbouncer_users.sh"
        "monitoring_status.sh"
        "create_database.sh"
        "setup_monitoring.sh"
        "make_executable.sh"
    )
    
    # Set ownership and permissions for each script
    for script in "${script_files[@]}"; do
        if [ -f "$SCRIPTS_DIR/$script" ]; then
            chown root:root "$SCRIPTS_DIR/$script"
            chmod 755 "$SCRIPTS_DIR/$script"
            log "Secured $SCRIPTS_DIR/$script (owner: root:root, permissions: 755)"
        else
            log "WARNING: Script not found: $SCRIPTS_DIR/$script"
        fi
    done
    
    log "Script files secured"
}

# Function to secure all files and directories
secure_all() {
    log "Securing all PostgreSQL and PgBouncer files"
    
    secure_pg_data
    secure_pg_config
    secure_pgbouncer
    secure_env_file
    secure_scripts
    
    log "All files and directories secured"
}

# Create log directory and file if they don't exist
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: This script must be run as root"
    exit 1
fi

# Parse command line arguments
if [ $# -eq 0 ]; then
    show_usage
fi

case "$1" in
    --all)
        secure_all
        ;;
    --pg-data)
        secure_pg_data
        ;;
    --pg-config)
        secure_pg_config
        ;;
    --pgbouncer)
        secure_pgbouncer
        ;;
    --env-file)
        secure_env_file
        ;;
    --scripts)
        secure_scripts
        ;;
    --help)
        show_usage
        ;;
    *)
        log "Unknown option: $1"
        show_usage
        ;;
esac

exit 0 