#!/bin/bash
# Database User Management Script
# Creates and manages PostgreSQL users with proper security restrictions

# Log file
LOG_FILE="/var/log/db-user-manager.log"
PG_VERSION=$(ls /etc/postgresql/ | sort -V | tail -n1)

# Load environment variables
ENV_FILES=("/etc/dbhub/.env" "/opt/dbhub/.env" "$(dirname "$0")/../.env" ".env")
for ENV_FILE in "${ENV_FILES[@]}"; do
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        break
    fi
done

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
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

# Check if PostgreSQL is installed
if ! command -v psql &> /dev/null; then
    log "ERROR: PostgreSQL is not installed"
    exit 1
fi

# Check if PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
    log "ERROR: PostgreSQL service is not running"
    exit 1
fi

# Create a database with a restricted user
create_user_db() {
    DB_NAME="$1"
    USER_NAME="$2"
    PASSWORD="$3"
    
    # Validate inputs
    if [[ -z "$DB_NAME" || -z "$USER_NAME" || -z "$PASSWORD" ]]; then
        log "ERROR: Database name, username, and password are required"
        exit 1
    fi
    
    # Check if database already exists
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        log "WARNING: Database '$DB_NAME' already exists"
    else
        log "Creating database '$DB_NAME'"
        sudo -u postgres psql -c "CREATE DATABASE $DB_NAME;" || {
            log "ERROR: Failed to create database '$DB_NAME'"
            exit 1
        }
    fi
    
    # Check if user already exists
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER_NAME'" | grep -q 1; then
        log "WARNING: User '$USER_NAME' already exists"
    else
        log "Creating user '$USER_NAME'"
        sudo -u postgres psql -c "CREATE USER $USER_NAME WITH ENCRYPTED PASSWORD '$PASSWORD';" || {
            log "ERROR: Failed to create user '$USER_NAME'"
            exit 1
        }
    fi
    
    # Grant privileges
    log "Granting privileges on '$DB_NAME' to '$USER_NAME'"
    sudo -u postgres psql -c "GRANT CONNECT ON DATABASE $DB_NAME TO $USER_NAME;" || {
        log "ERROR: Failed to grant CONNECT privilege"
        exit 1
    }
    
    # Connect to the database and set up schema permissions
    sudo -u postgres psql -d "$DB_NAME" -c "
        -- Revoke public schema usage from PUBLIC
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        
        -- Grant usage on public schema to the specific user
        GRANT USAGE ON SCHEMA public TO $USER_NAME;
        
        -- Grant privileges on all tables in public schema to the user
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $USER_NAME;
        
        -- Grant privileges on all sequences in public schema to the user
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $USER_NAME;
        
        -- Set default privileges for future tables
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $USER_NAME;
        
        -- Set default privileges for future sequences
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO $USER_NAME;
    " || {
        log "ERROR: Failed to set up schema permissions"
        exit 1
    }
    
    log "Successfully created database '$DB_NAME' with restricted user '$USER_NAME'"
}

# List all databases and their owners
list_databases() {
    log "Listing all databases and their owners"
    
    sudo -u postgres psql -c "
        SELECT d.datname as database, 
               pg_catalog.pg_get_userbyid(d.datdba) as owner,
               pg_size_pretty(pg_database_size(d.datname)) as size
        FROM pg_catalog.pg_database d
        WHERE d.datistemplate = false
        ORDER BY d.datname;
    "
}

# List all users and their permissions
list_users() {
    log "Listing all users and their permissions"
    
    sudo -u postgres psql -c "
        SELECT r.rolname as username,
               r.rolsuper as is_superuser,
               r.rolinherit as inherits_privileges,
               r.rolcreaterole as can_create_roles,
               r.rolcreatedb as can_create_dbs,
               r.rolcanlogin as can_login,
               r.rolreplication as has_replication,
               r.rolconnlimit as connection_limit,
               r.rolvaliduntil as valid_until
        FROM pg_catalog.pg_roles r
        ORDER BY r.rolname;
    "
}

