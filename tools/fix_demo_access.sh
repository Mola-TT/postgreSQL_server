#!/bin/bash

# Fix Demo Database Access Script
# This script fixes the issue where the demo database can be accessed through dbhub.cc

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
    log "Cannot proceed with the fix"
    exit 1
fi

log "Fix Demo Database Access Script"
log "----------------------------"

# Check if PostgreSQL is running
if ! pg_isready -q; then
    log "ERROR: PostgreSQL is not running, cannot fix database access"
    exit 1
fi

DB_NAME="demo"
SUBDOMAIN="demo"
DOMAIN="dbhub.cc"

# Check if demo database exists
if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    log "ERROR: Database '$DB_NAME' does not exist"
    exit 1
fi

log "Fixing access control for database '$DB_NAME'"

# Create a direct SQL fix to ensure the hostname validation is correctly enforced
sudo -u postgres psql -d "$DB_NAME" << EOF
-- Fix the hostname validation function for demo database
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
    allowed_hostname := '$SUBDOMAIN.$DOMAIN';
    
    -- Log connection attempt for debugging
    RAISE NOTICE 'Connection attempt: database=%, hostname=%, allowed=%', 
                 current_db, hostname, allowed_hostname;
    
    -- FIXED: Perform an exact match requirement for hostname
    -- The previous code was using position() which allowed partial matches
    IF hostname IS NULL OR hostname = '' OR hostname != allowed_hostname THEN
        -- Unauthorized hostname
        RAISE EXCEPTION 'Access to database "%" is only permitted through subdomain: %', 
                        current_db, allowed_hostname;
    END IF;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Ensure the event trigger is properly created
DROP EVENT TRIGGER IF EXISTS connection_hostname_validation;
CREATE EVENT TRIGGER connection_hostname_validation 
ON ddl_command_start
EXECUTE FUNCTION public.check_connection_hostname();

-- Grant execute permission to public
GRANT EXECUTE ON FUNCTION public.check_connection_hostname() TO PUBLIC;
EOF

if [ $? -ne 0 ]; then
    log "ERROR: Failed to update hostname validation for database '$DB_NAME'"
    exit 1
fi

log "Successfully updated hostname validation for database '$DB_NAME'"

# Also ensure global restrictions are applied
log "Applying global database visibility restrictions"
configure_database_visibility_restrictions

# Reload PostgreSQL configuration
log "Reloading PostgreSQL configuration"
if command -v pg_ctlcluster >/dev/null 2>&1; then
    pg_version=$(psql --version | head -n 1 | sed 's/^.* \([0-9]\+\.[0-9]\+\).*$/\1/')
    pg_ctlcluster "$pg_version" main reload
else
    systemctl reload postgresql
fi

log "PostgreSQL configuration reloaded"

# Restart PostgreSQL to ensure all changes take effect
log "Restarting PostgreSQL to apply all changes"
if command -v pg_ctlcluster >/dev/null 2>&1; then
    pg_version=$(psql --version | head -n 1 | sed 's/^.* \([0-9]\+\.[0-9]\+\).*$/\1/')
    pg_ctlcluster "$pg_version" main restart
else
    systemctl restart postgresql
fi

log "PostgreSQL restarted successfully"

# Test the fix
log "Testing the fix for database '$DB_NAME'"
log "Attempting connection via correct subdomain '$SUBDOMAIN.$DOMAIN'"
PGAPPNAME="$SUBDOMAIN.$DOMAIN" psql -U postgres -c "SELECT current_database()" "$DB_NAME" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    log "SUCCESS: Connection through correct subdomain '$SUBDOMAIN.$DOMAIN' works"
else
    log "WARNING: Could not connect through correct subdomain '$SUBDOMAIN.$DOMAIN'"
fi

log "Attempting connection via main domain 'dbhub.cc'"
PGAPPNAME="dbhub.cc" psql -U postgres -c "SELECT current_database()" "$DB_NAME" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    log "SUCCESS: Connection through incorrect hostname 'dbhub.cc' is properly blocked"
else
    log "WARNING: Connection through incorrect hostname 'dbhub.cc' is still NOT blocked"
    log "Additional troubleshooting may be required."
fi

log "Fix script completed"
exit 0 