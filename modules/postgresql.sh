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
    
    # Install PostgreSQL
    log "Installing PostgreSQL packages"
    apt-get install -y postgresql-$PG_VERSION postgresql-client-$PG_VERSION postgresql-contrib-$PG_VERSION
    
    # Wait for PostgreSQL to initialize
    log "Waiting for PostgreSQL to initialize"
    sleep 5
}

# Function to configure PostgreSQL
configure_postgresql() {
    log "Configuring PostgreSQL"
    
    # Check if PostgreSQL configuration directory exists
    PG_CONF_DIR="/etc/postgresql/$PG_VERSION/main"
    if [ ! -d "$PG_CONF_DIR" ]; then
        log "Creating PostgreSQL configuration directory: $PG_CONF_DIR"
        mkdir -p "$PG_CONF_DIR"
    fi
    
    # Check if PostgreSQL is properly installed
    if ! service_running "postgresql"; then
        log "PostgreSQL service not running, attempting to reinstall"
        apt-get install --reinstall -y postgresql-$PG_VERSION
        systemctl start postgresql
        sleep 5
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
    cat > "$PG_CONF_DIR/pg_hba.conf" << EOF
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
        echo "# Allow remote connections with password authentication" >> "$PG_CONF_DIR/pg_hba.conf"
        echo "host    all             all             0.0.0.0/0               scram-sha-256" >> "$PG_CONF_DIR/pg_hba.conf"
    fi
    
    # Set PostgreSQL password
    log "Setting PostgreSQL password"
    if service_running "postgresql"; then
        # Check if we can connect to PostgreSQL
        if sudo -u postgres psql -c "SELECT 1" > /dev/null 2>&1; then
            log "Setting PostgreSQL password for postgres user"
            sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$PG_PASSWORD';"
        else
            log "WARNING: Cannot connect to PostgreSQL, skipping password setup"
        fi
    else
        log "WARNING: PostgreSQL is not running, skipping password setup"
    fi
    
    # Create PostgreSQL data directory if it doesn't exist
    PG_DATA_DIR="/var/lib/postgresql/$PG_VERSION/main"
    if [ ! -d "$PG_DATA_DIR" ]; then
        log "Creating PostgreSQL data directory: $PG_DATA_DIR"
        mkdir -p "$PG_DATA_DIR"
        chown postgres:postgres "$PG_DATA_DIR"
        
        # Initialize PostgreSQL database
        log "Initializing PostgreSQL database"
        sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/initdb -D "$PG_DATA_DIR"
    fi
    
    # Restart PostgreSQL to apply changes
    restart_service "postgresql"
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
    if service_running "postgresql"; then
        # Check if database exists
        if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
            log "Creating database $db_name"
            sudo -u postgres psql -c "CREATE DATABASE $db_name;"
        fi
        
        # Check if user exists
        if ! sudo -u postgres psql -c "SELECT 1 FROM pg_roles WHERE rolname='$user_name'" | grep -q 1; then
            log "Creating user $user_name"
            sudo -u postgres psql -c "CREATE USER $user_name WITH ENCRYPTED PASSWORD '$password';"
        else
            log "User $user_name already exists, updating password"
            sudo -u postgres psql -c "ALTER USER $user_name WITH ENCRYPTED PASSWORD '$password';"
        fi
        
        # Grant privileges
        log "Granting privileges to $user_name on $db_name"
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $db_name TO $user_name;"
        sudo -u postgres psql -d "$db_name" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO $user_name;"
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
        log "ERROR: PostgreSQL is not running, cannot create user"
        return 1
    fi
} 