# Delete a user and optionally their database
delete_user() {
    USER_NAME="$1"
    DELETE_DB="$2"
    
    # Validate inputs
    if [[ -z "$USER_NAME" ]]; then
        log "ERROR: Username is required"
        exit 1
    fi
    
    # Check if user exists
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER_NAME'" | grep -q 1; then
        log "ERROR: User '$USER_NAME' does not exist"
        exit 1
    fi
    
    # Get databases owned by the user
    OWNED_DBS=$(sudo -u postgres psql -tAc "
        SELECT d.datname 
        FROM pg_catalog.pg_database d 
        JOIN pg_catalog.pg_roles r ON d.datdba = r.oid 
        WHERE r.rolname = '$USER_NAME'
    ")
    
    # If DELETE_DB is true, drop owned databases
    if [[ "$DELETE_DB" == "true" ]]; then
        for DB in $OWNED_DBS; do
            log "Dropping database '$DB' owned by '$USER_NAME'"
            sudo -u postgres psql -c "DROP DATABASE $DB;" || {
                log "ERROR: Failed to drop database '$DB'"
            }
        done
    elif [[ -n "$OWNED_DBS" ]]; then
        log "WARNING: User '$USER_NAME' owns databases. Reassigning ownership to postgres"
        for DB in $OWNED_DBS; do
            log "Reassigning ownership of database '$DB' to postgres"
            sudo -u postgres psql -c "ALTER DATABASE $DB OWNER TO postgres;" || {
                log "ERROR: Failed to reassign ownership of database '$DB'"
            }
        done
    fi
    
    # Revoke all privileges from the user
    log "Revoking all privileges from user '$USER_NAME'"
    sudo -u postgres psql -c "REASSIGN OWNED BY $USER_NAME TO postgres;" || {
        log "WARNING: Failed to reassign objects owned by '$USER_NAME'"
    }
    
    sudo -u postgres psql -c "DROP OWNED BY $USER_NAME;" || {
        log "WARNING: Failed to drop objects owned by '$USER_NAME'"
    }
    
    # Drop the user
    log "Dropping user '$USER_NAME'"
    sudo -u postgres psql -c "DROP USER $USER_NAME;" || {
        log "ERROR: Failed to drop user '$USER_NAME'"
        exit 1
    }
    
    log "Successfully deleted user '$USER_NAME'"
}

# Change user password
change_password() {
    USER_NAME="$1"
    NEW_PASSWORD="$2"
    
    # Validate inputs
    if [[ -z "$USER_NAME" || -z "$NEW_PASSWORD" ]]; then
        log "ERROR: Username and new password are required"
        exit 1
    fi
    
    # Check if user exists
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER_NAME'" | grep -q 1; then
        log "ERROR: User '$USER_NAME' does not exist"
        exit 1
    fi
    
    # Change password
    log "Changing password for user '$USER_NAME'"
    sudo -u postgres psql -c "ALTER USER $USER_NAME WITH ENCRYPTED PASSWORD '$NEW_PASSWORD';" || {
        log "ERROR: Failed to change password for user '$USER_NAME'"
        exit 1
    }
    
    log "Successfully changed password for user '$USER_NAME'"
}

# Grant additional privileges to a user
grant_privileges() {
    USER_NAME="$1"
    DB_NAME="$2"
    PRIVILEGES="$3"
    
    # Validate inputs
    if [[ -z "$USER_NAME" || -z "$DB_NAME" || -z "$PRIVILEGES" ]]; then
        log "ERROR: Username, database name, and privileges are required"
        exit 1
    fi
    
    # Check if user exists
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER_NAME'" | grep -q 1; then
        log "ERROR: User '$USER_NAME' does not exist"
        exit 1
    fi
    
    # Check if database exists
    if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        log "ERROR: Database '$DB_NAME' does not exist"
        exit 1
    fi
    
    # Grant privileges
    log "Granting $PRIVILEGES privileges on '$DB_NAME' to '$USER_NAME'"
    
    case "$PRIVILEGES" in
        "read")
            sudo -u postgres psql -d "$DB_NAME" -c "
                GRANT CONNECT ON DATABASE $DB_NAME TO $USER_NAME;
                GRANT USAGE ON SCHEMA public TO $USER_NAME;
                GRANT SELECT ON ALL TABLES IN SCHEMA public TO $USER_NAME;
                GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO $USER_NAME;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO $USER_NAME;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO $USER_NAME;
            " || {
                log "ERROR: Failed to grant read privileges"
                exit 1
            }
            ;;
        "write")
            sudo -u postgres psql -d "$DB_NAME" -c "
                GRANT CONNECT ON DATABASE $DB_NAME TO $USER_NAME;
                GRANT USAGE ON SCHEMA public TO $USER_NAME;
                GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $USER_NAME;
                GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $USER_NAME;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $USER_NAME;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO $USER_NAME;
            " || {
                log "ERROR: Failed to grant write privileges"
                exit 1
            }
            ;;
        "all")
            sudo -u postgres psql -d "$DB_NAME" -c "
                GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $USER_NAME;
                GRANT ALL PRIVILEGES ON SCHEMA public TO $USER_NAME;
                GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $USER_NAME;
                GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $USER_NAME;
                GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO $USER_NAME;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO $USER_NAME;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO $USER_NAME;
                ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON FUNCTIONS TO $USER_NAME;
            " || {
                log "ERROR: Failed to grant all privileges"
                exit 1
            }
            ;;
        *)
            log "ERROR: Invalid privileges. Use 'read', 'write', or 'all'"
            exit 1
            ;;
    esac
    
    log "Successfully granted $PRIVILEGES privileges on '$DB_NAME' to '$USER_NAME'"
}

