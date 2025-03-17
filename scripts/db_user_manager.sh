#!/bin/bash
# Database User Manager Script
# This script creates restricted PostgreSQL users with access to specific databases

# Log file
LOG_FILE="/var/log/dbhub/db_user_manager.log"

# Ensure log directory exists
mkdir -p $(dirname $LOG_FILE)
touch $LOG_FILE

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Function to check if a database exists
database_exists() {
    local db_name="$1"
    local exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'")
    
    if [ "$exists" = "1" ]; then
        return 0  # Database exists
    else
        return 1  # Database does not exist
    fi
}

# Function to check if a user exists
user_exists() {
    local user_name="$1"
    local exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$user_name'")
    
    if [ "$exists" = "1" ]; then
        return 0  # User exists
    else
        return 1  # User does not exist
    fi
}

# Function to create a restricted user with access to a specific database
create_restricted_user() {
    local db_name="$1"
    local user_name="$2"
    local password="$3"
    
    # Check if database exists
    if ! database_exists "$db_name"; then
        log "Error: Database '$db_name' does not exist"
        return 1
    fi
    
    # Check if user already exists
    if user_exists "$user_name"; then
        log "User '$user_name' already exists. Updating password and permissions."
        
        # Update user password
        sudo -u postgres psql -c "ALTER USER \"$user_name\" WITH PASSWORD '$password'"
        log "Updated password for user '$user_name'"
    else
        # Create new user with password
        sudo -u postgres psql -c "CREATE USER \"$user_name\" WITH PASSWORD '$password'"
        log "Created new user '$user_name'"
    fi
    
    # Revoke all privileges from public schema
    sudo -u postgres psql -c "REVOKE ALL ON DATABASE \"$db_name\" FROM \"$user_name\""
    
    # Grant connect privilege to the database
    sudo -u postgres psql -c "GRANT CONNECT ON DATABASE \"$db_name\" TO \"$user_name\""
    log "Granted CONNECT privilege on database '$db_name' to user '$user_name'"
    
    # Connect to the database and set up schema permissions
    sudo -u postgres psql -d "$db_name" -c "REVOKE ALL ON SCHEMA public FROM \"$user_name\""
    sudo -u postgres psql -d "$db_name" -c "GRANT USAGE ON SCHEMA public TO \"$user_name\""
    log "Granted USAGE privilege on schema 'public' to user '$user_name'"
    
    # Grant privileges on all tables in the public schema
    sudo -u postgres psql -d "$db_name" -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"$user_name\""
    log "Granted SELECT, INSERT, UPDATE, DELETE privileges on all tables to user '$user_name'"
    
    # Grant privileges on all sequences in the public schema
    sudo -u postgres psql -d "$db_name" -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"$user_name\""
    log "Granted USAGE, SELECT privileges on all sequences to user '$user_name'"
    
    # Set default privileges for future tables
    sudo -u postgres psql -d "$db_name" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO \"$user_name\""
    sudo -u postgres psql -d "$db_name" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO \"$user_name\""
    log "Set default privileges for future tables and sequences for user '$user_name'"
    
    log "Successfully configured restricted user '$user_name' for database '$db_name'"
    return 0
}

# Function to list all databases
list_databases() {
    log "Listing all databases"
    sudo -u postgres psql -c "\l"
}

# Function to list all users
list_users() {
    log "Listing all users"
    sudo -u postgres psql -c "\du"
}

# Function to delete a user
delete_user() {
    local user_name="$1"
    
    if user_exists "$user_name"; then
        sudo -u postgres psql -c "DROP USER \"$user_name\""
        log "Deleted user '$user_name'"
        return 0
    else
        log "Error: User '$user_name' does not exist"
        return 1
    fi
}

# Function to create a new database
create_database() {
    local db_name="$1"
    local owner="$2"
    
    # If no owner specified, use postgres
    if [ -z "$owner" ]; then
        owner="postgres"
    fi
    
    # Check if database already exists
    if database_exists "$db_name"; then
        log "Error: Database '$db_name' already exists"
        return 1
    fi
    
    # Check if owner exists
    if ! user_exists "$owner"; then
        log "Error: Owner '$owner' does not exist"
        return 1
    fi
    
    # Create the database
    sudo -u postgres psql -c "CREATE DATABASE \"$db_name\" OWNER \"$owner\""
    log "Created database '$db_name' with owner '$owner'"
    return 0
}

# Display usage information
usage() {
    echo "Database User Manager"
    echo "Usage:"
    echo "  $0 create-user <db_name> <user_name> <password>  - Create a user with access only to a specific database"
    echo "  $0 create-db <db_name> [owner]                   - Create a new database with optional owner"
    echo "  $0 delete-user <user_name>                       - Delete a user"
    echo "  $0 list-dbs                                      - List all databases"
    echo "  $0 list-users                                    - List all users"
    echo "  $0 help                                          - Display this help message"
}

# Main script logic
case "$1" in
    create-user)
        if [ $# -ne 4 ]; then
            echo "Error: Missing arguments for create-user"
            usage
            exit 1
        fi
        create_restricted_user "$2" "$3" "$4"
        ;;
    create-db)
        if [ $# -lt 2 ]; then
            echo "Error: Missing arguments for create-db"
            usage
            exit 1
        fi
        create_database "$2" "$3"
        ;;
    delete-user)
        if [ $# -ne 2 ]; then
            echo "Error: Missing argument for delete-user"
            usage
            exit 1
        fi
        delete_user "$2"
        ;;
    list-dbs)
        list_databases
        ;;
    list-users)
        list_users
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Error: Unknown command '$1'"
        usage
        exit 1
        ;;
esac

exit 0 