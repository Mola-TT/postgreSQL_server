#!/bin/bash

# Fix PgBouncer SSL Script
# This script enables SSL support in PgBouncer for existing installations

# Log file
LOG_FILE="/var/log/dbhub/pgbouncer_ssl_fix.log"
PGBOUNCER_CONF="/etc/pgbouncer/pgbouncer.ini"
PG_CONF_DIR="/etc/postgresql"
SSL_DIR="/etc/postgresql/ssl"

# Ensure log directory exists
mkdir -p $(dirname $LOG_FILE)
touch $LOG_FILE

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Load environment variables
load_env_vars() {
    log "Loading environment variables"
    ENV_FILES=("/etc/dbhub/.env" "/opt/dbhub/.env" "../.env" "./.env")
    
    for ENV_FILE in "${ENV_FILES[@]}"; do
        if [[ -f "$ENV_FILE" ]]; then
            source "$ENV_FILE"
            log "Loaded environment variables from $ENV_FILE"
            return 0
        fi
    done
    
    log "No environment file found, using default values"
    
    # Default values if no environment file is found
    SSL_CERT_VALIDITY=${SSL_CERT_VALIDITY:-365}
    SSL_COUNTRY=${SSL_COUNTRY:-US}
    SSL_STATE=${SSL_STATE:-State}
    SSL_LOCALITY=${SSL_LOCALITY:-City}
    SSL_ORGANIZATION=${SSL_ORGANIZATION:-Organization}
    SSL_COMMON_NAME=${SSL_COMMON_NAME:-localhost}
}

# Function to ensure SSL directory and certificates exist
setup_ssl_certs() {
    log "Setting up SSL certificates"
    
    # Create SSL directory if it doesn't exist
    if [ ! -d "$SSL_DIR" ]; then
        log "Creating PostgreSQL SSL directory: $SSL_DIR"
        mkdir -p "$SSL_DIR"
    else
        log "PostgreSQL SSL directory already exists: $SSL_DIR"
    fi
    
    # Create self-signed SSL certificate if it doesn't exist
    if [ ! -f "$SSL_DIR/server.crt" ] || [ ! -f "$SSL_DIR/server.key" ]; then
        log "Generating self-signed SSL certificate"
        
        # Ensure OpenSSL is installed
        if ! command -v openssl &>/dev/null; then
            log "Installing OpenSSL"
            apt-get update
            apt-get install -y openssl
        fi
        
        # Generate self-signed certificate
        openssl req -new -x509 -days "$SSL_CERT_VALIDITY" -nodes \
            -out "$SSL_DIR/server.crt" \
            -keyout "$SSL_DIR/server.key" \
            -subj "/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/CN=$SSL_COMMON_NAME"
        
        # Set proper permissions
        chmod 640 "$SSL_DIR/server.key"
        chmod 644 "$SSL_DIR/server.crt"
        chown postgres:postgres "$SSL_DIR/server.key" "$SSL_DIR/server.crt"
        
        log "Self-signed SSL certificate generated"
    else
        log "SSL certificates already exist"
    fi
}

# Function to update PgBouncer configuration
update_pgbouncer_conf() {
    log "Updating PgBouncer configuration"
    
    # Check if PgBouncer configuration file exists
    if [ ! -f "$PGBOUNCER_CONF" ]; then
        log "ERROR: PgBouncer configuration file not found: $PGBOUNCER_CONF"
        log "Make sure PgBouncer is properly installed"
        exit 1
    fi
    
    # Backup current configuration
    BACKUP_FILE="${PGBOUNCER_CONF}.$(date +'%Y%m%d%H%M%S').bak"
    log "Creating backup of PgBouncer configuration: $BACKUP_FILE"
    cp "$PGBOUNCER_CONF" "$BACKUP_FILE"
    
    # Check if SSL settings are already in the configuration
    if grep -q "client_tls_sslmode" "$PGBOUNCER_CONF"; then
        log "SSL settings already present in PgBouncer configuration"
    else
        log "Adding SSL settings to PgBouncer configuration"
        
        # Add SSL settings to the configuration file
        sed -i '/\[pgbouncer\]/,/^\[/ s/^server_round_robin = 0/server_round_robin = 0\n\n# SSL settings\nclient_tls_sslmode = allow\nclient_tls_key_file = \/etc\/postgresql\/ssl\/server.key\nclient_tls_cert_file = \/etc\/postgresql\/ssl\/server.crt/' "$PGBOUNCER_CONF"
        
        log "SSL settings added to PgBouncer configuration"
    fi
    
    # Set proper permissions on the configuration file
    chown postgres:postgres "$PGBOUNCER_CONF"
    chmod 640 "$PGBOUNCER_CONF"
}

# Function to restart PgBouncer
restart_pgbouncer() {
    log "Restarting PgBouncer"
    
    # Restart PgBouncer service
    if systemctl is-active --quiet pgbouncer; then
        systemctl restart pgbouncer
        
        # Check if PgBouncer started successfully
        if systemctl is-active --quiet pgbouncer; then
            log "PgBouncer restarted successfully"
        else
            log "ERROR: Failed to restart PgBouncer"
            log "Check PgBouncer logs: journalctl -u pgbouncer"
            exit 1
        fi
    else
        log "PgBouncer is not running, starting it"
        systemctl start pgbouncer
        
        # Check if PgBouncer started successfully
        if systemctl is-active --quiet pgbouncer; then
            log "PgBouncer started successfully"
        else
            log "ERROR: Failed to start PgBouncer"
            log "Check PgBouncer logs: journalctl -u pgbouncer"
            exit 1
        fi
    fi
}

# Main function
main() {
    log "Starting PgBouncer SSL fix"
    
    load_env_vars
    setup_ssl_certs
    update_pgbouncer_conf
    restart_pgbouncer
    
    log "PgBouncer SSL fix completed successfully"
    log "PgBouncer should now support SSL connections"
    log "Connection string example: postgresql://user:password@hostname:6432/dbname?sslmode=require"
}

# Run main function
main

exit 0 