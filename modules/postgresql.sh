# PostgreSQL Module
# Contains functions for managing PostgreSQL databases and security configurations

# Get PostgreSQL version
get_pg_version() {
    if command -v psql >/dev/null 2>&1; then
        psql --version | head -n 1 | sed 's/^.* \([0-9]\+\.[0-9]\+\).*$/\1/'
    else
        echo ""
    fi
}

# Get PostgreSQL config directory
get_pg_config_dir() {
    local pg_version=$(get_pg_version)
    if [ -n "$pg_version" ]; then
        echo "/etc/postgresql/$pg_version/main"
    else
        echo ""
    fi
}

# Check if PostgreSQL is installed
is_postgresql_installed() {
    if command -v psql >/dev/null 2>&1; then
        return 0  # True
    else
        return 1  # False
    fi
}

# Update hostname map configuration file
update_hostname_map_conf() {
    local db_name="$1"
    local subdomain="$2"
    local domain="${3:-dbhub.cc}"
    
    log "Updating hostname mapping for database '$db_name' -> '$subdomain.$domain'"
    
    # Get config directory
    local pg_config_dir=$(get_pg_config_dir)
    if [ -z "$pg_config_dir" ]; then
        log "ERROR: Could not determine PostgreSQL config directory"
        return 1
    fi
    
    # Hostname map file
    local map_file="$pg_config_dir/pg_hostname_map.conf"
    
    # Check if file exists, create if not
    if [ ! -f "$map_file" ]; then
        log "Creating hostname map file: $map_file"
        
        # Create with header
        cat > "$map_file" << EOF
# PostgreSQL Hostname Map Configuration
# Format: <database_name> <allowed_hostname>
# Example: mydatabase mydatabase.dbhub.cc
#
# This file maps database names to allowed hostnames for connection validation

EOF
        
        # Set proper permissions
        chmod 640 "$map_file"
        chown postgres:postgres "$map_file"
    fi
    
    # Check if mapping already exists
    if grep -q "^$db_name " "$map_file"; then
        # Update existing mapping
        log "Updating existing mapping for '$db_name'"
        sed -i "s|^$db_name .*|$db_name $subdomain.$domain|" "$map_file"
    else
        # Add new mapping
        log "Adding new mapping for '$db_name'"
        echo "$db_name $subdomain.$domain" >> "$map_file"
    fi
    
    log "Hostname mapping updated successfully"
    return 0
}

