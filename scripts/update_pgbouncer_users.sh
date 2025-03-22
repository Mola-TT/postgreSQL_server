#!/bin/bash

# Update PgBouncer Users Script
# This script synchronizes PostgreSQL users with PgBouncer's authentication file

# Exit on error
set -e

# Configuration variables
PGBOUNCER_USERLIST="/etc/pgbouncer/userlist.txt"
PGBOUNCER_CONFIG="/etc/pgbouncer/pgbouncer.ini"
LOG_FILE="/var/log/dbhub/update_pgbouncer_users.log"

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: This script must be run as root or with sudo privileges."
    exit 1
fi

# Function to get SCRAM hash for PostgreSQL user
get_user_hash() {
    local username="$1"
    # Pipe output through xargs to trim whitespace completely
    sudo -u postgres psql -t -c "SELECT concat('SCRAM-SHA-256$', split_part(rolpassword, '$', 2), '$', split_part(rolpassword, '$', 3), '$', split_part(rolpassword, '$', 4)) FROM pg_authid WHERE rolname='$username';" | xargs
}

# Function to update a single user in the PgBouncer userlist
update_single_user() {
    local username="$1"
    local action="$2"  # add, update, delete
    
    log "Processing single user: $username (action: $action)"
    
    # Create backup of current userlist
    if [ -f "$PGBOUNCER_USERLIST" ]; then
        local backup_file="${PGBOUNCER_USERLIST}.$(date +'%Y%m%d%H%M%S').bak"
        log "Creating backup of existing userlist: $backup_file"
        cp "$PGBOUNCER_USERLIST" "$backup_file"
    fi
    
    case "$action" in
        add|update)
            # Get password hash and ensure it's properly trimmed
            local password_hash=$(get_user_hash "$username")
            
            # Skip if password hash is empty
            if [ -z "$password_hash" ]; then
                log "Warning: No password hash found for user $username, skipping"
                return 1
            fi
            
            # Check if user exists in userlist
            if grep -q "^\"$username\"" "$PGBOUNCER_USERLIST"; then
                # Update existing user
                sed -i "/^\"$username\"/c\\\"$username\" \"$password_hash\"" "$PGBOUNCER_USERLIST"
                log "Updated existing user $username in PgBouncer userlist"
            else
                # Add new user
                echo "\"$username\" \"$password_hash\"" >> "$PGBOUNCER_USERLIST"
                log "Added user $username to PgBouncer userlist"
            fi
            ;;
        delete)
            # Remove user from userlist
            sed -i "/^\"$username\"/d" "$PGBOUNCER_USERLIST"
            log "Removed user $username from PgBouncer userlist"
            ;;
        *)
            log "ERROR: Unknown action '$action' for update_single_user"
            return 1
            ;;
    esac
    
    # Fix permissions
    chown postgres:postgres "$PGBOUNCER_USERLIST"
    chmod 640 "$PGBOUNCER_USERLIST"
    
    log "Single user update completed: $username"
    return 0
}

# Function to update all users in the PgBouncer userlist
update_userlist() {
    log "Updating PgBouncer userlist with all PostgreSQL users"
    
    # Create backup of current userlist
    if [ -f "$PGBOUNCER_USERLIST" ]; then
        local backup_file="${PGBOUNCER_USERLIST}.$(date +'%Y%m%d%H%M%S').bak"
        log "Creating backup of existing userlist: $backup_file"
        cp "$PGBOUNCER_USERLIST" "$backup_file"
    fi
    
    # Get list of PostgreSQL users
    log "Getting list of PostgreSQL users"
    local users=$(sudo -u postgres psql -t -c "SELECT rolname FROM pg_roles WHERE rolcanlogin;" | grep -v "^\s*$" | xargs -n1)
    
    # Create new userlist file
    echo "# PgBouncer userlist - Updated on $(date)" > "$PGBOUNCER_USERLIST.new"
    
    # Add users to userlist file
    log "Adding users to PgBouncer userlist"
    for username in $users; do
        # Skip if username is empty
        if [ -z "$username" ]; then
            continue
        fi
        
        # Get password hash (properly trimmed with xargs)
        local password_hash=$(get_user_hash "$username")
        
        # Skip if password hash is empty
        if [ -z "$password_hash" ]; then
            log "Warning: No password hash found for user $username, skipping"
            continue
        fi
        
        # Add user to userlist
        echo "\"$username\" \"$password_hash\"" >> "$PGBOUNCER_USERLIST.new"
        log "Added user $username to PgBouncer userlist"
    done
    
    # Replace old userlist with new one
    mv "$PGBOUNCER_USERLIST.new" "$PGBOUNCER_USERLIST"
    chown postgres:postgres "$PGBOUNCER_USERLIST"
    chmod 640 "$PGBOUNCER_USERLIST"
    
    log "PgBouncer userlist updated successfully"
}

