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
    
    # Set up SSL certificates
    if [ "$ENABLE_SSL" = "true" ]; then
        setup_ssl
    else
        log "SSL setup skipped (set ENABLE_SSL=true to enable)"
    fi
    
    # Set up subdomain routing
    if [ "$ENABLE_SUBDOMAIN_ROUTING" = "true" ]; then
        setup_subdomain_routing
    else
        log "Subdomain routing skipped (set ENABLE_SUBDOMAIN_ROUTING=true to enable)"
    fi
    
    # Create demo database and user
    if [ "$CREATE_DEMO_DB" = "true" ]; then
        create_demo_database
    else
        log "Demo database creation skipped (set CREATE_DEMO_DB=true to enable)"
    fi
    
    # Restart services
    restart_services
    
    # Create connection info file
    create_connection_info
    
    log "PostgreSQL server initialization completed successfully"
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

# Function to set up SSL certificates
setup_ssl() {
    log "Setting up SSL certificates"
    
    # Check if Let's Encrypt is enabled
    if [ "$USE_LETSENCRYPT" = "true" ]; then
        log "Setting up Let's Encrypt certificates"
        
        # Install certbot and dependencies
        apt-get update
        apt-get install -y certbot python3-certbot-nginx
        
        # Check if we need a wildcard certificate
        if [[ "$DOMAIN" == *"*"* ]]; then
            log "Wildcard domain detected: $DOMAIN"
            log "Obtaining Let's Encrypt certificate for $DOMAIN"
            
            # For wildcard certificates, we need to use DNS validation
            if command_exists certbot && certbot plugins | grep -q dns-cloudflare; then
                log "Using Cloudflare DNS validation for wildcard certificate"
                certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.cloudflare/credentials.ini -d "$DOMAIN" -d "${DOMAIN#\*.}"
            elif command_exists certbot && certbot plugins | grep -q dns-digitalocean; then
                log "Using DigitalOcean DNS validation for wildcard certificate"
                certbot certonly --dns-digitalocean --dns-digitalocean-credentials /root/.digitalocean/credentials.ini -d "$DOMAIN" -d "${DOMAIN#\*.}"
            else
                log "WARNING: Wildcard certificates require DNS validation"
                log "Please install a DNS plugin for certbot and configure it"
                log "Example: apt-get install python3-certbot-dns-cloudflare"
                log "Falling back to non-wildcard certificate"
                
                # Fall back to a non-wildcard certificate
                DOMAIN="${DOMAIN#\*.}"
                certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL_RECIPIENT"
            fi
        else
            log "Obtaining Let's Encrypt certificate for $DOMAIN"
            certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL_RECIPIENT"
        fi
        
        # Check if certificate was obtained successfully
        if [ -d "/etc/letsencrypt/live/$DOMAIN" ] || [ -d "/etc/letsencrypt/live/${DOMAIN#\*.}" ]; then
            log "Let's Encrypt certificates installed successfully"
            
            # Set permissions for PostgreSQL to read the certificates
            CERT_DIR="/etc/letsencrypt/live/${DOMAIN#\*.}"
            if [ -d "$CERT_DIR" ]; then
                chmod 750 "$CERT_DIR"
                chmod 640 "$CERT_DIR/privkey.pem"
                chown root:postgres "$CERT_DIR/privkey.pem"
                
                # Update PostgreSQL configuration to use Let's Encrypt certificates
                PG_CONF_FILE="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
                if [ -f "$PG_CONF_FILE" ]; then
                    sed -i "s|#\?ssl_cert_file\s*=\s*.*|ssl_cert_file = '$CERT_DIR/fullchain.pem'|" "$PG_CONF_FILE"
                    sed -i "s|#\?ssl_key_file\s*=\s*.*|ssl_key_file = '$CERT_DIR/privkey.pem'|" "$PG_CONF_FILE"
                    log "PostgreSQL configured to use Let's Encrypt certificates"
                fi
            else
                log "WARNING: Let's Encrypt certificate directory not found"
            fi
        else
            log "WARNING: Let's Encrypt certificate installation failed"
            log "Generating self-signed certificate as fallback"
            generate_self_signed_cert
        fi
    else
        log "Using self-signed certificates"
        generate_self_signed_cert
    fi
}

# Function to generate a self-signed certificate
generate_self_signed_cert() {
    log "Generating self-signed SSL certificate"
    
    # Create directory for certificates
    CERT_DIR="/etc/ssl/postgresql"
    mkdir -p "$CERT_DIR"
    
    # Generate self-signed certificate
    openssl req -new -x509 -days "$SSL_CERT_DAYS" -nodes \
        -out "$CERT_DIR/server.crt" \
        -keyout "$CERT_DIR/server.key" \
        -subj "/C=$SSL_COUNTRY/ST=$SSL_STATE/L=$SSL_LOCALITY/O=$SSL_ORGANIZATION/CN=$DOMAIN"
    
    # Set permissions
    chmod 640 "$CERT_DIR/server.key"
    chmod 644 "$CERT_DIR/server.crt"
    chown postgres:postgres "$CERT_DIR/server.key"
    
    # Update PostgreSQL configuration
    PG_CONF_FILE="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    if [ -f "$PG_CONF_FILE" ]; then
        sed -i "s|#\?ssl_cert_file\s*=\s*.*|ssl_cert_file = '$CERT_DIR/server.crt'|" "$PG_CONF_FILE"
        sed -i "s|#\?ssl_key_file\s*=\s*.*|ssl_key_file = '$CERT_DIR/server.key'|" "$PG_CONF_FILE"
        log "PostgreSQL configured to use self-signed certificate"
    fi
}