# Display usage information
usage() {
    echo "Usage: $0 COMMAND [OPTIONS]"
    echo
    echo "Commands:"
    echo "  create-user DB_NAME USER_NAME PASSWORD   Create a database with a restricted user"
    echo "  list-dbs                                 List all databases and their owners"
    echo "  list-users                               List all users and their permissions"
    echo "  delete-user USER_NAME [true|false]       Delete a user (optionally delete owned databases)"
    echo "  change-password USER_NAME NEW_PASSWORD   Change a user's password"
    echo "  grant-privileges USER_NAME DB_NAME TYPE  Grant privileges (read, write, all) to a user"
    echo "  help                                     Display this help message"
    echo
    echo "Examples:"
    echo "  $0 create-user mydb myuser mypassword    Create 'mydb' with restricted user 'myuser'"
    echo "  $0 list-dbs                              List all databases"
    echo "  $0 delete-user myuser true               Delete user 'myuser' and their databases"
    echo "  $0 grant-privileges myuser mydb write    Grant write privileges to 'myuser' on 'mydb'"
}

# Main script logic
case "$1" in
    create-user)
        if [[ $# -ne 4 ]]; then
            log "ERROR: create-user requires database name, username, and password"
            usage
            exit 1
        fi
        create_user_db "$2" "$3" "$4"
        ;;
    list-dbs)
        list_databases
        ;;
    list-users)
        list_users
        ;;
    delete-user)
        if [[ $# -lt 2 ]]; then
            log "ERROR: delete-user requires a username"
            usage
            exit 1
        fi
        delete_user "$2" "${3:-false}"
        ;;
    change-password)
        if [[ $# -ne 3 ]]; then
            log "ERROR: change-password requires username and new password"
            usage
            exit 1
        fi
        change_password "$2" "$3"
        ;;
    grant-privileges)
        if [[ $# -ne 4 ]]; then
            log "ERROR: grant-privileges requires username, database name, and privilege type"
            usage
            exit 1
        fi
        grant_privileges "$2" "$3" "$4"
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