# Configure database-specific connection restrictions with additional safeguards
configure_db_connection_restrictions() {
    local db_name="$1"
    local subdomain="$2"
    local domain="${3:-dbhub.cc}"
    
    log "Configuring connection restrictions for database '$db_name'"
    
    # Create validation function in the database
    sudo -u postgres psql -d "$db_name" << EOF
-- Create the hostname validation function if it doesn't exist
CREATE OR REPLACE FUNCTION public.check_connection_hostname()
RETURNS event_trigger AS \$\$
DECLARE
    hostname text;
    current_db text;
    allowed_hostname text;
BEGIN
    -- Get the current hostname (from application_name)
    SELECT application_name INTO hostname FROM pg_stat_activity WHERE pid = pg_backend_pid();
    
    -- Get current database name
    SELECT current_database() INTO current_db;
    
    -- Determine allowed hostname based on database name
    allowed_hostname := '$subdomain.$domain';
    
    -- Log connection attempt for debugging
    RAISE NOTICE 'Connection attempt: database=%, hostname=%, allowed=%', 
                 current_db, hostname, allowed_hostname;
    
    -- Check if hostname exactly matches the allowed hostname
    -- FIXED: Using exact match (!=) instead of partial match (position)
    -- to prevent accessing via main domain instead of subdomain
    IF hostname IS NULL OR hostname = '' OR hostname != allowed_hostname THEN
        -- Unauthorized hostname
        RAISE EXCEPTION 'Access to database "%" is only permitted through subdomain: %', 
                        current_db, allowed_hostname;
    END IF;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create a separate statement-level authentication check function that runs on every query
CREATE OR REPLACE FUNCTION public.validate_hostname_on_query()
RETURNS trigger AS \$\$
DECLARE
    hostname text;
    current_db text;
    allowed_hostname text;
BEGIN
    -- Skip for superuser
    IF (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        RETURN NULL;
    END IF;
    
    -- Get the current hostname (from application_name)
    SELECT application_name INTO hostname FROM pg_stat_activity WHERE pid = pg_backend_pid();
    
    -- Get current database name
    SELECT current_database() INTO current_db;
    
    -- Determine allowed hostname based on database name
    allowed_hostname := '$subdomain.$domain';
    
    -- Check if hostname exactly matches the allowed hostname
    -- FIXED: Using exact match (!=) instead of partial match
    IF hostname IS NULL OR hostname = '' OR hostname != allowed_hostname THEN
        -- Unauthorized hostname
        RAISE EXCEPTION 'Access to database "%" is only permitted through subdomain: %. (Query blocked)', 
                        current_db, allowed_hostname;
    END IF;
    
    -- Allow the query to proceed
    RETURN NULL;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create event trigger for connection events
DROP EVENT TRIGGER IF EXISTS connection_hostname_validation;
CREATE EVENT TRIGGER connection_hostname_validation 
ON ddl_command_start
EXECUTE FUNCTION public.check_connection_hostname();

-- First, remove any existing statement trigger if it exists
DROP EVENT TRIGGER IF EXISTS query_hostname_validation;

-- Create trigger on pg_class to capture all queries
DROP TRIGGER IF EXISTS validate_hostname_on_query_trigger ON pg_class;
CREATE TRIGGER validate_hostname_on_query_trigger
  BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE OR SELECT ON pg_class
  FOR EACH STATEMENT
  EXECUTE FUNCTION validate_hostname_on_query();

-- Grant usage to public
GRANT EXECUTE ON FUNCTION public.check_connection_hostname() TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_hostname_on_query() TO PUBLIC;
EOF
    
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to configure connection restrictions for database '$db_name'"
        return 1
    fi
    
    # Create a query-based validation on system catalogs to catch more types of access
    sudo -u postgres psql -d "$db_name" << EOF
-- Create validation triggers on common system catalogs to increase coverage
DO \$\$
DECLARE
    tbl RECORD;
BEGIN
    FOR tbl IN SELECT tablename FROM pg_tables WHERE schemaname = 'pg_catalog' LIMIT 5
    LOOP
        EXECUTE format('
            DROP TRIGGER IF EXISTS validate_hostname_trigger ON pg_catalog.%I;
            CREATE TRIGGER validate_hostname_trigger
              BEFORE SELECT ON pg_catalog.%I
              FOR EACH STATEMENT
              EXECUTE FUNCTION validate_hostname_on_query();
        ', tbl.tablename, tbl.tablename);
    END LOOP;
END
\$\$;
EOF
    
    log "Connection restrictions configured for database '$db_name'"
    return 0
}

# Update pg_hba.conf for subdomain based access
update_pg_hba_for_subdomain_access() {
    log "Updating pg_hba.conf for subdomain based access"
    
    # Get config directory
    local pg_config_dir=$(get_pg_config_dir)
    if [ -z "$pg_config_dir" ]; then
        log "ERROR: Could not determine PostgreSQL config directory"
        return 1
    fi
    
    # pg_hba.conf file path
    local pg_hba_file="$pg_config_dir/pg_hba.conf"
    
    # Check if pg_hba.conf exists
    if [ ! -f "$pg_hba_file" ]; then
        log "ERROR: pg_hba.conf not found: $pg_hba_file"
        return 1
    fi
    
    # Back up the file
    local backup_file="$pg_hba_file.$(date +%Y%m%d%H%M%S).bak"
    log "Creating backup of pg_hba.conf: $backup_file"
    cp -f "$pg_hba_file" "$backup_file"
    
    # Check if the hostssl entry already exists
    if grep -q "^hostssl.*hostnossl" "$pg_hba_file"; then
        log "Subdomain access rules already exist in pg_hba.conf"
    else
        log "Adding subdomain access rules to pg_hba.conf"
        
        # Add the rules to the file
        # We'll add them before the first "host" entry
        awk '
            /^host/ && !found {
                print "# Enhanced subdomain-based access control";
                print "# Allow connections only through specific subdomains for each database";
                print "hostssl all             all             0.0.0.0/0               md5     clientcert=0";
                print "hostnossl all           all             0.0.0.0/0               reject";
                print "";
                found=1;
            }
            {print}
        ' "$pg_hba_file" > "$pg_hba_file.tmp"
        
        # Replace the original file
        mv -f "$pg_hba_file.tmp" "$pg_hba_file"
        
        # Set proper permissions
        chmod 640 "$pg_hba_file"
        chown postgres:postgres "$pg_hba_file"
    fi
    
    log "pg_hba.conf updated successfully"
    return 0
}

# Apply PostgreSQL global visibility restrictions
configure_database_visibility_restrictions() {
    log "Configuring database visibility restrictions globally"
    
    sudo -u postgres psql -d postgres << EOF
-- Function to set up database visibility restrictions
CREATE OR REPLACE FUNCTION public.configure_database_visibility_restrictions()
RETURNS void AS \$\$
BEGIN
    -- Create a custom view that limits database visibility
    -- Only show databases that the current user has CONNECT permission for
    -- or if the user is a superuser
    EXECUTE 'CREATE OR REPLACE VIEW pg_catalog.pg_database_view AS
        SELECT d.*
        FROM pg_catalog.pg_database d
        WHERE 
            pg_catalog.has_database_privilege(d.datname, ''CONNECT'') OR 
            pg_catalog.pg_has_role(current_user, ''pg_execute_server_program'', ''MEMBER'') OR
            pg_catalog.pg_has_role(current_user, ''pg_read_server_files'', ''MEMBER'') OR
            pg_catalog.pg_has_role(current_user, ''pg_write_server_files'', ''MEMBER'') OR
            current_user = ''postgres'' OR
            current_setting(''is_superuser'') = ''on''';

    -- Revoke access to the original pg_database table for regular users
    -- But keep access to the view we just created
    EXECUTE 'REVOKE ALL ON pg_catalog.pg_database FROM PUBLIC';
    EXECUTE 'GRANT SELECT ON pg_catalog.pg_database_view TO PUBLIC';
    
    -- Create a wrapper function for the \l and \c commands to use
    EXECUTE 'CREATE OR REPLACE FUNCTION pg_catalog.pg_database_view_wrapper()
    RETURNS SETOF pg_catalog.pg_database AS \$\$
    SELECT * FROM pg_catalog.pg_database_view;
    \$\$ LANGUAGE SQL SECURITY DEFINER';
    
    -- Grant execute permission to all users on the wrapper function
    EXECUTE 'GRANT EXECUTE ON FUNCTION pg_catalog.pg_database_view_wrapper() TO PUBLIC';
    
    -- Create a function and event trigger to validate hostname during connection attempts
    EXECUTE 'CREATE OR REPLACE FUNCTION public.validate_connection_hostname()
    RETURNS event_trigger AS \$\$
    DECLARE
        hostname text;
        current_db text;
        allowed_hostname text;
        config_file text;
        mapping record;
    BEGIN
        -- Get the current hostname (from application_name)
        SELECT application_name INTO hostname FROM pg_stat_activity WHERE pid = pg_backend_pid();
        
        -- Get current database name
        SELECT current_database() INTO current_db;
        
        -- Skip validation for postgres database or if hostname is empty
        IF current_db = ''postgres'' OR hostname IS NULL OR hostname = '''' THEN
            RETURN;
        END IF;
        
        -- Find config file location
        SELECT setting INTO config_file FROM pg_settings WHERE name = ''config_file'';
        config_file := replace(config_file, ''postgresql.conf'', ''pg_hostname_map.conf'');
        
        -- For each database, get the allowed hostname from the config file
        -- and check if the current connection matches
        FOR mapping IN
            EXECUTE format(''SELECT * FROM pg_read_file(%L) AS content'', config_file)
        LOOP
            -- Process each line in the config file
            IF position(''#'' in mapping.content) = 0 AND mapping.content ~ ''\\S'' THEN
                -- Extract database name and allowed hostname
                allowed_hostname := split_part(mapping.content, '' '', 2);
                
                -- Check if this mapping applies to the current database
                IF split_part(mapping.content, '' '', 1) = current_db THEN
                    -- FIXED: Check if hostname exactly matches allowed pattern
                    -- Using != instead of position() to require exact match
                    IF hostname != allowed_hostname THEN
                        -- Unauthorized hostname
                        RAISE EXCEPTION ''Access to database "%s" is only permitted through subdomain: %s'', 
                                        current_db, allowed_hostname;
                    END IF;
                    
                    -- Match found, no need to check other mappings
                    RETURN;
                END IF;
            END IF;
        END LOOP;
    END;
    \$\$ LANGUAGE plpgsql SECURITY DEFINER';
    
    -- Create event trigger for connection events
    EXECUTE 'DROP EVENT TRIGGER IF EXISTS connection_hostname_validation';
    EXECUTE 'CREATE EVENT TRIGGER connection_hostname_validation 
    ON ddl_command_start
    EXECUTE FUNCTION public.validate_connection_hostname()';
    
    -- Grant usage to public
    EXECUTE 'GRANT EXECUTE ON FUNCTION public.validate_connection_hostname() TO PUBLIC';
END;
\$\$ LANGUAGE plpgsql;

-- Run the function to set up the restrictions
SELECT public.configure_database_visibility_restrictions();
EOF
    
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to configure database visibility restrictions"
        return 1
    fi
    
    log "Database visibility restrictions configured successfully"
    return 0
}

# Test subdomain access control
test_subdomain_access() {
    local db_name="$1"
    local subdomain="$2"
    local domain="${3:-dbhub.cc}"
    local hostname="$subdomain.$domain"
    
    log "Testing subdomain access control for database '$db_name'"
    log "Attempting connection via subdomain '$hostname'"
    
    # Attempt connection with correct hostname
    PGAPPNAME="$hostname" psql -U postgres -c "SELECT current_database()" "$db_name" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log "SUCCESS: Connection through correct subdomain '$hostname' works"
    else
        log "WARNING: Could not connect through correct subdomain '$hostname'"
    fi
    
    # Attempt connection with incorrect hostname
    log "Attempting connection via main domain 'dbhub.cc'"
    PGAPPNAME="dbhub.cc" psql -U postgres -c "SELECT current_database()" "$db_name" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log "SUCCESS: Connection through incorrect hostname 'dbhub.cc' is properly blocked"
    else
        log "WARNING: Connection through incorrect hostname 'dbhub.cc' was NOT blocked"
    fi
    
    log "Subdomain access control test completed"
}

# Install PostgreSQL if not already installed
install_postgresql() {
    log "Installing PostgreSQL $PG_VERSION"
    
    # Add PostgreSQL repository
    if ! grep -q "apt.postgresql.org" /etc/apt/sources.list.d/pgdg.list 2>/dev/null; then
        log "Adding PostgreSQL repository"
        
        # Install dependencies
        apt-get update
        apt-get install -y curl ca-certificates gnupg
        
        # Create the repository configuration file
        sh -c 'echo "deb [arch=$(dpkg --print-architecture)] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
        
        # Import the repository signing key
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
        
        # Update apt package index
        apt-get update
    fi
    
    # Install PostgreSQL packages with specified version
    log "Installing PostgreSQL $PG_VERSION packages"
    apt-get install -y postgresql-$PG_VERSION postgresql-contrib-$PG_VERSION
    
    # Check if installation was successful
    if ! systemctl is-active --quiet postgresql; then
        log "Starting PostgreSQL service"
        systemctl start postgresql
    fi
    
    if ! systemctl is-active --quiet postgresql; then
        log "ERROR: Failed to start PostgreSQL service"
        return 1
    fi
    
    log "PostgreSQL $PG_VERSION installed successfully"
    return 0
}

# PostgreSQL installation and configuration functions

# Function to configure PostgreSQL
configure_postgresql() {
    log "Configuring PostgreSQL"
    
    # Check if PostgreSQL is running
    if ! pg_isready -q; then
        log "ERROR: PostgreSQL is not running, cannot configure"
        log "Attempting to start PostgreSQL"
        
        # Try to start the specific cluster
        if pg_lsclusters | grep -q "$PG_VERSION main"; then
            log "Starting PostgreSQL cluster $PG_VERSION main"
            pg_ctlcluster $PG_VERSION main start
            sleep 5
        else
            log "No PostgreSQL cluster found, creating one"
            pg_createcluster $PG_VERSION main
            pg_ctlcluster $PG_VERSION main start
            sleep 5
        fi
        
        # Check again if PostgreSQL is running
        if ! pg_isready -q; then
            log "ERROR: PostgreSQL still not running after attempts to start"
            log "Continuing with limited functionality"
        fi
    fi
    
    # Check if PostgreSQL configuration directory exists
    PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    if [ ! -d "$PG_CONF_DIR" ]; then
        log "Creating PostgreSQL configuration directory: $PG_CONF_DIR"
        mkdir -p "$PG_CONF_DIR"
        chown postgres:postgres "$PG_CONF_DIR"
    fi
    
    # Check if PostgreSQL configuration file exists
    PG_CONF_FILE="$PG_CONF_DIR/postgresql.conf"
    if [ ! -f "$PG_CONF_FILE" ]; then
        log "Creating basic PostgreSQL configuration file: $PG_CONF_FILE"
        cat > "$PG_CONF_FILE" << EOF
# Basic PostgreSQL configuration file
listen_addresses = 'localhost'
port = 5432
max_connections = 100
shared_buffers = 128MB
dynamic_shared_memory_type = posix
max_wal_size = 1GB
min_wal_size = 80MB
log_timezone = 'UTC'
datestyle = 'iso, mdy'
timezone = 'UTC'
lc_messages = 'en_US.UTF-8'
lc_monetary = 'en_US.UTF-8'
lc_numeric = 'en_US.UTF-8'
lc_time = 'en_US.UTF-8'
default_text_search_config = 'pg_catalog.english'
EOF
        chown postgres:postgres "$PG_CONF_FILE"
        chmod 644 "$PG_CONF_FILE"
    fi
    
    # Backup PostgreSQL configuration files
    backup_file "$PG_CONF_FILE"
    backup_file "$PG_CONF_DIR/pg_hba.conf"
    
    # Configure PostgreSQL to listen on appropriate interfaces
    if [ "$ENABLE_REMOTE_ACCESS" = "true" ]; then
        log "Configuring PostgreSQL to listen on all interfaces"
        sed -i "s/#\?listen_addresses\s*=\s*'.*'/listen_addresses = '*'/" "$PG_CONF_FILE"
    else
        log "Configuring PostgreSQL to listen on localhost only"
        sed -i "s/#\?listen_addresses\s*=\s*'.*'/listen_addresses = 'localhost'/" "$PG_CONF_FILE"
    fi
    
    # Configure PostgreSQL authentication
    log "Configuring PostgreSQL authentication with SCRAM-SHA-256"
    sed -i "s/#\?password_encryption\s*=\s*\w*/password_encryption = scram-sha-256/" "$PG_CONF_FILE"
    
    # Configure PostgreSQL SSL
    log "Configuring PostgreSQL SSL"
    sed -i "s/#\?ssl\s*=\s*\w*/ssl = on/" "$PG_CONF_FILE"
    
    # Configure PostgreSQL client authentication
    log "Configuring PostgreSQL client authentication"
    PG_HBA_FILE="$PG_CONF_DIR/pg_hba.conf"
    
    # Backup pg_hba.conf
    backup_file "$PG_HBA_FILE"
    
    # Configure pg_hba.conf
    cat > "$PG_HBA_FILE" << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# "local" is for Unix domain socket connections only
local   all             postgres                                peer
local   all             all                                     scram-sha-256
# IPv4 local connections:
host    all             all             127.0.0.1/32            scram-sha-256
# IPv6 local connections:
host    all             all             ::1/128                 scram-sha-256
EOF
    
    # Add remote access if enabled
    if [ "$ENABLE_REMOTE_ACCESS" = "true" ]; then
        log "Adding remote access to PostgreSQL"
        echo "# Allow remote connections:" >> "$PG_HBA_FILE"
        echo "host    all             all             0.0.0.0/0               scram-sha-256" >> "$PG_HBA_FILE"
        echo "host    all             all             ::/0                    scram-sha-256" >> "$PG_HBA_FILE"
    fi
    
    # Set PostgreSQL password
    log "Setting PostgreSQL password"
    
    # Check if PostgreSQL is running before setting password
    if pg_isready -q; then
        log "Setting PostgreSQL password for postgres user"
        # Use a more reliable method to set password
        sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$PG_PASSWORD';" || {
            log "ERROR: Failed to set PostgreSQL password using ALTER USER"
            log "Trying alternative method"
            echo "postgres:$PG_PASSWORD" | sudo chpasswd
            sudo -u postgres psql -c "SELECT pg_reload_conf();"
        }
    else
        log "WARNING: PostgreSQL is not running, cannot set password"
        log "Password will be set when PostgreSQL is restarted"
        
        # Create a script to set the password on next boot
        PG_PASSWORD_SCRIPT="/var/lib/postgresql/set_password.sh"
        cat > "$PG_PASSWORD_SCRIPT" << EOF
#!/bin/bash
psql -c "ALTER USER postgres WITH PASSWORD '$PG_PASSWORD';"
rm "\$0"
EOF
        chmod 700 "$PG_PASSWORD_SCRIPT"
        chown postgres:postgres "$PG_PASSWORD_SCRIPT"
        
        # Add to postgres user's profile
        POSTGRES_PROFILE="/var/lib/postgresql/.profile"
        if [ -f "$POSTGRES_PROFILE" ]; then
            if ! grep -q "set_password.sh" "$POSTGRES_PROFILE"; then
                echo "[ -f /var/lib/postgresql/set_password.sh ] && /var/lib/postgresql/set_password.sh" >> "$POSTGRES_PROFILE"
            fi
        else
            echo "[ -f /var/lib/postgresql/set_password.sh ] && /var/lib/postgresql/set_password.sh" > "$POSTGRES_PROFILE"
            chown postgres:postgres "$POSTGRES_PROFILE"
        fi
    fi
    
    # Restart PostgreSQL to apply changes
    log "Restarting PostgreSQL to apply configuration changes"
    if pg_lsclusters | grep -q "$PG_VERSION main"; then
        pg_ctlcluster $PG_VERSION main restart
    else
        if systemctl list-unit-files | grep -q "postgresql@$PG_VERSION-main"; then
            systemctl restart postgresql@$PG_VERSION-main
        else
            systemctl restart postgresql
        fi
    fi
    
    # Wait for PostgreSQL to restart
    sleep 5
    
    # Verify PostgreSQL is running
    if pg_isready -q; then
        log "PostgreSQL successfully restarted and is running"
    else
        log "WARNING: PostgreSQL may not be running after restart"
        log "Current PostgreSQL cluster status:"
        pg_lsclusters
        
        # Try one more time with a different approach
        log "Attempting to start PostgreSQL with a different approach"
        systemctl stop postgresql
        sleep 2
        systemctl start postgresql@$PG_VERSION-main || systemctl start postgresql
        sleep 5
        
        if pg_isready -q; then
            log "PostgreSQL successfully started with alternative approach"
        else
            log "ERROR: Failed to start PostgreSQL after multiple attempts"
            log "Please check PostgreSQL logs: journalctl -u postgresql@$PG_VERSION-main"
        fi
    fi
}

# Function to optimize PostgreSQL settings
optimize_postgresql() {
    log "Optimizing PostgreSQL settings"
    
    # Get system resources
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    CPU_COUNT=$(nproc)
    
    # Calculate optimal settings
    SHARED_BUFFERS=$((TOTAL_MEM_MB / 4))
    EFFECTIVE_CACHE_SIZE=$((TOTAL_MEM_MB * 3 / 4))
    WORK_MEM=$((TOTAL_MEM_MB / 4 / 100))
    MAINTENANCE_WORK_MEM=$((TOTAL_MEM_MB / 16))
    MAX_CONNECTIONS=$((CPU_COUNT * 20))
    
    # Update PostgreSQL configuration
    PG_CONF_FILE="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    
    log "Setting shared_buffers to ${SHARED_BUFFERS}MB"
    sed -i "s/shared_buffers\s*=\s*[0-9]*\w*/shared_buffers = ${SHARED_BUFFERS}MB/" "$PG_CONF_FILE"
    
    log "Setting effective_cache_size to ${EFFECTIVE_CACHE_SIZE}MB"
    if grep -q "effective_cache_size" "$PG_CONF_FILE"; then
        sed -i "s/effective_cache_size\s*=\s*[0-9]*\w*/effective_cache_size = ${EFFECTIVE_CACHE_SIZE}MB/" "$PG_CONF_FILE"
    else
        echo "effective_cache_size = ${EFFECTIVE_CACHE_SIZE}MB" >> "$PG_CONF_FILE"
    fi
    
    log "Setting work_mem to ${WORK_MEM}MB"
    sed -i "s/work_mem\s*=\s*[0-9]*\w*/work_mem = ${WORK_MEM}MB/" "$PG_CONF_FILE"
    
    log "Setting maintenance_work_mem to ${MAINTENANCE_WORK_MEM}MB"
    if grep -q "maintenance_work_mem" "$PG_CONF_FILE"; then
        sed -i "s/maintenance_work_mem\s*=\s*[0-9]*\w*/maintenance_work_mem = ${MAINTENANCE_WORK_MEM}MB/" "$PG_CONF_FILE"
    else
        echo "maintenance_work_mem = ${MAINTENANCE_WORK_MEM}MB" >> "$PG_CONF_FILE"
    fi
    
    log "Setting max_connections to $MAX_CONNECTIONS"
    sed -i "s/max_connections\s*=\s*[0-9]*/max_connections = $MAX_CONNECTIONS/" "$PG_CONF_FILE"
    
    # Optimize based on CPU count
    log "Setting max_worker_processes to $CPU_COUNT"
    if grep -q "max_worker_processes" "$PG_CONF_FILE"; then
        sed -i "s/max_worker_processes\s*=\s*[0-9]*/max_worker_processes = $CPU_COUNT/" "$PG_CONF_FILE"
    else
        echo "max_worker_processes = $CPU_COUNT" >> "$PG_CONF_FILE"
    fi
    
    log "Setting max_parallel_workers to $CPU_COUNT"
    if grep -q "max_parallel_workers" "$PG_CONF_FILE"; then
        sed -i "s/max_parallel_workers\s*=\s*[0-9]*/max_parallel_workers = $CPU_COUNT/" "$PG_CONF_FILE"
    else
        echo "max_parallel_workers = $CPU_COUNT" >> "$PG_CONF_FILE"
    fi
    
    # Restart PostgreSQL to apply changes
    restart_service "postgresql"
}

# Function to create a database user with restricted visibility
create_restricted_user() {
    local db_name="$1"
    local user_name="$2"
    local user_password="${3:-$(generate_password)}"
    local read_only="${4:-false}"
    
    log "Creating restricted user '$user_name' for database '$db_name'"
    
    # Check if PostgreSQL is running
    if ! pg_isready -q; then
        log "ERROR: PostgreSQL is not running, cannot create user"
        return 1
    fi
    
    # Create SQL script for user creation
    local SQL_SCRIPT="/tmp/create_user_${user_name}.sql"
    
    # Build SQL based on whether this is a read-only user
    if [ "$read_only" = "true" ]; then
        cat > "$SQL_SCRIPT" << EOF
-- Create read-only user
CREATE USER ${user_name} WITH PASSWORD '${user_password}';

-- Connect to the target database
\c ${db_name}

-- Grant connect privilege on the database
GRANT CONNECT ON DATABASE ${db_name} TO ${user_name};

-- Grant usage on schema
GRANT USAGE ON SCHEMA public TO ${user_name};

-- Grant select on all tables
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${user_name};

-- Grant select on future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${user_name};

-- Apply database visibility restrictions
ALTER ROLE ${user_name} SET search_path TO "\$user", public;

-- Force non-superusers to use pg_database_view instead of pg_database
ALTER ROLE ${user_name} SET pg_catalog.pg_database TO pg_catalog.pg_database_view;
EOF
    else
        cat > "$SQL_SCRIPT" << EOF
-- Create user with write access
CREATE USER ${user_name} WITH PASSWORD '${user_password}';

-- Connect to the target database
\c ${db_name}

-- Grant connect privilege on the database
GRANT CONNECT ON DATABASE ${db_name} TO ${user_name};

-- Grant usage on schema
GRANT USAGE, CREATE ON SCHEMA public TO ${user_name};

-- Grant privileges on all tables
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${user_name};

-- Grant privileges on all sequences
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO ${user_name};

-- Grant privileges on future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${user_name};

-- Grant privileges on future sequences
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO ${user_name};

-- Apply database visibility restrictions
ALTER ROLE ${user_name} SET search_path TO "\$user", public;

-- Force non-superusers to use pg_database_view instead of pg_database
ALTER ROLE ${user_name} SET pg_catalog.pg_database TO pg_catalog.pg_database_view;
EOF
    fi
    
    # Execute the SQL script as the PostgreSQL superuser
    log "Creating user and setting permissions"
    sudo -u postgres psql -f "$SQL_SCRIPT"
    
    # Clean up
    rm -f "$SQL_SCRIPT"
    
    # Create connection info
    local PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    local MAP_FILE="$PG_CONF_DIR/pg_hostname_map.conf"
    local subdomain=$(grep "^${db_name} " "$MAP_FILE" | awk '{print $2}' | cut -d. -f1)
    
    local CONNECTION_INFO="db_name=${db_name}
db_user=${user_name}
db_password=${user_password}
db_host=${subdomain:-$db_name}.${DOMAIN_SUFFIX}
db_port=5432"
    
    log "User ${user_name} created successfully with restricted visibility"
    log "Connection information: ${CONNECTION_INFO}"
    
    # Return the user password
    echo "${user_password}"
}

# Function to create a new database with restricted visibility
create_restricted_database() {
    local db_name="$1"
    local admin_password="${2:-$(generate_password)}"
    local subdomain="${3:-$db_name}"
    
    log "Creating new database '$db_name' with restricted visibility and subdomain access"
    
    # Check if PostgreSQL is running
    if ! pg_isready -q; then
        log "ERROR: PostgreSQL is not running, cannot create database"
        return 1
    fi
    
    # Create SQL script for database creation
    local SQL_SCRIPT="/tmp/create_db_${db_name}.sql"
    
    cat > "$SQL_SCRIPT" << EOF
-- Create database
CREATE DATABASE ${db_name};

-- Create admin user for this database
CREATE USER admin_${db_name} WITH PASSWORD '${admin_password}';

-- Grant admin privileges on the database
GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO admin_${db_name};

-- Connect to the new database to set up permissions
\c ${db_name}

-- Revoke public schema privileges
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE ${db_name} FROM PUBLIC;

-- Set up proper permissions for admin user
GRANT ALL PRIVILEGES ON SCHEMA public TO admin_${db_name};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO admin_${db_name};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO admin_${db_name};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO admin_${db_name};

-- Apply database visibility restrictions
ALTER ROLE admin_${db_name} SET search_path TO "\$user", public;

-- Force non-superusers to use pg_database_view instead of pg_database
ALTER ROLE admin_${db_name} SET pg_catalog.pg_database TO pg_catalog.pg_database_view;
EOF
    
    # Execute the SQL script as the PostgreSQL superuser
    log "Creating database and setting permissions"
    sudo -u postgres psql -f "$SQL_SCRIPT"
    
    # Update the hostname mapping for subdomain access
    update_hostname_map_conf "$db_name" "$subdomain"
    
    # Configure database-specific connection restrictions
    configure_db_connection_restrictions "$db_name" "$subdomain"
    
    # Clean up
    rm -f "$SQL_SCRIPT"
    
    # Create connection info
    local CONNECTION_INFO="db_name=${db_name}
db_user=admin_${db_name}
db_password=${admin_password}
db_host=${subdomain}.${DOMAIN_SUFFIX}
db_port=5432"
    
    log "Database ${db_name} created successfully with restricted visibility"
    log "Connection information: ${CONNECTION_INFO}"
    
    # Return the admin password
    echo "${admin_password}"
}

# Function to save database credentials to a file
save_database_credentials() {
    local db_name="$1"
    local user_name="$2"
    local password="$3"

    log "Saving database credentials to file"

    # Define the credentials directory
    local credentials_dir="/opt/dbhub/credentials"
    local credentials_file="$credentials_dir/${db_name}_credentials.txt"

    # Create credentials directory if it doesn't exist
    mkdir -p "$credentials_dir" 2>/dev/null || {
        log "WARNING: Could not create credentials directory at $credentials_dir"
        log "Credentials will not be saved"
        return 1
    }

    # Save the credentials to a file
    cat > "$credentials_file" << EOF
# Database Credentials for $db_name
# SECURITY WARNING: Keep this file secure and private

DATABASE_NAME=$db_name
DATABASE_USER=$user_name
DATABASE_PASSWORD=$password
DATABASE_HOST=localhost
DATABASE_PORT=5432

# Connection string examples:
# Direct PostgreSQL Connection:
# "postgresql://$user_name:$password@localhost:5432/$db_name"
# 
# Via PgBouncer:
# "postgresql://$user_name:$password@localhost:6432/$db_name"
#
# Command line connection example:
# PGPASSWORD=$password psql -h localhost -p 5432 -U $user_name -d $db_name
EOF

    # Secure the credentials file
    chmod 600 "$credentials_file" 2>/dev/null || log "WARNING: Could not set permissions on credentials file"

    log "Database credentials saved to: $credentials_file"
    return 0
}

# Function to create a demo database and user with thorough cleanup operations
_module_create_demo_database() {
    local db_name="${1:-demo}"
    local user_name="${2:-demo}"
    local password="${3:-$(generate_password)}"
    
    log "Creating demo database '$db_name' and user '$user_name'"
    
    # Check if PostgreSQL is running
    if ! pg_isready -q; then
        log "ERROR: PostgreSQL is not running, cannot create demo database"
        return 1
    fi
    
    # Derived settings
    local role_name="${user_name}_role"
    
    # First perform cleanup of any existing demo database/user
    log "Checking if demo user exists and cleaning up if needed"
    
    # Check if user already exists
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$user_name'" 2>/dev/null | grep -q "1"; then
        log "Demo user already exists, performing cleanup"
        
        # First change ownership of the database to postgres if it exists
        if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" 2>/dev/null | grep -q "1"; then
            log "Changing ownership of $db_name database to postgres"
            sudo -u postgres psql -c "ALTER DATABASE $db_name OWNER TO postgres;"
        fi
        
        # Revoke all privileges from the user on all databases
        log "Revoking privileges for $user_name on all databases"
        sudo -u postgres psql -c "REVOKE ALL PRIVILEGES ON DATABASE $db_name FROM $user_name;" || true
        sudo -u postgres psql -c "REVOKE ALL PRIVILEGES ON DATABASE postgres FROM $user_name;" || true
        
        # Drop the database-specific role if it exists
        if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$role_name'" 2>/dev/null | grep -q "1"; then
            log "Dropping database-specific role: $role_name"
            
            # First handle dependencies by reassigning ownership of all objects owned by the role
            if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" 2>/dev/null | grep -q "1"; then
                log "Checking for objects owned by $role_name in $db_name database"
                
                # Try with DROP OWNED BY first to reset dependency chain
                log "Removing all objects owned by $role_name using DROP OWNED BY"
                sudo -u postgres psql -d "$db_name" -c "DROP OWNED BY $role_name CASCADE;" || true
                
                # Try to drop the role immediately after dropping owned objects
                sudo -u postgres psql -c "DROP ROLE IF EXISTS $role_name;" && {
                    log "Successfully dropped role $role_name after dropping owned objects"
                } || {
                    # If drop still fails, try more aggressive approach with direct SQL
                    log "Role still exists. Trying more aggressive approach to reassign ownership."
                    
                    # Reassign database ownership first if needed
                    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name' AND datdba=(SELECT oid FROM pg_roles WHERE rolname='$role_name')" 2>/dev/null | grep -q "1"; then
                        log "Reassigning database ownership from $role_name to postgres"
                        sudo -u postgres psql -c "ALTER DATABASE $db_name OWNER TO postgres;"
                    fi
                    
                    # Identify and fix any grants for the role that might be causing issues
                    log "Removing grants to/from the role"
                    sudo -u postgres psql -d "$db_name" -c "REVOKE ALL ON ALL TABLES IN SCHEMA public FROM $role_name;" || true
                    sudo -u postgres psql -d "$db_name" -c "REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM $role_name;" || true
                    sudo -u postgres psql -d "$db_name" -c "REVOKE ALL ON SCHEMA public FROM $role_name;" || true
                    
                    # Find dependent objects directly using detailed catalog queries
                    log "Finding and reassigning specific dependent objects"
                    sudo -u postgres psql -d "$db_name" << EOF
-- Create a temporary function to identify and fix object dependencies
DO \$\$
DECLARE
    obj record;
    dependent record;
    cmd text;
BEGIN
    -- List members of the role and remove them
    FOR obj IN SELECT rolname FROM pg_roles WHERE pg_has_role(rolname, '$role_name', 'MEMBER')
    LOOP
        EXECUTE 'REVOKE $role_name FROM ' || quote_ident(obj.rolname);
        RAISE NOTICE 'Revoked membership from %', obj.rolname;
    END LOOP;
    
    -- Reassign default privileges
    FOR obj IN SELECT nspname, rolname FROM pg_namespace n, pg_roles r 
              WHERE r.rolname = '$role_name'
    LOOP
        BEGIN
            EXECUTE 'ALTER DEFAULT PRIVILEGES FOR ROLE ' || quote_ident('$role_name') || 
                    ' IN SCHEMA ' || quote_ident(obj.nspname) || ' GRANT ALL ON TABLES TO postgres';
            RAISE NOTICE 'Altered default privileges in schema %', obj.nspname;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error altering default privileges: %', SQLERRM;
        END;
    END LOOP;
    
    -- Find and fix any foreign key constraints where the role is referenced
    FOR obj IN SELECT conname, conrelid::regclass::text as tabname
              FROM pg_constraint
              WHERE contype = 'f' 
              AND (conrelid::regclass::text IN 
                   (SELECT tablename FROM pg_tables WHERE tableowner = '$role_name'))
    LOOP
        BEGIN
            EXECUTE 'ALTER TABLE ' || obj.tabname || ' DROP CONSTRAINT ' || quote_ident(obj.conname);
            RAISE NOTICE 'Dropped foreign key constraint % on table %', obj.conname, obj.tabname;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error dropping constraint: %', SQLERRM;
        END;
    END LOOP;
    
    -- Reassign all objects of every type using pg_depend
    FOR obj IN SELECT DISTINCT classid::regclass::text as objtype, objid::regclass::text as objname
              FROM pg_depend d JOIN pg_authid a ON d.refobjid = a.oid
              WHERE a.rolname = '$role_name'
              AND classid::regclass::text NOT LIKE 'pg_%'
    LOOP
        BEGIN
            IF obj.objtype = 'pg_class' THEN
                EXECUTE 'ALTER TABLE ' || obj.objname || ' OWNER TO postgres';
                RAISE NOTICE 'Changed ownership of % to postgres', obj.objname;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Error changing ownership of %: %', obj.objname, SQLERRM;
        END;
    END LOOP;
END
\$\$;
EOF
                    
                    # Try one more DROP OWNED to be sure
                    log "Performing final DROP OWNED to clear any remaining dependencies"
                    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$role_name'" 2>/dev/null | grep -q "1"; then
                        sudo -u postgres psql -c "DROP OWNED BY $role_name CASCADE;" || true
                    else
                        log "Role $role_name does not exist, skipping final DROP OWNED step"
                    fi
                    
                    # Now try to drop the role again
                    log "Attempting to drop role after dependencies have been cleared"
                }

            
            # Now try to drop the role
            sudo -u postgres psql -c "DROP ROLE IF EXISTS $role_name;"
            
            # If it still fails, try one final approach
            if [ $? -ne 0 ]; then
                log "Still unable to drop role due to dependencies. Using database-level approach..."
                
                # Try to force cascade drop at database level
                sudo -u postgres psql -d "$db_name" << EOF
DO \$\$
BEGIN
    -- Try to revoke all privileges granted by the role
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM $role_name';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM $role_name';
    EXECUTE 'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM $role_name';
    
    -- Try to revoke all privileges granted to the role
    EXECUTE 'REVOKE ALL PRIVILEGES ON DATABASE $db_name FROM $role_name';
    EXECUTE 'REVOKE ALL PRIVILEGES ON SCHEMA public FROM $role_name';
    
    -- Final attempt to drop any owned objects
    EXECUTE 'DROP OWNED BY $role_name CASCADE';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error during final cleanup: %', SQLERRM;
END;
\$\$;
EOF
                
                # Ultra-aggressive dependency removal approach
                log "Using aggressive dependency removal approach..."
                sudo -u postgres psql -d "$db_name" << EOF
DO \$\$
DECLARE
    obj record;
    dep record;
BEGIN
    -- Identify and fix all objects that depend on the role
    FOR obj IN 
        SELECT DISTINCT 
            cl.oid as objoid,
            cl.relname as objname, 
            n.nspname as schema
        FROM pg_class cl
        JOIN pg_namespace n ON cl.relnamespace = n.oid
        JOIN pg_depend d ON d.objid = cl.oid
        JOIN pg_authid a ON d.refobjid = a.oid
        WHERE a.rolname = '$role_name'
        AND n.nspname NOT LIKE 'pg_%'
    LOOP
        -- For each object, change its owner to postgres
        BEGIN
            EXECUTE format('ALTER %s %I.%I OWNER TO postgres', 
                          CASE 
                            WHEN EXISTS (SELECT 1 FROM pg_tables WHERE schemaname=obj.schema AND tablename=obj.objname) THEN 'TABLE'
                            WHEN EXISTS (SELECT 1 FROM pg_views WHERE schemaname=obj.schema AND viewname=obj.objname) THEN 'VIEW'
                            WHEN EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON t.typnamespace=n.oid 
                                        WHERE n.nspname=obj.schema AND t.typname=obj.objname) THEN 'TYPE'
                            ELSE 'TABLE'
                          END,
                          obj.schema, obj.objname);
            RAISE NOTICE 'Changed owner of %.% to postgres', obj.schema, obj.objname;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Could not change owner of %.%: %', obj.schema, obj.objname, SQLERRM;
        END;
    END LOOP;
    
    -- Try to clean up functions owned by the role
    FOR obj IN 
        SELECT p.oid, p.proname, n.nspname as schema
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE p.proowner = (SELECT oid FROM pg_authid WHERE rolname = '$role_name')
        AND n.nspname NOT LIKE 'pg_%'
    LOOP
        BEGIN
            EXECUTE format('ALTER FUNCTION %I.%I() OWNER TO postgres', obj.schema, obj.proname);
            RAISE NOTICE 'Changed owner of function %.% to postgres', obj.schema, obj.proname;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Could not change owner of function %.%: %', obj.schema, obj.proname, SQLERRM;
        END;
    END LOOP;
    
    -- Try to clean up acess privileges referencing this role
    EXECUTE 'UPDATE pg_class SET relacl = NULL WHERE relacl::text LIKE ''%' || '$role_name' || '%''';
    EXECUTE 'UPDATE pg_proc SET proacl = NULL WHERE proacl::text LIKE ''%' || '$role_name' || '%''';
    EXECUTE 'UPDATE pg_namespace SET nspacl = NULL WHERE nspacl::text LIKE ''%' || '$role_name' || '%''';
    EXECUTE 'UPDATE pg_type SET typacl = NULL WHERE typacl::text LIKE ''%' || '$role_name' || '%''';
    
    -- Final DROP OWNED attempt
    BEGIN
        EXECUTE 'DROP OWNED BY $role_name CASCADE';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Final DROP OWNED failed: %', SQLERRM;
    END;
END \$\$;
EOF

                # Direct PostgreSQL operation on the database after the here-document
                sudo -u postgres psql -d "$db_name" -c "DROP OWNED BY $role_name CASCADE;" || true

                # Try dropping the role one final time
                sudo -u postgres psql -c "DROP ROLE IF EXISTS $role_name;"

                # If it still fails, warn but continue with script
                if [ $? -ne 0 ]; then
                    log "WARNING: Unable to drop role $role_name despite multiple attempts. This may leave orphaned objects."
                    log "WARNING: Proceeding with the rest of the script. Manual cleanup may be needed later."
                else
                    log "Successfully dropped role $role_name after extensive cleanup"
                fi
            fi
        fi
    fi
    
    # Check if role owns any objects in the demo database and reassign them to postgres
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" 2>/dev/null | grep -q "1"; then
        log "Reassigning owned objects in $db_name database to postgres"
        sudo -u postgres psql -c "REASSIGN OWNED BY $user_name TO postgres;" || true
        sudo -u postgres psql -d "$db_name" -c "REASSIGN OWNED BY $user_name TO postgres;" || true
        
        log "Performing additional object cleanup in $db_name database"
        
        # Find remaining objects owned by the user in the demo database
        local objects_sql="SELECT nspname, relname, relkind FROM pg_class c
                         JOIN pg_namespace n ON c.relnamespace = n.oid
                         WHERE relowner = (SELECT oid FROM pg_roles WHERE rolname = '$user_name')
                         ORDER BY relkind, nspname, relname;"
        
        # Try to drop these objects - using -t (tuples only) and -A (unaligned) for clean output
        sudo -u postgres psql -d "$db_name" -t -A -F' ' -c "$objects_sql" | while read schema table kind; do
            [ -z "$schema" ] && continue
            
            if [ "$kind" = "r" ]; then # regular table
                log "Dropping table $schema.$table owned by $user_name"
                sudo -u postgres psql -d "$db_name" -c "DROP TABLE IF EXISTS $schema.$table CASCADE;"
            elif [ "$kind" = "v" ]; then # view
                log "Dropping view $schema.$table owned by $user_name"
                sudo -u postgres psql -d "$db_name" -c "DROP VIEW IF EXISTS $schema.$table CASCADE;"
            elif [ "$kind" = "S" ]; then # sequence
                log "Dropping sequence $schema.$table owned by $user_name"
                sudo -u postgres psql -d "$db_name" -c "DROP SEQUENCE IF EXISTS $schema.$table CASCADE;"
            elif [ "$kind" = "i" ]; then # index
                log "Dropping index $schema.$table owned by $user_name"
                sudo -u postgres psql -d "$db_name" -c "DROP INDEX IF EXISTS $schema.$table CASCADE;"
            fi
        done
        
        # Check for functions owned by the user
        local functions_sql="SELECT nspname, proname FROM pg_proc p
                          JOIN pg_namespace n ON p.pronamespace = n.oid
                          WHERE proowner = (SELECT oid FROM pg_roles WHERE rolname = '$user_name')
                          ORDER BY nspname, proname;"
        
        # Try to drop these functions - using -t (tuples only) and -A (unaligned) for clean output
        sudo -u postgres psql -d "$db_name" -t -A -F' ' -c "$functions_sql" | while read schema func; do
            [ -z "$schema" ] && continue
            
            log "Dropping function $schema.$func owned by $user_name"
            sudo -u postgres psql -d "$db_name" -c "DROP FUNCTION IF EXISTS $schema.$func CASCADE;"
        done
    fi
    
    # Drop owned by user in postgres database
    log "Dropping owned objects for $user_name in postgres database"
    # Check if role exists before trying to drop owned objects
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$user_name'" 2>/dev/null | grep -q "1"; then
        sudo -u postgres psql -c "DROP OWNED BY $user_name CASCADE;" || true
    else
        log "Role $user_name does not exist, skipping DROP OWNED step"
    fi
    
    # Try to drop the user directly
    log "Attempting to drop user $user_name"
    sudo -u postgres psql -c "DROP ROLE IF EXISTS $user_name;" && {
        log "User $user_name dropped successfully"
    } || {
        # Find and drop remaining dependencies in all databases
        log "Scanning all databases for remaining dependencies"
        sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1') AND datistemplate = false;" | while read db; do
            log "Checking database: $db"
            
            # If this is the demo database, try drastic measures - drop schemas owned by the user
            if [ "$db" = "$db_name" ]; then
                log "Taking drastic measures in demo database"
                
                # Try to drop schemas
                local schemas=$(sudo -u postgres psql -d "$db" -tAc "SELECT nspname FROM pg_namespace WHERE nspowner = (SELECT oid FROM pg_roles WHERE rolname = '$user_name');")
                
                for schema in $schemas; do
                    log "Dropping schema $schema owned by $user_name"
                    sudo -u postgres psql -d "$db" -c "DROP SCHEMA IF EXISTS $schema CASCADE;"
                done
                
                # Try again to drop role
                sudo -u postgres psql -c "DROP ROLE IF EXISTS $user_name;" && {
                    log "User $user_name dropped successfully after schema cleanup"
                    break
                }
            fi
            
            # Try to reassign ownership and drop owned as a last resort
            if sudo -u postgres psql -d "$db" -tAc "SELECT 1 FROM pg_roles WHERE rolname='$user_name'" 2>/dev/null | grep -q "1"; then
                sudo -u postgres psql -d "$db" -c "REASSIGN OWNED BY $user_name TO postgres; DROP OWNED BY $user_name CASCADE;" || true
            else
                log "Role $user_name does not exist in database $db, skipping reassign/drop owned steps"
            fi
        done
        
        # Try once more to drop the role
        sudo -u postgres psql -c "DROP ROLE IF EXISTS $user_name;" || {
            log "ERROR: Still could not drop user. Will continue with creating a new database."
            # Force drop and recreate the database as last resort
            log "Force dropping and recreating the demo database as last resort"
            
            # Generate a backup name for the database if we need to rename it
            local timestamp=$(date +%Y%m%d%H%M%S)
            local new_db_name="${db_name}_old_$timestamp"
            
            # Force drop database - without WITH (FORCE) which might not be supported in all versions
            # First terminate all connections
            log "Attempting to drop database forcefully"
            sudo -u postgres psql -c "UPDATE pg_database SET datallowconn = 'false' WHERE datname = '$db_name';" || true
            
            # Terminate existing connections
            sudo -u postgres psql -c "
                SELECT pg_terminate_backend(pg_stat_activity.pid)
                FROM pg_stat_activity
                WHERE pg_stat_activity.datname = '$db_name'
                AND pid <> pg_backend_pid();" || true
            
            # Wait a moment for connections to be terminated
            sleep 2
            
            # Now try to drop the database (should be no connections)
            sudo -u postgres psql -c "DROP DATABASE $db_name;" || {
                log "WARNING: Could not drop the database, trying to force connection termination again"
                
                # Wait longer and try again with more force
                sleep 5
                sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_name';" || true
                sudo -u postgres psql -c "DROP DATABASE $db_name;" || {
                    # Final desperate measure - rename the database
                    log "WARNING: Could not drop the database, renaming it instead"
                    
                    sudo -u postgres psql -c "ALTER DATABASE $db_name RENAME TO $new_db_name;" || true
                }
            }
        }
    }
    
    # Create demo database (make sure it's owned by postgres initially)
    log "Creating demo database"
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$db_name'" 2>/dev/null | grep -q "1"; then
        sudo -u postgres psql -c "CREATE DATABASE $db_name OWNER postgres;"
        log "Demo database created"
    else
        log "Demo database already exists, ensuring correct ownership"
        sudo -u postgres psql -c "ALTER DATABASE $db_name OWNER TO postgres;"
    fi
    
    # Create the demo user
    log "Creating demo user"
    sudo -u postgres psql -c "CREATE ROLE $user_name WITH LOGIN PASSWORD '$password';"
    
    # Create a database-specific role for stricter isolation
    log "Creating database-specific role"
    sudo -u postgres psql -c "CREATE ROLE $role_name;"
    
    # Start implementing multi-layered isolation measures
    
    # 1. Set up proper privileges and schema security
    log "Setting up schema security and privileges"
    
    # Connect to the demo database and set up its schema security
    sudo -u postgres psql -d "$db_name" -c "
        -- Revoke public schema usage from PUBLIC and grant it only to specific users
        REVOKE ALL ON SCHEMA public FROM PUBLIC;
        GRANT ALL ON SCHEMA public TO postgres;
        GRANT ALL ON SCHEMA public TO $role_name;
        GRANT USAGE ON SCHEMA public TO $user_name;
        
        -- Grant privileges on all existing tables
        GRANT ALL ON ALL TABLES IN SCHEMA public TO $role_name;
        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO $user_name;
        
        -- Grant privileges on all future tables
        ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
            GRANT ALL ON TABLES TO $role_name;
        ALTER DEFAULT PRIVILEGES FOR ROLE $role_name IN SCHEMA public
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO $user_name;
            
        -- Grant privileges on all sequences
        GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO $role_name;
        GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO $user_name;
        
        -- Grant privileges on all future sequences
        ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
            GRANT ALL ON SEQUENCES TO $role_name;
        ALTER DEFAULT PRIVILEGES FOR ROLE $role_name IN SCHEMA public
            GRANT USAGE, SELECT ON SEQUENCES TO $user_name;
    "
    
    # 2. Explicitly revoke connect permission to postgres database
    sudo -u postgres psql -c "REVOKE ALL ON DATABASE postgres FROM PUBLIC;"
    sudo -u postgres psql -c "REVOKE ALL ON DATABASE postgres FROM $user_name;"
    sudo -u postgres psql -c "REVOKE CONNECT ON DATABASE postgres FROM $user_name;"
    
    # 3. Grant specific privileges only to the demo database
    log "Setting up proper schema permissions in the demo database"
    sudo -u postgres psql -c "
        -- Grant connect to the demo database
        GRANT CONNECT ON DATABASE $db_name TO $user_name;
        
        -- Set the user's search_path to be restricted
        ALTER ROLE $user_name SET search_path TO $db_name, public;
    "
    
    # 4a. Block visibility of other databases through catalog views
    log "Restricting visibility of other databases"
    
    # Revoke access to system catalog views that expose database information
    sudo -u postgres psql -c "REVOKE SELECT ON pg_catalog.pg_database FROM $user_name;"
    
    # 4b. Create a database-specific view of pg_database that only shows the demo database
    
    # Create a database-specific role to strictly limit visibility
    log "Creating database-specific role for strict isolation"
    sudo -u postgres psql -c "
        -- Grant membership in the role to the user
        GRANT $role_name TO $user_name;
        
        -- Transfer ownership of the database to the role
        ALTER DATABASE $db_name OWNER TO ${user_name}_role;
    "
    
    # Create a function that fakes the pg_database view
    sudo -u postgres psql -d "$db_name" -c "CREATE OR REPLACE FUNCTION public.database_list() RETURNS SETOF pg_catalog.pg_database AS \$\$
        SELECT * FROM pg_catalog.pg_database WHERE datname = '$db_name';
    \$\$ LANGUAGE sql SECURITY DEFINER;"
    
    # Create a restricted view that only shows the demo database
    sudo -u postgres psql -d "$db_name" -c "CREATE OR REPLACE VIEW pg_database_filtered AS
        SELECT * FROM pg_catalog.pg_database WHERE datname = '$db_name';"
    
    # Grant permissions on the function and view
    sudo -u postgres psql -d "$db_name" -c "
        -- Grant select on the filtered view
        GRANT SELECT ON pg_database_filtered TO $user_name;
    "
    
    # Set ownership of the function to postgres (to prevent the user from modifying it)
    sudo -u postgres psql -d "$db_name" -c "ALTER FUNCTION public.database_list() OWNER TO postgres;"
    
    # Grant execute to the user
    sudo -u postgres psql -d "$db_name" -c "GRANT EXECUTE ON FUNCTION public.database_list() TO $user_name;"
    
    # 5. Apply hostname validation for the demo database subdomain
    if [ -z "$DOMAIN_SUFFIX" ]; then
        DOMAIN_SUFFIX="dbhub.cc"
    fi

    # Update hostname mapping for subdomain access
    update_hostname_map_conf "$db_name" "$db_name" "$DOMAIN_SUFFIX"
    
    # Configure database-specific connection restrictions
    configure_db_connection_restrictions "$db_name" "$db_name" "$DOMAIN_SUFFIX"
    
    # Reload PostgreSQL to apply changes
    pg_ctlcluster $PG_VERSION main reload || systemctl reload postgresql || true
    
    log "Demo database and user created with strict isolation"
    log "Demo user can ONLY access the $db_name database"
    log "The database is ONLY accessible through subdomain $db_name.$DOMAIN_SUFFIX"
    
    # Test the subdomain access restrictions
    test_subdomain_access "$db_name" "$db_name" "$DOMAIN_SUFFIX"

    # Store user info and credentials
    save_database_credentials "$db_name" "$user_name" "$password"

    # Return the user details for display in the summary
    echo "$db_name,$user_name,$password"
    return 0
}



