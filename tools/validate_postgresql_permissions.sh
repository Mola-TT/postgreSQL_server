#!/bin/bash

# Database Permission Validation Script
# This script tests various permission scenarios to verify proper database isolation.
# It automatically tries to connect using default credentials and handles both PostgreSQL and PgBouncer.

# Exit on command errors
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
  local level=$1
  local message=$2
  
  case "$level" in
    "INFO") 
      echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${GREEN}INFO${NC}: $message"
      ;;
    "WARN")
      echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${YELLOW}WARN${NC}: $message"
      ;;
    "ERROR")
      echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ${RED}ERROR${NC}: $message"
      ;;
    *)
      echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $message"
      ;;
  esac
}

# Load environment variables from .env file
if [ -f "../.env" ]; then
  # When running from tools/ directory
  source "../.env"
  ENV_LOADED=true
  log "INFO" "Loaded environment variables from ../.env"
elif [ -f ".env" ]; then
  # When running from project root
  source ".env"
  ENV_LOADED=true
  log "INFO" "Loaded environment variables from .env"
else
  ENV_LOADED=false
  log "WARN" "No .env file found, using default values"
fi

# Default connection parameters - will be auto-detected or loaded from .env
PG_HOST="localhost"
PG_PORT="${PG_PORT:-5432}"
PG_SUPERUSER="postgres"
PG_PASSWORD="${PG_PASSWORD:-postgres}"
USE_PGBOUNCER=false
PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
DEMO_DB_NAME="${DEMO_DB_NAME:-demo}"
DEMO_DB_USER="${DEMO_DB_USER:-demo}"
DEMO_DB_PASSWORD="${DEMO_DB_PASSWORD:-demo}"

# Function to test PostgreSQL connection
test_connection() {
  local host=$1
  local port=$2
  local user=$3
  local password=$4
  local db=$5
  
  PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$user" -d "$db" -c "SELECT 1;" &>/dev/null
  return $?
}

# Auto-detect PostgreSQL connection parameters
auto_detect_connection() {
  log "INFO" "Auto-detecting PostgreSQL connection parameters..."
  
  # Try connecting with credentials from .env first
  if [ "$ENV_LOADED" = true ]; then
    log "INFO" "Trying connection with credentials from .env file"
    
    # Try PostgreSQL direct connection first
    if test_connection "$PG_HOST" "$PG_PORT" "$PG_SUPERUSER" "$PG_PASSWORD" "postgres"; then
      USE_PGBOUNCER=false
      log "INFO" "✅ Successfully connected to PostgreSQL on port $PG_PORT with credentials from .env"
      return 0
    fi
    
    # Try PgBouncer connection
    if test_connection "$PG_HOST" "$PGBOUNCER_PORT" "$PG_SUPERUSER" "$PG_PASSWORD" "postgres"; then
      PG_PORT="$PGBOUNCER_PORT"
      USE_PGBOUNCER=true
      log "INFO" "✅ Successfully connected to PgBouncer on port $PGBOUNCER_PORT with credentials from .env"
      return 0
    fi
    
    log "WARN" "Could not connect with credentials from .env, trying fallback options"
  fi
  
  # Try different password options for postgres
  for pw in "postgres" "$PG_PASSWORD" ""; do
    # First, try connecting to PostgreSQL directly
    if test_connection "$PG_HOST" "5432" "$PG_SUPERUSER" "$pw" "postgres"; then
      PG_PORT="5432"
      PG_PASSWORD="$pw"
      USE_PGBOUNCER=false
      log "INFO" "✅ Successfully connected to PostgreSQL on port 5432"
      return 0
    fi
    
    # Then try connecting through PgBouncer if available
    if test_connection "$PG_HOST" "6432" "$PG_SUPERUSER" "$pw" "postgres"; then
      PG_PORT="6432"
      PG_PASSWORD="$pw"
      USE_PGBOUNCER=true
      log "INFO" "✅ Successfully connected to PgBouncer on port 6432"
      return 0
    fi
  done
  
  log "ERROR" "❌ Could not connect to PostgreSQL or PgBouncer using any of the attempted methods"
  log "ERROR" "Could not connect to PostgreSQL. Please check that the server is running."
  log "ERROR" "If PostgreSQL is running, try setting PGPASSWORD environment variable."
  log "ERROR" "Example: PGPASSWORD=mypassword ./validate_postgresql_permissions.sh"
  
  # Attempt to diagnose connection issues
  log "INFO" "Running connection diagnostics..."
  
  # Check if PostgreSQL is running
  if command -v systemctl &>/dev/null && systemctl is-active postgresql &>/dev/null; then
    log "INFO" "PostgreSQL service is running"
  else
    log "WARN" "PostgreSQL service may not be running"
  fi
  
  # Check if PgBouncer is running
  if command -v systemctl &>/dev/null && systemctl is-active pgbouncer &>/dev/null; then
    log "INFO" "PgBouncer service is running"
  else
    log "WARN" "PgBouncer service may not be running"
  fi
  
  # Check if ports are open
  if command -v nc &>/dev/null; then
    if nc -z "$PG_HOST" 5432 &>/dev/null; then
      log "INFO" "PostgreSQL port 5432 is open"
    else
      log "WARN" "PostgreSQL port 5432 is not accessible"
    fi
    
    if nc -z "$PG_HOST" 6432 &>/dev/null; then
      log "INFO" "PgBouncer port 6432 is open"
    else
      log "WARN" "PgBouncer port 6432 is not accessible"
    fi
  fi
  
  return 1
}

