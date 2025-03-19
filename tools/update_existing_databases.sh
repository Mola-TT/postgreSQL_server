#!/bin/bash

# Update Existing Databases Script
# This script applies the enhanced subdomain access control to all existing databases

# Source common functions if available
if [ -f "../modules/common.sh" ]; then
    source "../modules/common.sh"
else
    # Define minimal logging function if common.sh is not available
    log() {
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    }
fi

# Source PostgreSQL functions
if [ -f "../modules/postgresql.sh" ]; then
    source "../modules/postgresql.sh"
else
    log "ERROR: PostgreSQL module not found: ../modules/postgresql.sh"
    log "Cannot proceed with the update"
    exit 1
fi

# Function to display help message
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  -d, --database NAME        Specify database name to update (default: all databases)"
    echo "  -s, --subdomain NAME       Specify subdomain for the database (default: same as database name)"
    echo "  -f, --force                Force update even if database appears to have the settings"
    echo "  -t, --test                 Test mode - don't make any changes"
    echo
    echo "Examples:"
    echo "  $0                         Update all databases"
    echo "  $0 --database demo         Update only the 'demo' database"
    echo "  $0 --database demo --subdomain testing  Update 'demo' database to use 'testing' subdomain"
    echo "  $0 --test                  Show what would be updated without making changes"
    echo
}

# Default values
DATABASE=""
SUBDOMAIN=""
FORCE=false
TEST_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--database)
            DATABASE="$2"
            shift 2
            ;;
        -s|--subdomain)
            SUBDOMAIN="$2"
            shift 2
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -t|--test)
            TEST_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Function to get all existing databases
get_databases() {
    log "Getting list of existing databases"
    
    # Skip system databases
    sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1', 'postgres') AND datname NOT LIKE 'pg_%'" | grep -v "^\s*$"
}

# Function to get existing hostname mappings
get_hostname_mappings() {
    log "Getting existing hostname mappings"
    
    # Get PostgreSQL version
    PG_VERSION=$(psql --version | head -n 1 | sed 's/^.* \([0-9]\+\.[0-9]\+\).*$/\1/')
    
    # Get hostname map file path
    MAP_FILE="/etc/postgresql/$PG_VERSION/main/pg_hostname_map.conf"
    
    if [ -f "$MAP_FILE" ]; then
        grep -v "^#" "$MAP_FILE" | grep -v "^\s*$"
    else
        log "WARNING: Hostname map file not found: $MAP_FILE"
        echo ""
    fi
}

# Function to check if a database has connection restrictions
has_connection_restrictions() {
    local db_name="$1"
    
    # Check if database has the trigger function for hostname validation
    local result=$(sudo -u postgres psql -t -c "SELECT 1 FROM pg_proc JOIN pg_namespace n ON pronamespace = n.oid WHERE proname = 'check_connection_hostname' AND n.nspname = 'public'" "$db_name" 2>/dev/null)
    
    if [ -n "$result" ] && [ "$(echo "$result" | tr -d ' ')" = "1" ]; then
        return 0  # Has the function
    else
        return 1  # Doesn't have the function
    fi
}

# Update a single database
update_database() {
    local db_name="$1"
    local subdomain="${2:-$db_name}"
    
    log "Updating database '$db_name' with subdomain '$subdomain'"
    
    # Check if database already has connection restrictions
    if ! $FORCE && has_connection_restrictions "$db_name"; then
        log "Database '$db_name' already has connection restrictions. Skipping. (Use --force to override)"
        return 0
    fi
    
    # In test mode, just show what would be done
    if $TEST_MODE; then
        log "TEST MODE: Would update database '$db_name' to use subdomain '$subdomain'"
        log "TEST MODE: Would apply hostname mapping for $db_name -> $subdomain"
        log "TEST MODE: Would configure connection restrictions for database '$db_name'"
        return 0
    fi
    
    # Update hostname mapping
    update_hostname_map_conf "$db_name" "$subdomain"
    
    # Configure database-specific connection restrictions
    configure_db_connection_restrictions "$db_name" "$subdomain"
    
    log "Database '$db_name' updated successfully"
    return 0
}

# Main execution
log "Database Update Script"
log "--------------------"

# Check if PostgreSQL is running
if ! pg_isready -q; then
    log "ERROR: PostgreSQL is not running, cannot update databases"
    exit 1
fi

# If a specific database was specified
if [ -n "$DATABASE" ]; then
    # Check if database exists
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DATABASE"; then
        log "Updating database '$DATABASE'"
        update_database "$DATABASE" "$SUBDOMAIN"
    else
        log "ERROR: Database '$DATABASE' does not exist"
        exit 1
    fi
else
    # Update all databases
    log "Updating all databases"
    
    # Get list of databases
    DATABASES=$(get_databases)
    
    # Get existing hostname mappings
    MAPPINGS=$(get_hostname_mappings)
    
    # Process each database
    for db_name in $DATABASES; do
        # Remove any whitespace
        db_name=$(echo "$db_name" | tr -d ' ')
        
        # Skip if empty
        [ -z "$db_name" ] && continue
        
        # Try to find existing mapping
        mapping=$(echo "$MAPPINGS" | grep "^$db_name " | head -1)
        
        if [ -n "$mapping" ]; then
            # Extract subdomain from mapping
            subdomain=$(echo "$mapping" | awk '{print $2}' | cut -d. -f1)
            log "Found existing mapping for '$db_name' -> '$subdomain'"
        else
            # Use database name as subdomain
            subdomain="$db_name"
            log "No existing mapping found for '$db_name', using '$subdomain' as subdomain"
        fi
        
        # Update the database
        update_database "$db_name" "$subdomain"
    done
fi

# Reload PostgreSQL configuration
if ! $TEST_MODE; then
    log "Reloading PostgreSQL configuration"
    if command -v pg_ctlcluster >/dev/null 2>&1; then
        pg_version=$(psql --version | head -n 1 | sed 's/^.* \([0-9]\+\.[0-9]\+\).*$/\1/')
        pg_ctlcluster "$pg_version" main reload
    else
        systemctl reload postgresql
    fi
    
    log "PostgreSQL configuration reloaded"
fi

log "Update script completed"
exit 0 