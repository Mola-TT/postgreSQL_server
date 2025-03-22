# Common functions module
# Contains shared utility functions for the DBHub.cc scripts

# Set default values
DEFAULT_DOMAIN="dbhub.cc"
DEFAULT_LOG_FILE="/var/log/dbhub/operations.log"

# Initialize the script environment
init_environment() {
    # Ensure the log directory exists
    if [ ! -d "$(dirname "$DEFAULT_LOG_FILE")" ]; then
        mkdir -p "$(dirname "$DEFAULT_LOG_FILE")"
        chmod 755 "$(dirname "$DEFAULT_LOG_FILE")"
    fi
    
    # Set up error handling
    set -o pipefail
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "WARNING: This script should typically be run with root privileges"
    fi
}

# Logging function
log() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local log_message="[${timestamp}] ${message}"
    
    # Print to stdout
    echo "$log_message"
    
    # Write to log file if writable
    if [ -w "$(dirname "$DEFAULT_LOG_FILE")" ]; then
        echo "$log_message" >> "$DEFAULT_LOG_FILE"
    fi
}

# Display a banner with version information
show_banner() {
    local script_name="${1:-Script}"
    local version="${2:-1.0.0}"
    
    echo "=============================================="
    echo "  DBHub.cc - $script_name v$version"
    echo "=============================================="
    echo "  Server: $(hostname)"
    echo "  Date: $(date)"
    echo "  User: $(whoami)"
    echo "=============================================="
    echo ""
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if a service is running
service_is_running() {
    local service_name="$1"
    
    if command_exists systemctl; then
        systemctl is-active --quiet "$service_name"
    elif command_exists service; then
        service "$service_name" status >/dev/null 2>&1
    else
        ps aux | grep -v grep | grep -q "$service_name"
    fi
}

# Run a command with error handling
run_command() {
    local cmd="$1"
    local error_msg="${2:-Command failed}"
    
    log "Executing: $cmd"
    
    # Run the command
    eval "$cmd"
    local result=$?
    
    # Check result
    if [ $result -ne 0 ]; then
        log "ERROR: $error_msg (exit code: $result)"
        return $result
    fi
    
    return 0
}

# Check if a file exists and is readable
file_exists_readable() {
    local file_path="$1"
    
    if [ -f "$file_path" ] && [ -r "$file_path" ]; then
        return 0
    else
        return 1
    fi
}

# Check if a directory exists and is writable
dir_exists_writable() {
    local dir_path="$1"
    
    if [ -d "$dir_path" ] && [ -w "$dir_path" ]; then
        return 0
    else
        return 1
    fi
}

# Create a backup of a file with timestamp
backup_file() {
    local file_path="$1"
    local backup_dir="${2:-/var/backups/dbhub}"
    
    # Ensure backup directory exists
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir"
        chmod 755 "$backup_dir"
    fi
    
    # Check if file exists
    if [ ! -f "$file_path" ]; then
        log "WARNING: Cannot backup non-existent file: $file_path"
        return 1
    fi
    
    # Create backup with timestamp
    local timestamp=$(date "+%Y%m%d%H%M%S")
    local filename=$(basename "$file_path")
    local backup_path="${backup_dir}/${filename}.${timestamp}.bak"
    
    cp -p "$file_path" "$backup_path"
    
    if [ $? -eq 0 ]; then
        log "Created backup: $backup_path"
        return 0
    else
        log "ERROR: Failed to create backup of $file_path"
        return 1
    fi
}

# Wait for a service to be ready
wait_for_service() {
    local service_name="$1"
    local max_wait="${2:-60}"  # Default timeout 60 seconds
    local check_cmd="${3:-service_is_running $service_name}"
    
    log "Waiting for $service_name to be ready (timeout: ${max_wait}s)"
    
    local counter=0
    while [ $counter -lt $max_wait ]; do
        if eval "$check_cmd"; then
            log "$service_name is ready"
            return 0
        fi
        
        counter=$((counter + 1))
        sleep 1
    done
    
    log "ERROR: Timeout waiting for $service_name"
    return 1
}

# Check if a port is in use
port_is_used() {
    local port="$1"
    
    if command_exists netstat; then
        netstat -tuln | grep -q ":$port "
    elif command_exists ss; then
        ss -tuln | grep -q ":$port "
    else
        return 1  # Cannot determine
    fi
}

# Get OS type and version
get_os_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "OS: $NAME $VERSION_ID"
    elif command_exists lsb_release; then
        echo "OS: $(lsb_release -sd)"
    else
        echo "OS: $(uname -s) $(uname -r)"
    fi
}

# Parse configuration file
parse_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log "WARNING: Configuration file not found: $config_file"
        return 1
    fi
    
    # Read configuration file line by line
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        if [[ "$key" =~ ^[[:space:]]*# ]] || [[ -z "$key" ]]; then
            continue
        fi
        
        # Trim whitespace
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | tr -d '[:space:]')
        
        # Export the variable
        export "$key"="$value"
    done < "$config_file"
    
    log "Configuration loaded from $config_file"
    return 0
}

# Initialize the environment if this script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    init_environment
    show_banner "Common Utilities" "1.0.0"
fi 