#!/bin/bash

# Validate Subdomain Access Tool
# This tool helps test and verify that the subdomain-based access control is working correctly,
# ensuring that database 'demo' can only be accessed through demo.dbhub.cc and not through dbhub.cc directly.

# Source common functions if available
if [ -f "../modules/common.sh" ]; then
    source "../modules/common.sh"
else
    # Define minimal logging function if common.sh is not available
    log() {
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    }
fi

# Function to display help message
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help                 Show this help message"
    echo "  -d, --database NAME        Specify database name to test (default: demo)"
    echo "  -s, --subdomain NAME       Specify subdomain to test (default: same as database name)"
    echo "  -u, --user USERNAME        Specify PostgreSQL username (default: admin_[database])"
    echo "  -p, --password PASSWORD    Specify PostgreSQL password"
    echo "  -t, --test-all             Test all databases and their subdomains"
    echo "  -f, --fix                  Fix configuration issues that are detected"
    echo
    echo "Examples:"
    echo "  $0 --database demo                  Test access to 'demo' database"
    echo "  $0 --database demo --fix            Test and fix access to 'demo' database"
    echo "  $0 --test-all                       Test all database subdomain mappings"
    echo
}

# Default values
DATABASE="demo"
SUBDOMAIN=""
USERNAME=""
PASSWORD=""
TEST_ALL=false
FIX_ISSUES=false

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
        -u|--user)
            USERNAME="$2"
            shift 2
            ;;
        -p|--password)
            PASSWORD="$2"
            shift 2
            ;;
        -t|--test-all)
            TEST_ALL=true
            shift
            ;;
        -f|--fix)
            FIX_ISSUES=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Function to get domain suffix from environment or config
get_domain_suffix() {
    # Try to read from environment
    if [ -n "$DOMAIN_SUFFIX" ]; then
        echo "$DOMAIN_SUFFIX"
        return
    fi
    
    # Try to read from .env file
    if [ -f "../.env" ]; then
        DOMAIN_SUFFIX=$(grep "DOMAIN_SUFFIX" "../.env" | cut -d= -f2)
        echo "$DOMAIN_SUFFIX"
        return
    fi
    
    # Default value if not found
    echo "dbhub.cc"
}

# Function to test database access via main domain
test_main_domain_access() {
    local db_name="$1"
    local username="${2:-postgres}"
    local password="$3"
    local domain_suffix=$(get_domain_suffix)
    
    log "Testing access to database '$db_name' via main domain '$domain_suffix'"
    
    # Build connection parameters
    local conn_params="-h $domain_suffix -p 5432 -d $db_name"
    if [ -n "$username" ]; then
        conn_params="$conn_params -U $username"
    fi
    
    # Set PGPASSWORD if password is provided
    if [ -n "$password" ]; then
        export PGPASSWORD="$password"
    fi
    
    # Try to connect via main domain
    psql $conn_params -c "SELECT current_database();" > /dev/null 2>&1
    local result=$?
    
    # Unset PGPASSWORD
    if [ -n "$password" ]; then
        unset PGPASSWORD
    fi
    
    if [ $result -eq 0 ]; then
        log "WARNING: Database '$db_name' can be accessed through main domain '$domain_suffix'"
        log "This is a security issue that should be fixed"
        return 1
    else
        log "Good: Database '$db_name' cannot be accessed through main domain '$domain_suffix'"
        return 0
    fi
}

# Function to test database access via subdomain
test_subdomain_access() {
    local db_name="$1"
    local subdomain="$2"
    local username="${3:-postgres}"
    local password="$4"
    local domain_suffix=$(get_domain_suffix)
    
    log "Testing access to database '$db_name' via subdomain '$subdomain.$domain_suffix'"
    
    # Build connection parameters
    local conn_params="-h $subdomain.$domain_suffix -p 5432 -d $db_name"
    if [ -n "$username" ]; then
        conn_params="$conn_params -U $username"
    fi
    
    # Set PGPASSWORD if password is provided
    if [ -n "$password" ]; then
        export PGPASSWORD="$password"
    fi
    
    # Try to connect via subdomain
    psql $conn_params -c "SELECT current_database();" > /dev/null 2>&1
    local result=$?
    
    # Unset PGPASSWORD
    if [ -n "$password" ]; then
        unset PGPASSWORD
    fi
    
    if [ $result -eq 0 ]; then
        log "Good: Database '$db_name' can be accessed through subdomain '$subdomain.$domain_suffix'"
        return 0
    else
        log "WARNING: Database '$db_name' cannot be accessed through its subdomain '$subdomain.$domain_suffix'"
        log "This may indicate a configuration issue"
        return 1
    fi
}

