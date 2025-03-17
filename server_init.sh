#!/bin/bash

# PostgreSQL Server Initialization Script
# This script sets up a PostgreSQL server with PgBouncer, security enhancements,
# and monitoring capabilities.

# Security notice
# IMPORTANT: This script uses environment variables for sensitive information.
# Create a .env file based on .env.example before running this script.

# Load functions from modules
source "$(dirname "$0")/modules/common.sh"
source "$(dirname "$0")/modules/postgresql.sh"
source "$(dirname "$0")/modules/pgbouncer.sh"
source "$(dirname "$0")/modules/security.sh"
source "$(dirname "$0")/modules/monitoring.sh"
source "$(dirname "$0")/modules/subdomain.sh"

# Main execution function
main() {
    # Create log directory and file
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    log "Starting PostgreSQL server initialization"
    
    # Load or create environment file
    setup_environment
    
    # Install PostgreSQL and dependencies
    install_postgresql
    
    # Configure PostgreSQL
    configure_postgresql
    
    # Install and configure PgBouncer
    install_pgbouncer
    configure_pgbouncer
    
    # Set up security enhancements
    setup_security
    
    # Set up monitoring
    if [ "$INSTALL_MONITORING" = "true" ]; then
        setup_monitoring
    else
        log "Monitoring installation skipped (set INSTALL_MONITORING=true to enable)"
    fi
    
    # Set up subdomain routing
    setup_subdomain_routing
    
    # Create demo database if requested
    if [ "$CREATE_DEMO_DB" = "true" ]; then
        create_demo_database
    fi
    
    # Restart services
    restart_services
    
    log "PostgreSQL server initialization completed successfully"
    log "Connection information saved to connection_info.txt"
    
    exit 0
}

# Function to set up environment variables
setup_environment() {
    log "Setting up environment variables"
    
    # Default configuration
    PG_VERSION=${PG_VERSION:-"17"}
    DOMAIN_SUFFIX=${DOMAIN_SUFFIX:-"example.com"}
    ENABLE_REMOTE_ACCESS=${ENABLE_REMOTE_ACCESS:-false}
    CREATE_DEMO_DB=${CREATE_DEMO_DB:-true}
    INSTALL_MONITORING=${INSTALL_MONITORING:-false}
    USE_LETSENCRYPT=${USE_LETSENCRYPT:-false}
    
    # Email settings for alerts
    EMAIL_RECIPIENT=${EMAIL_RECIPIENT:-""}
    EMAIL_SENDER=${EMAIL_SENDER:-""}
    SMTP_SERVER=${SMTP_SERVER:-""}
    SMTP_PORT=${SMTP_PORT:-""}
    SMTP_USER=${SMTP_USER:-""}
    SMTP_PASS=${SMTP_PASS:-""}
    
    # SSL certificate settings
    SSL_CERT_VALIDITY=${SSL_CERT_VALIDITY:-"365"}
    SSL_CERT_COUNTRY=${SSL_CERT_COUNTRY:-"US"}
    SSL_CERT_STATE=${SSL_CERT_STATE:-"California"}
    SSL_CERT_LOCALITY=${SSL_CERT_LOCALITY:-"San Francisco"}
    SSL_CERT_ORG=${SSL_CERT_ORG:-"DBHub"}
    SSL_CERT_OU=${SSL_CERT_OU:-"IT"}
    SSL_CERT_CN=${SSL_CERT_CN:-"$DOMAIN_SUFFIX"}
    
    # Load environment variables from .env file if it exists
    ENV_FILE="$(dirname "$0")/.env"
    if [ -f "$ENV_FILE" ]; then
        log "Loading environment variables from $ENV_FILE"
        source "$ENV_FILE"
    else
        log "No .env file found, creating one with default values"
        create_env_file
    fi
    
    # Back up the environment file
    backup_env_file
}

