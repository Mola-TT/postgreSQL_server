#!/bin/bash

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

# Configure database-specific connection restrictions
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
    
    -- Check if hostname matches allowed pattern
    IF position(allowed_hostname in hostname) = 0 THEN
        -- Unauthorized hostname
        RAISE EXCEPTION 'Access to database "%" is only permitted through subdomain: %', 
                        current_db, allowed_hostname;
    END IF;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger for connection events
DROP EVENT TRIGGER IF EXISTS connection_hostname_validation;
CREATE EVENT TRIGGER connection_hostname_validation 
ON ddl_command_start
EXECUTE FUNCTION public.check_connection_hostname();

-- Grant usage to public
GRANT EXECUTE ON FUNCTION public.check_connection_hostname() TO PUBLIC;
EOF
    
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to configure connection restrictions for database '$db_name'"
        return 1
    fi
    
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
                    -- Check if hostname matches allowed pattern
                    IF position(allowed_hostname in hostname) = 0 THEN
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
    log "Checking if PostgreSQL is installed"
    
    if is_postgresql_installed; then
        log "PostgreSQL is already installed"
        return 0
    fi
    
    log "Installing PostgreSQL"
    
    # Detect OS type
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$DISTRIB_ID
    else
        OS=$(uname -s)
    fi
    
    # Install based on OS
    case "$OS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y postgresql postgresql-contrib
            ;;
        fedora|rhel|centos)
            dnf install -y postgresql-server postgresql-contrib
            postgresql-setup --initdb --unit postgresql
            systemctl enable postgresql
            systemctl start postgresql
            ;;
        *)
            log "ERROR: Unsupported OS: $OS"
            return 1
            ;;
    esac
    
    log "PostgreSQL installed successfully"
    return 0
}

# PostgreSQL installation and configuration functions

# Function to install PostgreSQL
install_postgresql() {
    log "Installing PostgreSQL $PG_VERSION"
    
    # Add PostgreSQL repository
    if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
        log "Adding PostgreSQL repository"
        
        # Install dependencies
        apt-get update
        apt-get install -y wget gnupg lsb-release
        
        # Add PostgreSQL repository key
        wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/postgresql.gpg > /dev/null
        
        # Add PostgreSQL repository
        echo "deb [signed-by=/etc/apt/trusted.gpg.d/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
        
        # Update package lists
        apt-get update
    fi
    
    # Check if PostgreSQL is already installed
    if dpkg -l | grep -q "postgresql-$PG_VERSION"; then
        log "PostgreSQL $PG_VERSION is already installed"
        
        # Check if PostgreSQL is running
        if pg_isready -q; then
            log "PostgreSQL is already running"
            return 0
        else
            log "PostgreSQL is installed but not running, attempting to fix"
        fi
    else
        # Install PostgreSQL
        log "Installing PostgreSQL packages"
        apt-get install -y postgresql-$PG_VERSION postgresql-client-$PG_VERSION postgresql-contrib-$PG_VERSION
    fi
    
    # Wait for PostgreSQL to initialize
    log "Waiting for PostgreSQL to initialize"
    sleep 5
    
    # Check PostgreSQL clusters
    log "Checking PostgreSQL clusters"
    if ! pg_lsclusters | grep -q "$PG_VERSION main"; then
        log "No PostgreSQL $PG_VERSION main cluster found, creating one"
        pg_createcluster $PG_VERSION main
    fi
    
    # Ensure the correct service is enabled and started
    PG_SERVICE="postgresql@$PG_VERSION-main"
    if systemctl list-unit-files | grep -q "$PG_SERVICE"; then
        log "Enabling and starting $PG_SERVICE"
        systemctl enable $PG_SERVICE
        systemctl start $PG_SERVICE
    else
        log "Enabling and starting postgresql service"
        systemctl enable postgresql
        systemctl start postgresql
    fi
    
    # Wait for PostgreSQL to start
    log "Waiting for PostgreSQL to start"
    for i in {1..30}; do
        if pg_isready -q; then
            log "PostgreSQL is ready"
            break
        fi
        log "Waiting for PostgreSQL to become ready... ($i/30)"
        sleep 2
    done
    
    if ! pg_isready -q; then
        log "ERROR: PostgreSQL failed to start within the timeout period"
        log "Checking PostgreSQL cluster status:"
        pg_lsclusters
        
        # Try to fix common issues
        log "Attempting to fix PostgreSQL startup issues"
        
        # Check if data directory exists and has correct permissions
        PG_DATA_DIR="/var/lib/postgresql/$PG_VERSION/main"
        if [ ! -d "$PG_DATA_DIR" ]; then
            log "PostgreSQL data directory does not exist, creating it"
            mkdir -p "$PG_DATA_DIR"
            chown postgres:postgres "$PG_DATA_DIR"
            chmod 700 "$PG_DATA_DIR"
            
            # Initialize the database
            log "Initializing PostgreSQL database"
            sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/initdb -D "$PG_DATA_DIR"
        else
            log "Checking PostgreSQL data directory permissions"
            chown -R postgres:postgres "$PG_DATA_DIR"
            chmod 700 "$PG_DATA_DIR"
        fi
        
        # Try to start the cluster again
        log "Attempting to start PostgreSQL cluster again"
        pg_ctlcluster $PG_VERSION main start
        sleep 5
        
        # Final check
        if ! pg_isready -q; then
            log "ERROR: PostgreSQL still failed to start after fixes"
            log "Please check PostgreSQL logs: journalctl -u postgresql@$PG_VERSION-main"
            log "Continuing with limited functionality"
        else
            log "PostgreSQL successfully started after fixes"
        fi
    fi
}

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
    
    local CONNECTION_INFO="db_name=${db_name}\ndb_user=${user_name}\ndb_password=${user_password}\ndb_host=${subdomain:-$db_name}.${DOMAIN_SUFFIX}\ndb_port=5432"
    
    log "User ${user_name} created successfully with restricted visibility"
    log "Connection information: ${CONNECTION_INFO}"
    
    # Return the user password
    echo "${user_password}"
}