# Function to create a demo database and user
create_demo_database() {
    log "Creating demo database and user"
    
    # Check if PostgreSQL is running
    if pg_isready -q; then
        # Create demo database and user
        create_restricted_user "$DEMO_DB_NAME" "$DEMO_DB_USER" "$DEMO_DB_PASSWORD"
        
        log "Demo database created: $DEMO_DB_NAME"
        log "Demo user created: $DEMO_DB_USER"
    else
        log "WARNING: PostgreSQL is not running, skipping demo database creation"
        
        # Try to start PostgreSQL
        log "Attempting to start PostgreSQL"
        if pg_lsclusters | grep -q "$PG_VERSION main"; then
            pg_ctlcluster $PG_VERSION main start
            sleep 5
            
            if pg_isready -q; then
                log "PostgreSQL started, creating demo database"
                create_restricted_user "$DEMO_DB_NAME" "$DEMO_DB_USER" "$DEMO_DB_PASSWORD"
                
                log "Demo database created: $DEMO_DB_NAME"
                log "Demo user created: $DEMO_DB_USER"
            else
                log "ERROR: Failed to start PostgreSQL, demo database not created"
            fi
        else
            log "ERROR: No PostgreSQL cluster found, demo database not created"
        fi
    fi
}

# Function to restart services
restart_services() {
    log "Restarting services"
    
    # Restart PostgreSQL
    log "Restarting PostgreSQL"
    if pg_lsclusters | grep -q "$PG_VERSION main"; then
        pg_ctlcluster $PG_VERSION main restart
    else
        if systemctl list-units --state=active | grep -q "postgresql@.*\.service"; then
            local pg_services=$(systemctl list-units --state=active | grep "postgresql@.*\.service" | awk '{print $1}')
            while read -r service; do
                log "Restarting PostgreSQL service $service"
                systemctl restart "$service"
            done <<< "$pg_services"
        else
            log "Attempting to restart postgresql service"
            systemctl restart postgresql || log "WARNING: Failed to restart PostgreSQL"
        fi
    fi
    
    # Restart PgBouncer if it's running
    if systemctl is-active pgbouncer > /dev/null 2>&1; then
        log "Restarting PgBouncer"
        systemctl restart pgbouncer
    else
        log "Starting PgBouncer"
        systemctl start pgbouncer || log "WARNING: Failed to start PgBouncer"
    fi
    
    # Restart Nginx if it's running
    if systemctl is-active nginx > /dev/null 2>&1; then
        log "Restarting Nginx"
        systemctl restart nginx
    else
        if [ "$ENABLE_SUBDOMAIN_ROUTING" = "true" ]; then
            log "Starting Nginx"
            systemctl start nginx || log "WARNING: Failed to start Nginx"
        else
            log "Nginx not needed, skipping restart"
        fi
    fi
    
    # Verify PostgreSQL is running
    if pg_isready -q; then
        log "PostgreSQL is running"
    else
        log "WARNING: PostgreSQL may not be running after restart"
        log "Current PostgreSQL cluster status:"
        pg_lsclusters
    fi
}

# Function to create connection info file
create_connection_info() {
    log "Creating connection information file"
    
    # Create connection info file
    CONNECTION_INFO_FILE="connection_info.txt"
    cat > "$CONNECTION_INFO_FILE" << EOF
PostgreSQL Server Connection Information
=======================================

PostgreSQL Version: $PG_VERSION
Host: $(hostname -f)
Port: 5432
SSL: $([ "$ENABLE_SSL" = "true" ] && echo "Enabled" || echo "Disabled")

Admin Connection:
----------------
Username: postgres
Password: $PG_PASSWORD
Connection String: postgresql://postgres:$PG_PASSWORD@$(hostname -f):5432/postgres

PgBouncer Connection:
-------------------
Port: 6432
Connection String: postgresql://postgres:$PG_PASSWORD@$(hostname -f):6432/postgres

$(if [ "$CREATE_DEMO_DB" = "true" ]; then
echo "Demo Database:
-------------
Database: $DEMO_DB_NAME
Username: $DEMO_DB_USER
Password: $DEMO_DB_PASSWORD
Connection String: postgresql://$DEMO_DB_USER:$DEMO_DB_PASSWORD@$(hostname -f):5432/$DEMO_DB_NAME
PgBouncer Connection String: postgresql://$DEMO_DB_USER:$DEMO_DB_PASSWORD@$(hostname -f):6432/$DEMO_DB_NAME"
fi)

$(if [ "$ENABLE_SUBDOMAIN_ROUTING" = "true" ]; then
echo "Subdomain Routing:
-----------------
Domain Suffix: $DOMAIN_SUFFIX
Demo Database URL: $DEMO_DB_NAME.$DOMAIN_SUFFIX"
fi)

Monitoring:
----------
Prometheus: http://$(hostname -f):9090
Grafana: http://$(hostname -f):3000 (admin/admin)
Node Exporter: http://$(hostname -f):9100
PostgreSQL Exporter: http://$(hostname -f):9187

Generated: $(date +'%Y-%m-%d %H:%M:%S')
EOF
    
    # Set permissions
    chmod 600 "$CONNECTION_INFO_FILE"
    
    log "Connection information saved to $CONNECTION_INFO_FILE"
}

# Call the main function
main 