# Function to create environment file if it doesn't exist
create_env_file() {
    log "Creating environment file"
    
    # Generate random passwords if not set
    PG_PASSWORD=${PG_PASSWORD:-$(generate_password)}
    PGBOUNCER_ADMIN_PASSWORD=${PGBOUNCER_ADMIN_PASSWORD:-$(generate_password)}
    
    # Create .env file
    cat > "$ENV_FILE" << EOF
# PostgreSQL Configuration
PG_VERSION=$PG_VERSION
PG_PASSWORD=$PG_PASSWORD
PG_PORT=5432

# PgBouncer Configuration
PGBOUNCER_PORT=6432
PGBOUNCER_ADMIN_PASSWORD=$PGBOUNCER_ADMIN_PASSWORD
MAX_CLIENT_CONN=1000
DEFAULT_POOL_SIZE=20

# Domain Configuration
DOMAIN_SUFFIX=$DOMAIN_SUFFIX
ENABLE_REMOTE_ACCESS=$ENABLE_REMOTE_ACCESS

# Email Configuration
EMAIL_RECIPIENT=$EMAIL_RECIPIENT
EMAIL_SENDER=$EMAIL_SENDER
SMTP_SERVER=$SMTP_SERVER
SMTP_PORT=$SMTP_PORT
SMTP_USER=$SMTP_USER
SMTP_PASS=$SMTP_PASS

# Monitoring Configuration
INSTALL_MONITORING=$INSTALL_MONITORING

# SSL Configuration
USE_LETSENCRYPT=$USE_LETSENCRYPT
EOF

    # Set secure permissions
    chmod 600 "$ENV_FILE"
}

# Function to back up environment file
backup_env_file() {
    log "Backing up environment file"
    
    # Create backup directory if it doesn't exist
    BACKUP_DIR="$(dirname "$0")/.env_backups"
    mkdir -p "$BACKUP_DIR"
    
    # Create backup with timestamp
    ENV_BACKUP_FILE="$BACKUP_DIR/.env.$(date +'%Y%m%d%H%M%S')"
    cp "$ENV_FILE" "$ENV_BACKUP_FILE"
    chmod 600 "$ENV_BACKUP_FILE"
    
    log "Environment file backed up to $ENV_BACKUP_FILE"
}

# Function to generate a random password
generate_password() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16
}

# Function to create a demo database
create_demo_database() {
    log "Creating demo database and user"
    
    # Check if PostgreSQL is running
    if systemctl is-active postgresql > /dev/null 2>&1; then
        # Set demo database name and user
        DEMO_DB_NAME=${DEMO_DB_NAME:-"demo"}
        DEMO_DB_USER=${DEMO_DB_USER:-"demo_user"}
        DEMO_DB_PASSWORD=${DEMO_DB_PASSWORD:-$(generate_password)}
        
        # Create demo database and user
        sudo -u postgres psql -c "CREATE DATABASE $DEMO_DB_NAME;"
        sudo -u postgres psql -c "CREATE USER $DEMO_DB_USER WITH ENCRYPTED PASSWORD '$DEMO_DB_PASSWORD';"
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DEMO_DB_NAME TO $DEMO_DB_USER;"
        
        # Update .env file with demo database information
        if ! grep -q "DEMO_DB_NAME" "$ENV_FILE"; then
            echo "" >> "$ENV_FILE"
            echo "# Demo Database Configuration" >> "$ENV_FILE"
            echo "DEMO_DB_NAME=$DEMO_DB_NAME" >> "$ENV_FILE"
            echo "DEMO_DB_USER=$DEMO_DB_USER" >> "$ENV_FILE"
            echo "DEMO_DB_PASSWORD=$DEMO_DB_PASSWORD" >> "$ENV_FILE"
        fi
        
        log "Demo database created: $DEMO_DB_NAME"
        log "Demo user created: $DEMO_DB_USER"
    else
        log "WARNING: PostgreSQL is not running, skipping demo database creation"
    fi
}

# Function to restart services
restart_services() {
    log "Restarting services"
    
    # Restart PostgreSQL if it's running
    if systemctl is-active postgresql > /dev/null 2>&1; then
        log "Restarting PostgreSQL"
        systemctl restart postgresql
    else
        log "WARNING: PostgreSQL is not running, skipping restart"
    fi
    
    # Restart PgBouncer if it's running
    if systemctl is-active pgbouncer > /dev/null 2>&1; then
        log "Restarting PgBouncer"
        systemctl restart pgbouncer
    else
        log "WARNING: PgBouncer is not running, skipping restart"
    fi
    
    # Restart Nginx if it's running
    if systemctl is-active nginx > /dev/null 2>&1; then
        log "Restarting Nginx"
        systemctl restart nginx
    else
        log "WARNING: Nginx is not running, skipping restart"
    fi
}

# Call the main function
main 