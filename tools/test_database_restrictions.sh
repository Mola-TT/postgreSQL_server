#!/bin/bash

# Test Database Restrictions Script
# Tests the effectiveness of database visibility restrictions and subdomain-based access control

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
    echo "  -d, --database NAME        Database to test (default: test all accessible databases)"
    echo "  -u, --user USERNAME        PostgreSQL user to test with (default: postgres)"
    echo "  -v, --verbose              Enable verbose output"
    echo
    echo "Examples:"
    echo "  $0                         Test all databases with postgres user"
    echo "  $0 --database demo         Test only the 'demo' database"
    echo "  $0 --user testuser         Test with 'testuser' instead of postgres"
    echo
}

# Default values
DATABASE=""
USER="postgres"
VERBOSE=false

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
        -u|--user)
            USER="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Function to check if PostgreSQL is running
check_postgresql() {
    log "Checking if PostgreSQL is running"
    
    if pg_isready -q; then
        log "PostgreSQL is running"
        return 0
    else
        log "ERROR: PostgreSQL is not running"
        return 1
    fi
}

# Function to get all accessible databases
get_accessible_databases() {
    local user="$1"
    
    log "Getting list of databases accessible by user '$user'"
    
    # Run psql as the specified user to list databases
    if [ "$user" == "postgres" ]; then
        sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1') AND datname NOT LIKE 'pg_%'" | grep -v "^\s*$"
    else
        # For non-postgres users, we need to be careful about authentication
        PGPASSWORD="${PGPASSWORD:-}" psql -U "$user" -h localhost -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1') AND datname NOT LIKE 'pg_%'" | grep -v "^\s*$"
    fi
}

# Function to test database visibility
test_database_visibility() {
    local user="$1"
    
    log "Testing database visibility for user '$user'"
    
    # Get list of all databases as postgres (superuser)
    local all_databases=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1') AND datname NOT LIKE 'pg_%'" | grep -v "^\s*$")
    
    # Get list of visible databases for the test user
    local visible_databases
    if [ "$user" == "postgres" ]; then
        visible_databases=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database_view WHERE datname NOT IN ('template0', 'template1') AND datname NOT LIKE 'pg_%'" | grep -v "^\s*$")
    else
        # For non-postgres users, we need to be careful about authentication
        visible_databases=$(PGPASSWORD="${PGPASSWORD:-}" psql -U "$user" -h localhost -t -c "SELECT datname FROM pg_database_view WHERE datname NOT IN ('template0', 'template1') AND datname NOT LIKE 'pg_%'" 2>/dev/null | grep -v "^\s*$")
        
        # If the previous command failed (pg_database_view might not be accessible), try the standard approach
        if [ $? -ne 0 ]; then
            visible_databases=$(PGPASSWORD="${PGPASSWORD:-}" psql -U "$user" -h localhost -t -c "\l" 2>/dev/null | awk '{print $1}' | grep -v "^\s*$" | grep -v "Name" | grep -v "List" | grep -v "----" | grep -v "rows)")
        fi
    fi
    
    # Count databases
    local all_count=$(echo "$all_databases" | grep -c ".")
    local visible_count=$(echo "$visible_databases" | grep -c ".")
    
    log "Total databases: $all_count"
    log "Visible to user '$user': $visible_count"
    
    # Calculate percentage visibility
    local visibility_pct=$(( (visible_count * 100) / all_count ))
    log "Database visibility: ${visibility_pct}%"
    
    # If in verbose mode, show details
    if $VERBOSE; then
        log "All databases:"
        echo "$all_databases" | while read -r db; do
            [ -z "$db" ] && continue
            echo "  - $db"
        done
        
        log "Databases visible to user '$user':"
        echo "$visible_databases" | while read -r db; do
            [ -z "$db" ] && continue
            echo "  - $db"
        done
    fi
    
    # Check if user can see databases they shouldn't
    if [ "$user" != "postgres" ] && [ $visibility_pct -eq 100 ]; then
        log "WARNING: Non-superuser '$user' can see all databases!"
    elif [ "$user" == "postgres" ] && [ $visibility_pct -lt 100 ]; then
        log "WARNING: Superuser 'postgres' cannot see all databases!"
    elif [ "$user" != "postgres" ]; then
        log "User '$user' has restricted database visibility as expected"
    fi
}