# Function to run SQL and capture result
run_sql() {
  local user=$1
  local password=$2
  local database=$3
  local sql=$4
  local expected_success=$5
  local description=$6
  
  result=$(PGPASSWORD="$password" psql -h "$PG_HOST" -p "$PG_PORT" -U "$user" -d "$database" -t -c "$sql" 2>&1 || true)
  
  if [[ $result == *"ERROR"* ]] || [[ $result == *"FATAL"* ]]; then
    if [ "$expected_success" = false ]; then
      log "INFO" "✅ TEST PASSED: $description - Access correctly denied"
      return 0
    else
      log "ERROR" "❌ TEST FAILED: $description - Unexpected access denied: $result"
      return 1
    fi
  else
    if [ "$expected_success" = true ]; then
      log "INFO" "✅ TEST PASSED: $description - Access correctly granted"
      return 0
    else
      log "ERROR" "❌ TEST FAILED: $description - Unexpected access granted: $result"
      return 1
    fi
  fi
}

# Function to check if a specific role exists
role_exists() {
  local role=$1
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -t -c "SELECT 1 FROM pg_roles WHERE rolname='$role'" | grep -q 1
  return $?
}

# Function to check if a specific database exists
db_exists() {
  local db=$1
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1
  return $?
}

# Cleanup existing test database and users if they exist
cleanup() {
  log "INFO" "Cleaning up existing test environment..."
  
  # Connect as postgres to perform cleanup
  if db_exists "test"; then
    log "INFO" "Terminating all connections to the test database"
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='test' AND pid <> pg_backend_pid();" > /dev/null 2>&1 || true
    
    log "INFO" "Dropping test database"
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -c "DROP DATABASE IF EXISTS test;" > /dev/null 2>&1 || true
  fi
  
  # Drop test users if they exist
  for user in "testadmin" "testuser"; do
    if role_exists "$user"; then
      log "INFO" "Dropping role $user"
      PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -c "DROP OWNED BY $user CASCADE;" > /dev/null 2>&1 || true
      PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -c "DROP ROLE $user;" > /dev/null 2>&1 || true
    fi
  done
}

# Set up test environment
setup() {
  log "INFO" "Setting up test environment..."
  
  # Create test database owned by postgres initially
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -c "CREATE DATABASE test;" > /dev/null 2>&1
  
  # Create test admin user
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -c "CREATE USER testadmin WITH PASSWORD 'testadmin';" > /dev/null 2>&1
  
  # Create regular test user
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -c "CREATE USER testuser WITH PASSWORD 'testuser';" > /dev/null 2>&1
  
  # Grant admin privileges to testadmin for test database
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d postgres -c "ALTER DATABASE test OWNER TO testadmin;" > /dev/null 2>&1
  
  # Connect to test database and set up permissions
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d test -c "GRANT CONNECT ON DATABASE test TO testuser;" > /dev/null 2>&1
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d test -c "GRANT USAGE ON SCHEMA public TO testuser;" > /dev/null 2>&1
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d test -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO testuser;" > /dev/null 2>&1
  PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_SUPERUSER" -d test -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO testuser;" > /dev/null 2>&1
  
  log "INFO" "Test environment setup complete"
}

