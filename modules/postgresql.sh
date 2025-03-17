#!/bin/bash

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

# Function to create a restricted database user
create_restricted_user() {
    local db_name="$1"
    local user_name="$2"
    local password="$3"
    
    log "Creating restricted user $user_name for database $db_name"
    
    # Check if PostgreSQL is running
    if pg_isready -q; then
        # Check if database exists
        if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
            log "Creating database $db_name"
            sudo -u postgres psql -c "CREATE DATABASE $db_name;" || {
                log "ERROR: Failed to create database $db_name"
                return 1
            }
        else
            log "Database $db_name already exists"
        fi
        
        # Check if user exists
        if ! sudo -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='$user_name'" | grep -q 1; then
            log "Creating user $user_name"
            sudo -u postgres psql -c "CREATE USER $user_name WITH ENCRYPTED PASSWORD '$password';" || {
                log "ERROR: Failed to create user $user_name"
                return 1
            }
        else
            log "User $user_name already exists, updating password"
            sudo -u postgres psql -c "ALTER USER $user_name WITH ENCRYPTED PASSWORD '$password';" || {
                log "ERROR: Failed to update password for user $user_name"
                return 1
            }
        fi
        
        # Grant privileges
        log "Granting privileges to $user_name on $db_name"
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $db_name TO $user_name;" || {
            log "ERROR: Failed to grant database privileges to $user_name"
            return 1
        }
        
        # Connect to the database to grant schema privileges
        if sudo -u postgres psql -d "$db_name" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO $user_name;"; then
            sudo -u postgres psql -d "$db_name" -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $user_name;"
            sudo -u postgres psql -d "$db_name" -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $user_name;"
            sudo -u postgres psql -d "$db_name" -c "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO $user_name;"
            
            # Revoke public privileges
            log "Revoking public privileges on $db_name"
            sudo -u postgres psql -d "$db_name" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC;"
            sudo -u postgres psql -d "$db_name" -c "REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;"
            sudo -u postgres psql -d "$db_name" -c "REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;"
            sudo -u postgres psql -d "$db_name" -c "REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;"
            
            log "User $user_name created and configured for database $db_name"
            return 0
        else
            log "WARNING: Could not connect to database $db_name to grant schema privileges"
            log "This may be because the database was just created and is not ready yet"
            log "Basic privileges have been granted, but schema privileges may be incomplete"
            return 0
        fi
    else
        log "ERROR: PostgreSQL is not running, cannot create user"
        log "Attempting to start PostgreSQL"
        
        # Try to start the specific cluster
        if pg_lsclusters | grep -q "$PG_VERSION main"; then
            pg_ctlcluster $PG_VERSION main start
            sleep 5
            
            if pg_isready -q; then
                log "PostgreSQL started, retrying user creation"
                create_restricted_user "$db_name" "$user_name" "$password"
                return $?
            else
                log "ERROR: Failed to start PostgreSQL, user not created"
                return 1
            fi
        else
            log "ERROR: No PostgreSQL cluster found, user not created"
            return 1
        fi
    fi
} 