# Function to configure database-specific connection restrictions
configure_db_connection_restrictions() {
    local db_name="$1"
    local subdomain="$2"
    
    log "Configuring connection restrictions for database '$db_name' via subdomain '$subdomain'"
    
    # Check if PostgreSQL is running
    if ! pg_isready -q; then
        log "ERROR: PostgreSQL is not running, cannot configure connection restrictions"
        return 1
    fi
    
    # Create SQL script for connection restrictions
    local SQL_SCRIPT="/tmp/configure_db_connections_${db_name}.sql"
    
    cat > "$SQL_SCRIPT" << EOF
-- Create database-specific connection restrictions
\c ${db_name}

-- Prevent direct connections through the main domain for regular users
CREATE OR REPLACE FUNCTION public.check_connection_hostname()
RETURNS TRIGGER AS \$\$
DECLARE
    client_addr text;
    client_hostname text;
    expected_hostname text;
BEGIN
    -- Skip check for superuser
    IF (SELECT usesuper FROM pg_catalog.pg_user WHERE usename = SESSION_USER) THEN
        RETURN NEW;
    END IF;
    
    -- Get client information
    client_addr := inet_client_addr();
    client_hostname := inet_client_hostname();
    expected_hostname := '${subdomain}.${DOMAIN_SUFFIX}';
    
    -- Check if hostname matches expected value
    IF client_hostname IS NULL OR client_hostname != expected_hostname THEN
        RAISE EXCEPTION 'Access to database "${db_name}" is only allowed through subdomain "${subdomain}.${DOMAIN_SUFFIX}"';
    END IF;
    
    RETURN NEW;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create trigger to validate connections
DROP TRIGGER IF EXISTS check_connection_hostname_trigger ON public.pg_class;
CREATE TRIGGER check_connection_hostname_trigger
    BEFORE SELECT ON public.pg_class
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.check_connection_hostname();

-- Set a reminder message for all users connecting to this database
ALTER DATABASE ${db_name} SET client_min_messages TO 'notice';
COMMENT ON DATABASE ${db_name} IS 'Access only allowed through ${subdomain}.${DOMAIN_SUFFIX}';

EOF
    
    # Execute the SQL script
    log "Applying connection restrictions for database $db_name"
    sudo -u postgres psql -f "$SQL_SCRIPT"
    
    # Clean up
    rm -f "$SQL_SCRIPT"
    
    log "Database connection restrictions configured successfully"
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
    local CONNECTION_INFO="db_name=${db_name}\ndb_user=admin_${db_name}\ndb_password=${admin_password}\ndb_host=${subdomain}.${DOMAIN_SUFFIX}\ndb_port=5432"
    
    log "Database ${db_name} created successfully with restricted visibility"
    log "Connection information: ${CONNECTION_INFO}"
    
    # Return the admin password
    echo "${admin_password}"
} 