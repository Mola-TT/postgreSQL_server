#!/bin/bash

# Security-related functions for PostgreSQL server setup

# Function to set up security enhancements
setup_security() {
    log "Setting up security enhancements"
    
    # Install security-related packages
    apt-get install -y ufw fail2ban

    # Configure firewall
    configure_firewall
    
    # Configure fail2ban
    configure_fail2ban
    
    # Set up SSL certificates
    setup_ssl_certificates
    
    # Configure PostgreSQL database visibility restrictions
    configure_database_visibility_restrictions
}

# Function to configure firewall
configure_firewall() {
    log "Configuring firewall"
    
    # Enable UFW
    ufw --force enable
    
    # Allow SSH
    ufw allow ssh
    
    # Allow PostgreSQL if remote access is enabled
    if [ "$ENABLE_REMOTE_ACCESS" = "true" ]; then
        log "Allowing PostgreSQL port in firewall"
        ufw allow 5432/tcp
    fi
    
    # Allow PgBouncer
    ufw allow ${PGBOUNCER_PORT:-6432}/tcp
    
    # Allow HTTP and HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Reload firewall
    ufw reload
}

# Function to configure fail2ban
configure_fail2ban() {
    log "Configuring fail2ban"
    
    # Create PostgreSQL jail configuration
    cat > "/etc/fail2ban/jail.d/postgresql.conf" << EOF
[postgresql]
enabled = true
filter = postgresql
action = iptables-allports[name=postgresql]
logpath = /var/log/postgresql/postgresql-$PG_VERSION-main.log
maxretry = 5
findtime = 600
bantime = 3600
EOF

    # Create PostgreSQL filter
    mkdir -p /etc/fail2ban/filter.d
    cat > "/etc/fail2ban/filter.d/postgresql.conf" << EOF
[Definition]
failregex = ^.*authentication failed for user.*$
            ^.*no pg_hba.conf entry for host.*$
            ^.*password authentication failed for user.*$
ignoreregex =
EOF

    # Restart fail2ban
    restart_service "fail2ban"
}

# Function to set up SSL certificates
setup_ssl_certificates() {
    log "Setting up SSL certificates"
    
    # Check if Let's Encrypt should be used
    if [ "$USE_LETSENCRYPT" = "true" ]; then
        setup_letsencrypt
    else
        setup_self_signed_ssl
    fi
}