# Function to get all databases and their mappings
get_database_mappings() {
    # Get the path to PostgreSQL configuration
    local pg_version=$(psql --version | head -n 1 | sed 's/^.* \([0-9]\+\.[0-9]\+\).*$/\1/')
    local pg_conf_dir="/etc/postgresql/$pg_version/main"
    local map_file="$pg_conf_dir/pg_hostname_map.conf"
    
    if [ -f "$map_file" ]; then
        grep -v "^#" "$map_file" | grep -v "^$" | awk '{print $1 " " $2}'
    else
        log "ERROR: Hostname map file not found: $map_file"
        return 1
    fi
}

# Function to fix access control issues
fix_access_control() {
    local db_name="$1"
    local subdomain="$2"
    
    log "Fixing access control for database '$db_name' with subdomain '$subdomain'"
    
    # Source the PostgreSQL module
    if [ -f "../modules/postgresql.sh" ]; then
        source "../modules/postgresql.sh"
        
        # Update hostname mapping configuration
        update_hostname_map_conf "$db_name" "$subdomain"
        
        # Configure database-specific connection restrictions
        configure_db_connection_restrictions "$db_name" "$subdomain"
        
        # Reload PostgreSQL configuration
        if command -v pg_ctlcluster >/dev/null 2>&1; then
            pg_version=$(psql --version | head -n 1 | sed 's/^.* \([0-9]\+\.[0-9]\+\).*$/\1/')
            log "Reloading PostgreSQL configuration"
            pg_ctlcluster "$pg_version" main reload
        else
            log "Reloading PostgreSQL configuration"
            systemctl reload postgresql
        fi
        
        log "Access control fixes applied successfully"
    else
        log "ERROR: PostgreSQL module not found: ../modules/postgresql.sh"
        log "Cannot apply fixes automatically"
        return 1
    fi
}

# Main execution
log "Subdomain Access Validation Tool"
log "----------------------------"

# Set default values if not provided
if [ -z "$SUBDOMAIN" ]; then
    SUBDOMAIN="$DATABASE"
fi

if [ -z "$USERNAME" ]; then
    USERNAME="admin_$DATABASE"
fi

if $TEST_ALL; then
    log "Testing all database subdomain mappings"
    
    MAPPINGS=$(get_database_mappings)
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to get database mappings"
        exit 1
    fi
    
    FAILED=0
    
    while read -r mapping; do
        db_name=$(echo "$mapping" | awk '{print $1}')
        fqdn=$(echo "$mapping" | awk '{print $2}')
        subdomain=$(echo "$fqdn" | cut -d. -f1)
        
        log "Testing database '$db_name' with subdomain '$subdomain'"
        
        # Test main domain access (should fail)
        test_main_domain_access "$db_name" "admin_$db_name" "$PASSWORD"
        if [ $? -ne 0 ]; then
            FAILED=$((FAILED + 1))
            if $FIX_ISSUES; then
                fix_access_control "$db_name" "$subdomain"
            fi
        fi
        
        # Test subdomain access (should succeed)
        test_subdomain_access "$db_name" "$subdomain" "admin_$db_name" "$PASSWORD"
        if [ $? -ne 0 ]; then
            FAILED=$((FAILED + 1))
            if $FIX_ISSUES; then
                fix_access_control "$db_name" "$subdomain"
            fi
        fi
        
        echo
    done <<< "$MAPPINGS"
    
    if [ $FAILED -eq 0 ]; then
        log "All tests passed successfully"
        exit 0
    else
        log "WARNING: $FAILED tests failed"
        if $FIX_ISSUES; then
            log "Fixes were applied, please run the tests again to verify"
        else
            log "Use --fix option to automatically apply fixes"
        fi
        exit 1
    fi
else
    # Test specific database
    log "Testing database '$DATABASE' with subdomain '$SUBDOMAIN'"
    
    FAILED=0
    
    # Test main domain access (should fail)
    test_main_domain_access "$DATABASE" "$USERNAME" "$PASSWORD"
    if [ $? -ne 0 ]; then
        FAILED=$((FAILED + 1))
        if $FIX_ISSUES; then
            fix_access_control "$DATABASE" "$SUBDOMAIN"
        fi
    fi
    
    # Test subdomain access (should succeed)
    test_subdomain_access "$DATABASE" "$SUBDOMAIN" "$USERNAME" "$PASSWORD"
    if [ $? -ne 0 ]; then
        FAILED=$((FAILED + 1))
        if $FIX_ISSUES; then
            fix_access_control "$DATABASE" "$SUBDOMAIN"
        fi
    fi
    
    if [ $FAILED -eq 0 ]; then
        log "All tests passed successfully"
        exit 0
    else
        log "WARNING: $FAILED tests failed"
        if $FIX_ISSUES; then
            log "Fixes were applied, please run the tests again to verify"
        else
            log "Use --fix option to automatically apply fixes"
        fi
        exit 1
    fi
fi 