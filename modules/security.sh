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