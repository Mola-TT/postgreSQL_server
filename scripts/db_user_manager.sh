#!/bin/bash
# Database User Manager Script
# This script creates restricted PostgreSQL users with access to specific databases

# Log file
LOG_FILE="/var/log/dbhub/db_user_manager.log"
PGBOUNCER_USERLIST="/etc/pgbouncer/userlist.txt"

# Ensure log directory exists
mkdir -p $(dirname $LOG_FILE)
touch $LOG_FILE

# Logging function
log() {
    echo "[$(TZ=Asia/Singapore date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
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

# Function to get SCRAM hash for PostgreSQL user
get_user_hash() {
    local username="$1"
    sudo -u postgres psql -t -c "SELECT concat('SCRAM-SHA-256$', split_part(rolpassword, '$', 2), '$', split_part(rolpassword, '$', 3), '$', split_part(rolpassword, '$', 4)) FROM pg_authid WHERE rolname='$username';"
}

# Function to update PgBouncer user list
update_pgbouncer_user() {
    local username="$1"
    local action="$2"  # add, update, delete
    
    # Check if PgBouncer is installed
    if [ ! -f "$PGBOUNCER_USERLIST" ]; then
        log "PgBouncer userlist not found at $PGBOUNCER_USERLIST, skipping update"
        return 0
    fi
    
    log "Updating PgBouncer userlist for user '$username' (action: $action)"
    
    # Create backup of current userlist
    local backup_file="${PGBOUNCER_USERLIST}.$(date +'%Y%m%d%H%M%S').bak"
    cp "$PGBOUNCER_USERLIST" "$backup_file"
    log "Created backup of PgBouncer userlist at $backup_file"
    
    case "$action" in
        add|update)
            # Get user hash
            local user_hash=$(get_user_hash "$username")
            user_hash=$(echo "$user_hash" | tr -d ' ')
            
            if [ -z "$user_hash" ]; then
                log "Error: Could not get hash for user '$username'"
                return 1
            fi
            
            # Check if user exists in userlist
            if grep -q "^\"$username\"" "$PGBOUNCER_USERLIST"; then
                # Update existing user
                sed -i "/^\"$username\"/c\\\"$username\" \"$user_hash\"" "$PGBOUNCER_USERLIST"
                log "Updated existing user '$username' in PgBouncer userlist"
            else
                # Add new user
                echo "\"$username\" \"$user_hash\"" >> "$PGBOUNCER_USERLIST"
                log "Added new user '$username' to PgBouncer userlist"
            fi
            ;;
        delete)
            # Remove user from userlist
            sed -i "/^\"$username\"/d" "$PGBOUNCER_USERLIST"
            log "Removed user '$username' from PgBouncer userlist"
            ;;
        *)
            log "Error: Unknown action '$action' for update_pgbouncer_user"
            return 1
            ;;
    esac
    
    # Fix permissions
    chown postgres:postgres "$PGBOUNCER_USERLIST"
    chmod 640 "$PGBOUNCER_USERLIST"
    
    # Reload PgBouncer if running
    if systemctl is-active --quiet pgbouncer; then
        log "Reloading PgBouncer to apply changes"
        systemctl reload pgbouncer || systemctl restart pgbouncer
        log "PgBouncer reloaded successfully"
    else
        log "PgBouncer is not running, changes will be applied on next start"
    fi
    
    return 0
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
        
        # Update PgBouncer userlist for this user
        update_pgbouncer_user "$user_name" "update"
    else
        # Create new user with password
        sudo -u postgres psql -c "CREATE USER \"$user_name\" WITH PASSWORD '$password'"
        log "Created new user '$user_name'"
        
        # Add user to PgBouncer userlist
        update_pgbouncer_user "$user_name" "add"
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
        # Remove user from PgBouncer userlist first
        update_pgbouncer_user "$user_name" "delete"
        
        # Then delete the user from PostgreSQL
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

# Function to update user password
update_user_password() {
    local user_name="$1"
    local new_password="$2"
    
    if ! user_exists "$user_name"; then
        log "Error: User '$user_name' does not exist"
        return 1
    fi
    
    # Update user password in PostgreSQL
    sudo -u postgres psql -c "ALTER USER \"$user_name\" WITH PASSWORD '$new_password'"
    log "Updated password for user '$user_name'"
    
    # Update user in PgBouncer userlist
    update_pgbouncer_user "$user_name" "update"
    
    log "Password updated successfully for user '$user_name'"
    return 0
}

# Function to synchronize all PgBouncer users with PostgreSQL
sync_all_pgbouncer_users() {
    log "Synchronizing all PostgreSQL users with PgBouncer userlist"
    
    # Check if PgBouncer is installed
    if [ ! -f "$PGBOUNCER_USERLIST" ]; then
        log "PgBouncer userlist not found at $PGBOUNCER_USERLIST, skipping sync"
        return 1
    fi
    
    # Create backup of current userlist
    local backup_file="${PGBOUNCER_USERLIST}.$(date +'%Y%m%d%H%M%S').bak"
    cp "$PGBOUNCER_USERLIST" "$backup_file"
    log "Created backup of PgBouncer userlist at $backup_file"
    
    # Create new userlist with header
    echo "# PgBouncer userlist - Updated on $(date)" > "${PGBOUNCER_USERLIST}.new"
    
    # Get all users from PostgreSQL that can login
    local users=$(sudo -u postgres psql -t -c "SELECT rolname FROM pg_roles WHERE rolcanlogin" | grep -v "^ *$")
    
    # Process each user
    for username in $users; do
        username=$(echo "$username" | tr -d ' ')
        
        # Skip if empty
        if [ -z "$username" ]; then
            continue
        fi
        
        # Get user hash
        local user_hash=$(get_user_hash "$username")
        user_hash=$(echo "$user_hash" | tr -d ' ')
        
        if [ -z "$user_hash" ]; then
            log "Warning: Could not get hash for user '$username', skipping"
            continue
        fi
        
        # Add user to new userlist
        echo "\"$username\" \"$user_hash\"" >> "${PGBOUNCER_USERLIST}.new"
        log "Added user '$username' to new PgBouncer userlist"
    done
    
    # Replace old userlist with new one
    mv "${PGBOUNCER_USERLIST}.new" "$PGBOUNCER_USERLIST"
    chown postgres:postgres "$PGBOUNCER_USERLIST"
    chmod 640 "$PGBOUNCER_USERLIST"
    
    # Reload PgBouncer if running
    if systemctl is-active --quiet pgbouncer; then
        log "Reloading PgBouncer to apply changes"
        systemctl reload pgbouncer || systemctl restart pgbouncer
        log "PgBouncer reloaded successfully"
    else
        log "PgBouncer is not running, changes will be applied on next start"
    fi
    
    log "All PostgreSQL users synchronized with PgBouncer userlist"
    return 0
}

# Display usage information
usage() {
    echo "Database User Manager"
    echo "Usage:"
    echo "  $0 create-user <db_name> <user_name> <password>  - Create a user with access only to a specific database"
    echo "  $0 create-db <db_name> [owner]                   - Create a new database with optional owner"
    echo "  $0 delete-user <user_name>                       - Delete a user"
    echo "  $0 update-password <user_name> <new_password>    - Update a user's password"
    echo "  $0 sync-pgbouncer                                - Synchronize all PostgreSQL users with PgBouncer"
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
    update-password)
        if [ $# -ne 3 ]; then
            echo "Error: Missing arguments for update-password"
            usage
            exit 1
        fi
        update_user_password "$2" "$3"
        ;;
    sync-pgbouncer)
        sync_all_pgbouncer_users
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