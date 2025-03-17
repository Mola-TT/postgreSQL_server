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
    systemctl is-active "$1" >/dev/null 2>&1
}

# Function to restart a service if it's running
restart_service() {
    if service_running "$1"; then
        log "Restarting service: $1"
        systemctl restart "$1"
    else
        log "Starting service: $1"
        systemctl start "$1"
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
    local backup="${file}.$(date +'%Y%m%d%H%M%S').bak"
    
    if [ -f "$file" ]; then
        log "Backing up file: $file to $backup"
        cp "$file" "$backup"
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