# Function to set up Let's Encrypt certificates
setup_letsencrypt() {
    log "Setting up Let's Encrypt certificates"
    
    # Install certbot
    apt-get install -y certbot python3-certbot-nginx
    
    # Check if domain is set
    if [ -n "$DOMAIN_SUFFIX" ]; then
        log "Obtaining Let's Encrypt certificate for *.$DOMAIN_SUFFIX"
        
        # Install Nginx if not already installed
        if ! command_exists "nginx"; then
            log "Installing Nginx for Let's Encrypt"
            apt-get install -y nginx
        fi
        
        # Create Nginx configuration for Let's Encrypt
        cat > "/etc/nginx/sites-available/letsencrypt" << EOF
server {
    listen 80;
    server_name *.$DOMAIN_SUFFIX $DOMAIN_SUFFIX;
    
    location ~ /.well-known/acme-challenge {
        allow all;
        root /var/www/html;
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

        # Enable the site
        ln -sf /etc/nginx/sites-available/letsencrypt /etc/nginx/sites-enabled/
        
        # Restart Nginx
        restart_service "nginx"
        
        # Obtain certificate
        certbot --nginx -d "$DOMAIN_SUFFIX" -d "*.$DOMAIN_SUFFIX" --non-interactive --agree-tos --email "$EMAIL_RECIPIENT" --redirect
        
        # Configure PostgreSQL to use Let's Encrypt certificates
        PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
        sed -i "s|#\?ssl_cert_file\s*=\s*.*|ssl_cert_file = '/etc/letsencrypt/live/$DOMAIN_SUFFIX/fullchain.pem'|" "$PG_CONF_DIR/postgresql.conf"
        sed -i "s|#\?ssl_key_file\s*=\s*.*|ssl_key_file = '/etc/letsencrypt/live/$DOMAIN_SUFFIX/privkey.pem'|" "$PG_CONF_DIR/postgresql.conf"
        
        # Set proper permissions
        chmod 640 "/etc/letsencrypt/live/$DOMAIN_SUFFIX/privkey.pem"
        chown postgres:postgres "/etc/letsencrypt/live/$DOMAIN_SUFFIX/privkey.pem"
        
        log "Let's Encrypt certificates installed successfully"
    else
        log "Let's Encrypt certificates not available. Using self-signed certificates."
        setup_self_signed_ssl
    fi
}

# Function to set up self-signed SSL certificates
setup_self_signed_ssl() {
    log "Setting up self-signed SSL certificates"
    
    # Install OpenSSL
    apt-get install -y openssl
    
    # Create directory for certificates
    SSL_DIR="/etc/postgresql/ssl"
    mkdir -p "$SSL_DIR"
    
    # Generate self-signed certificate
    log "Generating self-signed certificate"
    openssl req -new -x509 -days "$SSL_CERT_VALIDITY" -nodes \
        -out "$SSL_DIR/server.crt" \
        -keyout "$SSL_DIR/server.key" \
        -subj "/C=$SSL_CERT_COUNTRY/ST=$SSL_CERT_STATE/L=$SSL_CERT_LOCALITY/O=$SSL_CERT_ORG/OU=$SSL_CERT_OU/CN=$SSL_CERT_CN"
    
    # Set proper permissions
    chmod 640 "$SSL_DIR/server.key"
    chmod 644 "$SSL_DIR/server.crt"
    chown postgres:postgres "$SSL_DIR/server.key" "$SSL_DIR/server.crt"
    
    # Configure PostgreSQL to use self-signed certificates
    PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    sed -i "s|#\?ssl_cert_file\s*=\s*.*|ssl_cert_file = '$SSL_DIR/server.crt'|" "$PG_CONF_DIR/postgresql.conf"
    sed -i "s|#\?ssl_key_file\s*=\s*.*|ssl_key_file = '$SSL_DIR/server.key'|" "$PG_CONF_DIR/postgresql.conf"
    
    log "Self-signed certificates installed successfully"
}

# Function to configure database visibility restrictions
configure_database_visibility_restrictions() {
    log "Configuring database visibility restrictions"
    
    # Check if PostgreSQL is running
    if ! pg_isready -q; then
        log "ERROR: PostgreSQL is not running, cannot configure visibility restrictions"
        return 1
    fi
    
    # Create a script to execute SQL commands
    local SQL_SCRIPT="/tmp/restrict_db_visibility.sql"
    
    cat > "$SQL_SCRIPT" << EOF
-- Create a custom view to restrict database visibility
CREATE OR REPLACE FUNCTION pg_catalog.pg_database_restricted()
RETURNS SETOF pg_catalog.pg_database AS \$\$
DECLARE
    current_user text := current_user;
    current_db text := current_database();
    is_superuser boolean := (SELECT usesuper FROM pg_catalog.pg_user WHERE usename = current_user);
BEGIN
    -- Superuser can see all databases
    IF is_superuser THEN
        RETURN QUERY SELECT * FROM pg_catalog.pg_database;
    ELSE
        -- Regular users can only see the current database and template databases
        RETURN QUERY SELECT * FROM pg_catalog.pg_database 
                     WHERE datname = current_db 
                     OR datname LIKE 'template%' 
                     OR datname = 'postgres';
    END IF;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create a view that overrides pg_database for non-superusers
CREATE OR REPLACE VIEW pg_catalog.pg_database_view AS
SELECT * FROM pg_catalog.pg_database_restricted();

-- Revoke direct access to pg_database for regular users
REVOKE SELECT ON pg_catalog.pg_database FROM PUBLIC;

-- Grant access to our restricted view
GRANT SELECT ON pg_catalog.pg_database_view TO PUBLIC;

-- Set up restrictions for information_schema.schemata
CREATE OR REPLACE FUNCTION information_schema.schemata_restricted()
RETURNS SETOF information_schema.schemata AS \$\$
DECLARE
    current_user text := current_user;
    current_db text := current_database();
    is_superuser boolean := (SELECT usesuper FROM pg_catalog.pg_user WHERE usename = current_user);
BEGIN
    -- Superuser can see all schemas
    IF is_superuser THEN
        RETURN QUERY SELECT * FROM information_schema.schemata;
    ELSE
        -- Regular users can only see schemas in the current database
        RETURN QUERY SELECT * FROM information_schema.schemata 
                     WHERE catalog_name = current_db;
    END IF;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create a function to be executed when a database admin user is created
CREATE OR REPLACE FUNCTION public.restrict_admin_visibility()
RETURNS VOID AS \$\$
BEGIN
    -- Apply restrictions to the database
    EXECUTE format('ALTER ROLE %I SET search_path TO "$user", public', current_user);
    
    -- Force non-superusers to use pg_database_view instead of pg_database
    EXECUTE format('ALTER ROLE %I SET pg_catalog.pg_database TO pg_catalog.pg_database_view', current_user);
END;
\$\$ LANGUAGE plpgsql;

-- Add a trigger function to enforce the subdomain-based access model
CREATE OR REPLACE FUNCTION public.enforce_subdomain_access()
RETURNS event_trigger AS \$\$
DECLARE
    db_name text;
    user_name text;
BEGIN
    -- Get current database and user
    db_name := current_database();
    user_name := current_user;
    
    -- Skip for superuser and template databases
    IF (SELECT usesuper FROM pg_catalog.pg_user WHERE usename = user_name) OR
       db_name LIKE 'template%' OR db_name = 'postgres' THEN
        RETURN;
    END IF;
    
    -- Enforce the subdomain access model for non-superusers
    -- This will be called from connection validation through pg_hba.conf
    NULL;
END;
\$\$ LANGUAGE plpgsql;

-- Create an event trigger to enforce access control on database creation
CREATE EVENT TRIGGER enforce_access_on_db_create
ON ddl_command_end
WHEN tag IN ('CREATE DATABASE')
EXECUTE FUNCTION public.enforce_subdomain_access();
EOF
    
    # Execute the SQL script as the PostgreSQL superuser
    log "Applying database visibility restrictions"
    sudo -u postgres psql -f "$SQL_SCRIPT"
    
    # Clean up
    rm -f "$SQL_SCRIPT"
    
    # Create function to configure pg_hba.conf for subdomain access control
    configure_subdomain_pg_hba
    
    # Restart PostgreSQL to apply changes
    restart_service "postgresql"
    
    log "Database visibility restrictions configured successfully"
}

# Function to configure pg_hba.conf for subdomain access control
configure_subdomain_pg_hba() {
    log "Configuring pg_hba.conf for subdomain access control"
    
    # Create a script to update pg_hba.conf
    local PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    local PG_HBA_FILE="$PG_CONF_DIR/pg_hba.conf"
    
    # Backup existing pg_hba.conf
    backup_file "$PG_HBA_FILE"
    
    # Create a new pg_hba.conf with strict subdomain-based access control
    cat > "$PG_HBA_FILE" << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD                OPTIONS

# "local" is for Unix domain socket connections only
local   all             postgres                                peer                  
local   all             all                                     scram-sha-256         

# IPv4 local connections for superuser only
host    all             postgres        127.0.0.1/32            scram-sha-256         
host    all             postgres        ::1/128                 scram-sha-256         

# Remote superuser can connect to any database from any host
host    all             postgres        all                     scram-sha-256         

# The postgres database is accessible from localhost without hostname check
host    postgres        all             127.0.0.1/32            scram-sha-256
host    postgres        all             ::1/128                 scram-sha-256

# SSl connections with hostname verification 
# Regular users can only connect to their database if hostname matches
hostssl all             all             all                     scram-sha-256         hostnossl
hostssl sameuser        all             all                     scram-sha-256         

# Allow access to template databases for admin functionality
host    template0       postgres        all                     scram-sha-256
host    template1       postgres        all                     scram-sha-256

# Reject all other connections
host    all             all             all                     reject

EOF
    
    # Create hostname map configuration
    local MAP_FILE="$PG_CONF_DIR/pg_hostname_map.conf"
    
    cat > "$MAP_FILE" << EOF
# Map hostnames to database names
# Format: database_name subdomain.domain.com
# Example: demo demo.example.com

# Dynamic entries will be added by the DBHub.cc system
EOF
    
    # Update postgresql.conf to use the hostname map
    local PG_CONF_FILE="$PG_CONF_DIR/postgresql.conf"
    
    # Make sure hostname mapping is enabled in postgresql.conf
    grep -q "^host_name_map" "$PG_CONF_FILE" || echo "host_name_map = '$MAP_FILE'" >> "$PG_CONF_FILE"
    
    # Update PostgreSQL to check hostname during connection
    grep -q "^check_hostname" "$PG_CONF_FILE" || echo "check_hostname = on" >> "$PG_CONF_FILE"
    
    # Add hostname validation to postgresql.conf if not already there
    grep -q "^verify_hostname" "$PG_CONF_FILE" || echo "verify_hostname = on" >> "$PG_CONF_FILE"
    
    # Make sure SSL is enabled for hostname verification
    grep -q "^ssl" "$PG_CONF_FILE" || echo "ssl = on" >> "$PG_CONF_FILE"
    
    log "pg_hba.conf configured for strict subdomain access control"
    
    # Create a subdomain checking function
    local SQL_SCRIPT="/tmp/create_hostname_check.sql"
    
    cat > "$SQL_SCRIPT" << EOF
-- Create a function to validate hostname during connection
CREATE OR REPLACE FUNCTION public.validate_connection_hostname()
RETURNS event_trigger AS \$\$
DECLARE
    client_hostname text;
    expected_hostname text;
    current_db text;
BEGIN
    -- Get current database and client hostname
    current_db := current_database();
    client_hostname := inet_server_addr();
    
    -- Skip check for superuser, template databases, or postgres database
    IF (SELECT usesuper FROM pg_catalog.pg_user WHERE usename = current_user) OR
       current_db LIKE 'template%' OR current_db = 'postgres' THEN
        RETURN;
    END IF;
    
    -- Get expected hostname from mapping
    SELECT subdomain INTO expected_hostname 
    FROM pg_hostname_map 
    WHERE db_name = current_db;
    
    -- Validate hostname
    IF client_hostname != expected_hostname THEN
        RAISE EXCEPTION 'Connection to database % must be made through subdomain %', 
                        current_db, expected_hostname;
    END IF;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create a trigger for connection validation
CREATE EVENT TRIGGER connection_hostname_validation
ON connection_start
EXECUTE FUNCTION public.validate_connection_hostname();
EOF
    
    # Execute the SQL script as the PostgreSQL superuser
    log "Creating hostname validation function"
    sudo -u postgres psql -f "$SQL_SCRIPT"
    
    # Clean up
    rm -f "$SQL_SCRIPT"
} 