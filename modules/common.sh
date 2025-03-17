#!/bin/bash

# Common functions for PostgreSQL server setup

# Configuration
LOG_FILE="/var/log/dbhub_setup.log"

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to handle errors
error_handler() {
    local exit_code=$?
    local line_number=$1
    if [ $exit_code -ne 0 ]; then
        log "ERROR: Command failed at line $line_number with exit code $exit_code"
        exit $exit_code
    fi
}

# Set up error handling
trap 'error_handler $LINENO' ERR

# Function to generate a random password
generate_password() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if a package is installed
package_installed() {
    dpkg -l "$1" | grep -q "^ii" >/dev/null 2>&1
}

# Function to install a package if it's not already installed
install_package() {
    if ! package_installed "$1"; then
        log "Installing package: $1"
        apt-get install -y "$1"
    else
        log "Package already installed: $1"
    fi
}

# Function to check if a service is running
service_running() {
    local service_name="$1"
    
    # Special handling for PostgreSQL
    if [[ "$service_name" == "postgresql" ]]; then
        # First try pg_isready if available
        if command_exists pg_isready; then
            if pg_isready -q; then
                return 0
            fi
        fi
        
        # Check for specific PostgreSQL service patterns
        if systemctl list-units --state=active | grep -q "postgresql@.*\.service"; then
            return 0
        fi
    fi
    
    # Standard check for other services
    systemctl is-active "$service_name" >/dev/null 2>&1
}

# Function to restart a service if it's running
restart_service() {
    local service_name="$1"
    
    # Special handling for PostgreSQL
    if [[ "$service_name" == "postgresql" ]]; then
        log "Restarting PostgreSQL"
        
        # Try to use pg_ctlcluster if available
        if command_exists pg_ctlcluster && command_exists pg_lsclusters; then
            # Get the list of running clusters
            local clusters=$(pg_lsclusters | grep -v "down" | awk '{print $1" "$2}')
            
            if [ -n "$clusters" ]; then
                log "Restarting PostgreSQL clusters"
                while read -r version cluster; do
                    log "Restarting PostgreSQL cluster $version $cluster"
                    pg_ctlcluster "$version" "$cluster" restart
                done <<< "$clusters"
                return 0
            fi
        fi
        
        # If pg_ctlcluster failed or no clusters found, try systemctl
        if systemctl list-units --state=active | grep -q "postgresql@.*\.service"; then
            local pg_services=$(systemctl list-units --state=active | grep "postgresql@.*\.service" | awk '{print $1}')
            while read -r service; do
                log "Restarting PostgreSQL service $service"
                systemctl restart "$service"
            done <<< "$pg_services"
            return 0
        fi
        
        # Fallback to generic service
        log "Using generic PostgreSQL service"
        systemctl restart postgresql
        return 0
    fi
    
    # Standard restart for other services
    if systemctl is-active "$service_name" >/dev/null 2>&1; then
        log "Restarting service: $service_name"
        systemctl restart "$service_name"
    else
        log "Starting service: $service_name"
        systemctl start "$service_name"
    fi
}

# Function to enable a service
enable_service() {
    log "Enabling service: $1"
    systemctl enable "$1"
}

# Function to create a directory if it doesn't exist
create_directory() {
    if [ ! -d "$1" ]; then
        log "Creating directory: $1"
        mkdir -p "$1"
    fi
}

# Function to backup a file
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup_file="${file}.$(date +'%Y%m%d%H%M%S').bak"
        log "Backing up file: $file to $backup_file"
        cp "$file" "$backup_file"
    fi
}

# Function to send an email
send_email() {
    local subject="$1"
    local message="$2"
    
    if [ -n "$EMAIL_RECIPIENT" ] && [ -n "$EMAIL_SENDER" ] && [ -n "$SMTP_SERVER" ]; then
        log "Sending email to $EMAIL_RECIPIENT: $subject"
        
        # Create email content
        local email_content=$(cat <<EOF
From: $EMAIL_SENDER
To: $EMAIL_RECIPIENT
Subject: $subject
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: 8bit

$message

--
This is an automated message from your DBHub.cc server.
Time: $(date)
EOF
)
        
        # Send email using curl with SSL
        curl --url "smtps://$SMTP_SERVER:$SMTP_PORT" \
             --ssl-reqd \
             --mail-from "$EMAIL_SENDER" \
             --mail-rcpt "$EMAIL_RECIPIENT" \
             --user "$SMTP_USER:$SMTP_PASS" \
             --upload-file - <<< "$email_content"
    else
        log "Email configuration not complete, skipping email notification"
    fi
}

# Function to setup environment variables
setup_environment() {
    log "Setting up environment variables"
    
    # Check for .env file
    ENV_FILE="./.env"
    if [ -f "$ENV_FILE" ]; then
        log "Loading environment variables from $ENV_FILE"
        set -a
        source "$ENV_FILE"
        set +a
    else
        log "ERROR: Environment file $ENV_FILE not found"
        log "Please create an environment file based on .env.example"
        exit 1
    fi
    
    # Backup environment file
    ENV_BACKUP_DIR="./.env_backups"
    mkdir -p "$ENV_BACKUP_DIR"
    ENV_BACKUP_FILE="$ENV_BACKUP_DIR/.env.$(date +'%Y%m%d%H%M%S')"
    log "Backing up environment file"
    cp "$ENV_FILE" "$ENV_BACKUP_FILE"
    
    # Set permissions on environment files
    chmod 600 "$ENV_FILE"
    chmod 600 "$ENV_BACKUP_FILE"
} 