# Run tests for a specific user
run_user_tests() {
  local user=$1
  local password=$2
  local is_admin=$3
  
  log "INFO" "Running tests for user '$user'..."
  
  # Test 1: Can connect to test database
  run_sql "$user" "$password" "test" "SELECT 1;" true "User $user can connect to test database"
  
  # Test 2: Can create table in test database
  run_sql "$user" "$password" "test" "CREATE TABLE test_table_$user (id serial primary key, name text);" $is_admin "User $user can create table in test database"
  
  # Test 3: If admin, can create user in test database
  if [ "$is_admin" = true ]; then
    run_sql "$user" "$password" "test" "CREATE ROLE test_role_$user;" $is_admin "User $user can create role in test database"
  fi
  
  # Test 4: Can see list of databases (should be limited for non-admin)
  result=$(PGPASSWORD="$password" psql -h "$PG_HOST" -p "$PG_PORT" -U "$user" -d "test" -t -c "SELECT datname FROM pg_database ORDER BY datname;" 2>/dev/null || echo "ERROR")
  if [ "$is_admin" = true ]; then
    if echo "$result" | grep -q "postgres"; then
      log "INFO" "✅ TEST PASSED: Admin user $user can see postgres database as expected"
    else
      log "ERROR" "❌ TEST FAILED: Admin user $user cannot see postgres database"
    fi
  else
    if echo "$result" | grep -q "postgres"; then
      log "ERROR" "❌ TEST FAILED: Non-admin user $user can see postgres database"
    else
      log "INFO" "✅ TEST PASSED: Non-admin user $user cannot see postgres database as expected"
    fi
  fi
  
  # Test 5: Can connect to demo database (should fail for both if proper isolation)
  if db_exists "demo"; then
    run_sql "$user" "$password" "demo" "SELECT 1;" false "User $user cannot access demo database"
    
    # Test 6: Can create table in demo database (should fail for both if proper isolation)
    run_sql "$user" "$password" "demo" "CREATE TABLE test_table_$user (id serial primary key, name text);" false "User $user cannot create table in demo database"
  else
    log "WARN" "Demo database does not exist, skipping demo access tests"
  fi
  
  # Test 7: Can connect to postgres database (should fail for non-admin, succeed for admin)
  run_sql "$user" "$password" "postgres" "SELECT 1;" $is_admin "User $user connecting to postgres database"
}

# Test demo database permissions specifically
test_demo_database() {
  if [ -z "$DEMO_DB_NAME" ] || [ -z "$DEMO_DB_USER" ] || [ -z "$DEMO_DB_PASSWORD" ]; then
    log "WARN" "Demo database credentials not fully defined in .env, skipping demo database tests"
    return 1
  fi

  log "INFO" "Testing demo database permissions..."
  
  # Test 1: Superuser connection to demo database
  run_sql "$PG_SUPERUSER" "$PG_PASSWORD" "$DEMO_DB_NAME" "SELECT 1;" true "Superuser can connect to demo database"
  
  # Test 2: Demo user connection to own database
  run_sql "$DEMO_DB_USER" "$DEMO_DB_PASSWORD" "$DEMO_DB_NAME" "SELECT 1;" true "Demo user can connect to its own database"
  
  # Test 3: Demo user can create tables in own database
  run_sql "$DEMO_DB_USER" "$DEMO_DB_PASSWORD" "$DEMO_DB_NAME" "CREATE TABLE IF NOT EXISTS demo_test_table (id serial primary key, name text);" true "Demo user can create tables in demo database"
  
  # Test 4: Demo user cannot connect to postgres database
  run_sql "$DEMO_DB_USER" "$DEMO_DB_PASSWORD" "postgres" "SELECT 1;" false "Demo user cannot connect to postgres database"
  
  # Test 5: Check proper isolation - create a test table in demo database
  run_sql "$DEMO_DB_USER" "$DEMO_DB_PASSWORD" "$DEMO_DB_NAME" "INSERT INTO demo_test_table (name) VALUES ('test_value');" true "Demo user can insert data into demo database"
  
  # Test 6: Check if demo user can see list of databases (should be limited)
  result=$(PGPASSWORD="$DEMO_DB_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$DEMO_DB_USER" -d "$DEMO_DB_NAME" -t -c "SELECT datname FROM pg_database ORDER BY datname;" 2>/dev/null || echo "ERROR")
  if echo "$result" | grep -q "postgres"; then
    log "ERROR" "❌ TEST FAILED: Demo user can see postgres database, which violates isolation"
  else
    log "INFO" "✅ TEST PASSED: Demo user cannot see postgres database as expected"
  fi
  
  log "INFO" "Demo database permission tests completed"
}

# Main execution function
main() {
  log "INFO" "Starting PostgreSQL permission validation tests"
  
  # Auto-detect connection parameters
  auto_detect_connection
  
  if [ $? -ne 0 ]; then
    exit 1
  fi
  
  log "INFO" "Using connection parameters: Host=$PG_HOST, Port=$PG_PORT, User=$PG_SUPERUSER"
  if [ "$USE_PGBOUNCER" = true ]; then
    log "INFO" "Connected through PgBouncer"
  else
    log "INFO" "Connected directly to PostgreSQL"
  fi
  
  # Test demo database if .env was loaded
  if [ "$ENV_LOADED" = true ]; then
    test_demo_database
  else
    # Only set up test environment if not using existing demo
    setup
    
    # Run tests for admin and regular users
    run_user_tests "testadmin" "testadmin" true
    run_user_tests "testuser" "testuser" false
    
    # Cleanup
    cleanup
  fi
  
  log "INFO" "All tests completed"
}

# Run the main function
main 