# After updating the userlist, verify it's valid
verify_userlist() {
    log "Verifying PgBouncer userlist format"
    
    # Check if file exists
    if [ ! -f "$PGBOUNCER_USERLIST" ]; then
        log "ERROR: PgBouncer userlist file not found at $PGBOUNCER_USERLIST"
        return 1
    fi
    
    # Check each line in the userlist file
    local line_num=0
    local has_error=false
    
    while IFS= read -r line; do
        ((line_num++))
        
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# || -z "${line// /}" ]]; then
            continue
        fi
        
        # Validate line format - should be "username" "password"
        if ! [[ "$line" =~ ^\"[^\"]+\"[[:space:]]+\"[^\"]+\"$ ]]; then
            log "ERROR: Invalid format in userlist at line $line_num: $line"
            has_error=true
        fi
    done < "$PGBOUNCER_USERLIST"
    
    if [ "$has_error" = true ]; then
        log "WARNING: Found formatting issues in userlist file"
        
        # Create a clean backup just in case
        local backup_file="${PGBOUNCER_USERLIST}.malformed.$(date +'%Y%m%d%H%M%S').bak"
        cp "$PGBOUNCER_USERLIST" "$backup_file"
        log "Created backup of problematic userlist: $backup_file"
        
        # Try to fix common formatting issues
        log "Attempting to fix formatting issues..."
        sed -i 's/^"\([^"]*\)" "\s\+\([^"]*\)"$/"\1" "\2"/g' "$PGBOUNCER_USERLIST"
        
        log "Fixed potential formatting issues in userlist"
        return 1
    else
        log "PgBouncer userlist format verified successfully"
        return 0
    fi
}

# Function to ensure auth_type is set to scram-sha-256
update_auth_type() {
    log "Checking PgBouncer authentication configuration"
    
    # Create backup of current configuration
    if [ -f "$PGBOUNCER_CONFIG" ]; then
        local backup_file="${PGBOUNCER_CONFIG}.$(date +'%Y%m%d%H%M%S').bak"
        log "Creating backup of existing configuration: $backup_file"
        cp "$PGBOUNCER_CONFIG" "$backup_file"
    else
        log "ERROR: PgBouncer configuration file not found at $PGBOUNCER_CONFIG"
        return 1
    fi
    
    # Check if auth_type is already set to scram-sha-256
    if grep -q "^auth_type.*=.*scram-sha-256" "$PGBOUNCER_CONFIG"; then
        log "PgBouncer already configured to use SCRAM-SHA-256 authentication"
    else
        log "Updating PgBouncer to use SCRAM-SHA-256 authentication"
        
        # Update auth_type if it exists, or add it if it doesn't
        if grep -q "^auth_type" "$PGBOUNCER_CONFIG"; then
            sed -i "s/^auth_type.*$/auth_type = scram-sha-256/" "$PGBOUNCER_CONFIG"
        else
            sed -i "/^\[pgbouncer\]/a auth_type = scram-sha-256" "$PGBOUNCER_CONFIG"
        fi
    fi
    
    # Check if auth_query is set
    if grep -q "^auth_query" "$PGBOUNCER_CONFIG"; then
        log "PgBouncer auth_query already configured"
    else
        log "Adding auth_query for SASL authentication support"
        sed -i "/^\[pgbouncer\]/a auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=\$1\nauth_user = postgres" "$PGBOUNCER_CONFIG"
    fi
    
    log "PgBouncer authentication configuration updated"
}

# Function to reload PgBouncer
reload_pgbouncer() {
    log "Reloading PgBouncer to apply changes"
    if systemctl is-active --quiet pgbouncer; then
        systemctl reload pgbouncer || systemctl restart pgbouncer
        
        # Verify PgBouncer is running
        if systemctl is-active --quiet pgbouncer; then
            log "PgBouncer successfully reloaded"
            return 0
        else
            log "ERROR: PgBouncer failed to reload. Checking logs..."
            journalctl -u pgbouncer --no-pager -n 20
            return 1
        fi
    else
        log "PgBouncer is not running. Starting PgBouncer..."
        systemctl start pgbouncer
        
        # Verify PgBouncer started
        if systemctl is-active --quiet pgbouncer; then
            log "PgBouncer successfully started"
            return 0
        else
            log "ERROR: PgBouncer failed to start. Checking logs..."
            journalctl -u pgbouncer --no-pager -n 20
            return 1
        fi
    fi
}

# Function to show usage
usage() {
    echo "Usage: $0 [OPTION] [ARGUMENTS]"
    echo "Update PgBouncer users from PostgreSQL."
    echo
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -u, --user USERNAME     Update a single user (needs -a action)"
    echo "  -a, --action ACTION     Action for single user: add, update, delete"
    echo "  -s, --skip-reload       Skip reloading PgBouncer after update"
    echo "  -q, --quiet             Suppress output except for errors"
    echo "  -f, --fix-userlist      Fix formatting issues in userlist file without updating users"
    echo
    echo "Examples:"
    echo "  $0                      Update all users (default behavior)"
    echo "  $0 -u myuser -a add     Add or update a single user"
    echo "  $0 -u myuser -a delete  Remove a user from PgBouncer"
    echo "  $0 -s                   Update all users but don't reload PgBouncer"
    echo "  $0 -f                   Fix formatting issues in userlist.txt only"
}

# Main function
main() {
    local single_user=""
    local action=""
    local skip_reload=false
    local quiet_mode=false
    local fix_userlist=false
    
    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -u|--user)
                if [[ -z "$2" || "$2" == -* ]]; then
                    log "ERROR: Option -u requires an argument"
                    usage
                    exit 1
                fi
                single_user="$2"
                shift 2
                ;;
            -a|--action)
                if [[ -z "$2" || "$2" == -* ]]; then
                    log "ERROR: Option -a requires an argument"
                    usage
                    exit 1
                fi
                action="$2"
                if [[ "$action" != "add" && "$action" != "update" && "$action" != "delete" ]]; then
                    log "ERROR: Invalid action: $action. Must be add, update, or delete"
                    usage
                    exit 1
                fi
                shift 2
                ;;
            -s|--skip-reload)
                skip_reload=true
                shift
                ;;
            -q|--quiet)
                quiet_mode=true
                shift
                ;;
            -f|--fix-userlist)
                fix_userlist=true
                shift
                ;;
            *)
                log "ERROR: Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # If in quiet mode, redirect logs to file only
    if [ "$quiet_mode" = true ]; then
        # Redefine log function to only write to file
        log() {
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
        }
    fi
    
    log "Starting PgBouncer users update"
    
    # If requested to fix userlist only, do that and exit
    if [ "$fix_userlist" = true ]; then
        log "Running in fix userlist mode only"
        verify_userlist
        
        # Reload PgBouncer if not skipped
        if [ "$skip_reload" = false ]; then
            reload_pgbouncer
        else
            log "Skipping PgBouncer reload as requested"
        fi
        
        log "PgBouncer userlist fix completed"
        exit 0
    fi
    
    # Update authentication configuration (always do this)
    update_auth_type
    
    # Process based on arguments
    if [ -n "$single_user" ]; then
        # Single user mode
        if [ -z "$action" ]; then
            log "ERROR: When specifying a user, an action (-a) must also be provided"
            usage
            exit 1
        fi
        
        log "Processing single user mode for $single_user with action $action"
        update_single_user "$single_user" "$action"
    else
        # Full update mode
        log "Processing all users mode"
        update_userlist
    fi
    
    # Always verify the userlist after updating
    verify_userlist
    
    # Reload PgBouncer if not skipped
    if [ "$skip_reload" = false ]; then
        reload_pgbouncer
    else
        log "Skipping PgBouncer reload as requested"
    fi
    
    log "PgBouncer users update completed"
}

# Run main function with all command-line arguments
main "$@"

exit 0 