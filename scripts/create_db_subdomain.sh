#!/bin/bash
# Database Subdomain Management Script
# Creates and manages Nginx configurations for database subdomains

# Log file
LOG_FILE="/var/log/db-subdomain.log"
NGINX_SITES="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
TEMPLATE_FILE="$NGINX_SITES/db-subdomain-template"
PG_VERSION=$(ls /etc/postgresql/ | sort -V | tail -n1)

# Load environment variables
ENV_FILES=("/etc/dbhub/.env" "/opt/dbhub/.env" "$(dirname "$0")/../.env" ".env")
for ENV_FILE in "${ENV_FILES[@]}"; do
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        break
    fi
done

# Set default domain suffix if not in environment
if [[ -z "$DOMAIN_SUFFIX" ]]; then
    DOMAIN_SUFFIX="example.com"
fi

# Logging function
log() {
    echo "[$(TZ=Asia/Singapore date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Create log file if it doesn't exist
if [[ ! -f "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
fi

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log "ERROR: This script must be run as root"
    exit 1
fi

# Check if Nginx is installed
if ! command -v nginx &> /dev/null; then
    log "ERROR: Nginx is not installed"
    exit 1
fi

# Create template if it doesn't exist
create_template() {
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        log "Creating Nginx template for database subdomains"
        cat > "$TEMPLATE_FILE" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name {{DB_NAME}}.$DOMAIN_SUFFIX;

    access_log /var/log/nginx/{{DB_NAME}}-access.log;
    error_log /var/log/nginx/{{DB_NAME}}-error.log;

    # Security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass http://localhost:5432;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Database name header
        proxy_set_header X-DB-Name "{{DB_NAME}}";
    }

    # Redirect to HTTPS if SSL is enabled
    if (\$scheme = http) {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS server block will be added by Let's Encrypt if enabled
EOF
        log "Template created at $TEMPLATE_FILE"
    fi
}

# Create subdomain for a database
create_subdomain() {
    DB_NAME="$1"
    
    # Validate database name
    if [[ -z "$DB_NAME" ]]; then
        log "ERROR: Database name is required"
        exit 1
    fi
    
    # Check if database exists
    if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        log "ERROR: Database '$DB_NAME' does not exist"
        exit 1
    fi
    
    # Create config file
    CONFIG_FILE="$NGINX_SITES/$DB_NAME.$DOMAIN_SUFFIX"
    
    # Check if config already exists
    if [[ -f "$CONFIG_FILE" ]]; then
        log "WARNING: Configuration for $DB_NAME.$DOMAIN_SUFFIX already exists"
        return 0
    fi
    
    log "Creating subdomain configuration for $DB_NAME.$DOMAIN_SUFFIX"
    
    # Create from template
    sed "s/{{DB_NAME}}/$DB_NAME/g" "$TEMPLATE_FILE" > "$CONFIG_FILE"
    
    # Enable site
    ln -sf "$CONFIG_FILE" "$NGINX_ENABLED/"
    
    # Test Nginx configuration
    if nginx -t; then
        log "Nginx configuration for $DB_NAME.$DOMAIN_SUFFIX is valid"
        systemctl reload nginx
        log "Subdomain $DB_NAME.$DOMAIN_SUFFIX has been created and enabled"
    else
        log "ERROR: Nginx configuration for $DB_NAME.$DOMAIN_SUFFIX is invalid"
        rm -f "$CONFIG_FILE" "$NGINX_ENABLED/$(basename "$CONFIG_FILE")"
        exit 1
    fi
}

# Create subdomains for all databases
create_all_subdomains() {
    log "Creating subdomains for all databases"
    
    # Get list of all databases
    DATABASES=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';")
    
    # Create subdomain for each database
    for DB in $DATABASES; do
        create_subdomain "$DB"
    done
    
    log "All database subdomains have been created"
}

# Setup PostgreSQL trigger for automatic subdomain creation
setup_trigger() {
    log "Setting up PostgreSQL trigger for automatic subdomain creation"
    
    # Check if PostgreSQL is running
    if ! systemctl is-active --quiet postgresql; then
        log "ERROR: PostgreSQL service is not running"
        exit 1
    fi
    
    # Create function and trigger
    sudo -u postgres psql -c "
    CREATE OR REPLACE FUNCTION create_subdomain_for_db() RETURNS event_trigger AS \$\$
    DECLARE
        db_name text;
    BEGIN
        SELECT object_identity INTO db_name FROM pg_event_trigger_ddl_commands() WHERE command_tag = 'CREATE DATABASE';
        IF db_name IS NOT NULL THEN
            db_name := replace(db_name, '\"', '');
            EXECUTE 'NOTIFY db_created, ''' || db_name || '''';
        END IF;
    END;
    \$\$ LANGUAGE plpgsql;
    
    DROP EVENT TRIGGER IF EXISTS db_creation_trigger;
    CREATE EVENT TRIGGER db_creation_trigger ON ddl_command_end
    WHEN TAG IN ('CREATE DATABASE')
    EXECUTE PROCEDURE create_subdomain_for_db();
    " postgres
    
    # Create listener script
    LISTENER_SCRIPT="/usr/local/bin/db_subdomain_listener.sh"
    cat > "$LISTENER_SCRIPT" << 'EOF'
#!/bin/bash
# PostgreSQL database creation listener
# Automatically creates subdomains when new databases are created

LOG_FILE="/var/log/db-subdomain.log"

log() {
    echo "[$(TZ=Asia/Singapore date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting database creation listener"

# Listen for database creation notifications
sudo -u postgres psql -c "LISTEN db_created;" postgres &

# Process notifications
while read -r line; do
    if [[ "$line" == *"db_created"* ]]; then
        DB_NAME=$(echo "$line" | grep -oP "db_created, \K[^)]*" | tr -d "'")
        log "Received notification for new database: $DB_NAME"
        /usr/local/bin/create_db_subdomain.sh create "$DB_NAME"
    fi
done < <(sudo -u postgres psql -c "LISTEN db_created; SELECT pg_sleep(100000);" postgres 2>&1)
EOF
    
    chmod +x "$LISTENER_SCRIPT"
    
    # Create systemd service for listener
    cat > /etc/systemd/system/db-subdomain-listener.service << EOF
[Unit]
Description=Database Subdomain Listener
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
ExecStart=/usr/local/bin/db_subdomain_listener.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    # Enable and start the service
    systemctl daemon-reload
    systemctl enable db-subdomain-listener
    systemctl start db-subdomain-listener
    
    log "Automatic subdomain creation has been set up"
}

# Remove subdomain for a database
remove_subdomain() {
    DB_NAME="$1"
    
    # Validate database name
    if [[ -z "$DB_NAME" ]]; then
        log "ERROR: Database name is required"
        exit 1
    fi
    
    CONFIG_FILE="$NGINX_SITES/$DB_NAME.$DOMAIN_SUFFIX"
    ENABLED_LINK="$NGINX_ENABLED/$DB_NAME.$DOMAIN_SUFFIX"
    
    # Check if config exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "WARNING: Configuration for $DB_NAME.$DOMAIN_SUFFIX does not exist"
        return 0
    fi
    
    log "Removing subdomain configuration for $DB_NAME.$DOMAIN_SUFFIX"
    
    # Remove symlink and config
    rm -f "$ENABLED_LINK" "$CONFIG_FILE"
    
    # Reload Nginx
    systemctl reload nginx
    
    log "Subdomain $DB_NAME.$DOMAIN_SUFFIX has been removed"
}

# Display usage information
usage() {
    echo "Usage: $0 COMMAND [OPTIONS]"
    echo
    echo "Commands:"
    echo "  create DB_NAME       Create subdomain for a specific database"
    echo "  create-all           Create subdomains for all existing databases"
    echo "  remove DB_NAME       Remove subdomain for a specific database"
    echo "  setup-trigger        Setup automatic subdomain creation on database creation"
    echo "  help                 Display this help message"
    echo
    echo "Examples:"
    echo "  $0 create mydb       Create subdomain for 'mydb' database"
    echo "  $0 create-all        Create subdomains for all databases"
    echo "  $0 remove mydb       Remove subdomain for 'mydb' database"
    echo "  $0 setup-trigger     Setup automatic subdomain creation"
}

# Main script logic
case "$1" in
    create)
        create_template
        create_subdomain "$2"
        ;;
    create-all)
        create_template
        create_all_subdomains
        ;;
    remove)
        remove_subdomain "$2"
        ;;
    setup-trigger)
        create_template
        setup_trigger
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac

exit 0 