# Function to test subdomain-based access
test_subdomain_access() {
    local db_name="$1"
    local user="$2"
    
    log "Testing subdomain-based access for database '$db_name' with user '$user'"
    
    # Get the allowed hostname for this database
    local allowed_hostname
    if [ "$user" == "postgres" ]; then
        # Get PostgreSQL version
        local pg_version=$(psql --version | head -n 1 | sed 's/^.* \([0-9]\+\.[0-9]\+\).*$/\1/')
        local map_file="/etc/postgresql/$pg_version/main/pg_hostname_map.conf"
        
        if [ -f "$map_file" ]; then
            allowed_hostname=$(grep "^$db_name " "$map_file" | awk '{print $2}')
        fi
    fi
    
    # If we couldn't determine the allowed hostname, use default pattern
    if [ -z "$allowed_hostname" ]; then
        allowed_hostname="${db_name}.dbhub.cc"
    fi
    
    log "Expected allowed hostname: $allowed_hostname"
    
    # Test connection with correct hostname
    log "Testing connection with correct hostname"
    
    # Save detailed output for debugging if in verbose mode
    local correct_output=""
    if $VERBOSE; then
        if [ "$user" == "postgres" ]; then
            correct_output=$(PGAPPNAME="$allowed_hostname" sudo -u postgres psql -c "SELECT current_database(), current_user, application_name;" "$db_name" 2>&1)
        else
            correct_output=$(PGAPPNAME="$allowed_hostname" PGPASSWORD="${PGPASSWORD:-}" psql -U "$user" -h localhost -c "SELECT current_database(), current_user, application_name;" "$db_name" 2>&1)
        fi
        log "Connection output with correct hostname:"
        echo "$correct_output"
    else
        # Just test connection status without verbose output
        if [ "$user" == "postgres" ]; then
            PGAPPNAME="$allowed_hostname" sudo -u postgres psql -c "SELECT current_database()" "$db_name" >/dev/null 2>&1
        else
            PGAPPNAME="$allowed_hostname" PGPASSWORD="${PGPASSWORD:-}" psql -U "$user" -h localhost -c "SELECT current_database()" "$db_name" >/dev/null 2>&1
        fi
    fi
    
    if [ $? -eq 0 ]; then
        log "SUCCESS: Connection through correct hostname '$allowed_hostname' works"
    else
        log "WARNING: Could not connect through correct hostname '$allowed_hostname'"
        log "This suggests that hostname validation may be rejecting valid connections."
        log "Check that the hostname map configuration is set up correctly."
    fi
    
    # Test connection with incorrect hostname
    local incorrect_hostname="dbhub.cc"
    log "Testing connection with incorrect hostname"
    
    # Capture connection attempt output for debugging
    local result=0
    local incorrect_output=""
    
    if [ "$user" == "postgres" ]; then
        incorrect_output=$(PGAPPNAME="$incorrect_hostname" sudo -u postgres psql -c "SELECT current_database(), application_name;" "$db_name" 2>&1)
        result=$?
    else
        incorrect_output=$(PGAPPNAME="$incorrect_hostname" PGPASSWORD="${PGPASSWORD:-}" psql -U "$user" -h localhost -c "SELECT current_database(), application_name;" "$db_name" 2>&1)
        result=$?
    fi
    
    if [ $result -ne 0 ]; then
        log "SUCCESS: Connection through incorrect hostname '$incorrect_hostname' is properly blocked"
        if $VERBOSE; then
            log "Error message from connection attempt:"
            echo "$incorrect_output" | grep -i "error\|exception\|permitted"
        fi
    else
        log "WARNING: Connection through incorrect hostname '$incorrect_hostname' was NOT blocked"
        log "This is a security issue! The database should only be accessible through its designated subdomain."
        log "Check that exact hostname validation is enabled."
        if $VERBOSE; then
            log "Output from successful connection that should have been blocked:"
            echo "$incorrect_output"
        fi
    fi
}

# Function to test database access permissions
test_database_permissions() {
    local db_name="$1"
    local user="$2"
    
    log "Testing permissions in database '$db_name' for user '$user'"
    
    # Check if user can create a table
    log "Testing table creation permission"
    local create_result
    if [ "$user" == "postgres" ]; then
        create_result=$(sudo -u postgres psql -t -c "CREATE TABLE IF NOT EXISTS _test_permissions (id serial primary key, test_col text); SELECT 'Table created successfully';" "$db_name" 2>&1)
    else
        create_result=$(PGPASSWORD="${PGPASSWORD:-}" psql -U "$user" -h localhost -t -c "CREATE TABLE IF NOT EXISTS _test_permissions (id serial primary key, test_col text); SELECT 'Table created successfully';" "$db_name" 2>&1)
    fi
    
    if echo "$create_result" | grep -q "Table created successfully"; then
        log "User '$user' can create tables in database '$db_name'"
    else
        log "User '$user' cannot create tables in database '$db_name'"
        log "Error: $(echo "$create_result" | grep -i "error")"
    fi
    
    # Cleanup test table if it was created
    if [ "$user" == "postgres" ]; then
        sudo -u postgres psql -c "DROP TABLE IF EXISTS _test_permissions;" "$db_name" >/dev/null 2>&1
    else
        PGPASSWORD="${PGPASSWORD:-}" psql -U "$user" -h localhost -c "DROP TABLE IF EXISTS _test_permissions;" "$db_name" >/dev/null 2>&1
    fi
}

# Main function
main() {
    log "Database Restrictions Test"
    log "-----------------------"
    
    # Check if PostgreSQL is running
    check_postgresql || exit 1
    
    # Test database visibility
    test_database_visibility "$USER"
    
    # If a specific database was specified
    if [ -n "$DATABASE" ]; then
        log "Testing specific database: $DATABASE"
        test_subdomain_access "$DATABASE" "$USER"
        test_database_permissions "$DATABASE" "$USER"
    else
        # Test all accessible databases
        log "Testing all accessible databases"
        
        # Get list of accessible databases
        local databases=$(get_accessible_databases "$USER")
        
        # Test each database
        echo "$databases" | while read -r db; do
            # Skip empty lines
            [ -z "$db" ] && continue
            # Remove whitespace
            db=$(echo "$db" | tr -d ' ')
            
            log "=== Testing database: $db ==="
            test_subdomain_access "$db" "$USER"
            test_database_permissions "$db" "$USER"
            log ""
        done
    fi
    
    log "Database restrictions test completed"
}

# Run the main function
main 