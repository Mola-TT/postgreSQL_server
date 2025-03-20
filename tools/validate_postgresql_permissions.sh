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

# Default connection parameters - will be auto-detected
PG_HOST="localhost"
PG_PORT="5432"
PG_SUPERUSER="postgres"
PG_PASSWORD="postgres"
USE_PGBOUNCER=false
PGBOUNCER_PORT="6432"

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
  
  # Try different password options for postgres
  for pw in "postgres" "$PG_PASSWORD"; do
    # First, try connecting to PostgreSQL directly
    if test_connection "$PG_HOST" "5432" "$PG_SUPERUSER" "$pw" "postgres"; then
      PG_PORT="5432"
      PG_PASSWORD="$pw"
      USE_PGBOUNCER=false
      log "INFO" "✅ Successfully connected to PostgreSQL on port 5432"
      return 0
    fi
    
    # If direct connection failed, try PgBouncer
    if test_connection "$PG_HOST" "6432" "$PG_SUPERUSER" "$pw" "postgres"; then
      PG_PORT="6432"
      PG_PASSWORD="$pw"
      USE_PGBOUNCER=true
      log "INFO" "✅ Successfully connected to PgBouncer on port 6432"
      return 0
    fi
  done
  
  # Try to read password from environment variable if set
  if [ -n "$PGPASSWORD" ]; then
    if test_connection "$PG_HOST" "5432" "$PG_SUPERUSER" "$PGPASSWORD" "postgres"; then
      PG_PORT="5432"
      PG_PASSWORD="$PGPASSWORD"
      USE_PGBOUNCER=false
      log "INFO" "✅ Successfully connected to PostgreSQL on port 5432 using PGPASSWORD environment variable"
      return 0
    fi
    
    if test_connection "$PG_HOST" "6432" "$PG_SUPERUSER" "$PGPASSWORD" "postgres"; then
      PG_PORT="6432"
      PG_PASSWORD="$PGPASSWORD"
      USE_PGBOUNCER=true
      log "INFO" "✅ Successfully connected to PgBouncer on port 6432 using PGPASSWORD environment variable"
      return 0
    fi
  fi
  
  # Try to read password from .pgpass file
  if [ -f ~/.pgpass ]; then
    log "INFO" "Found .pgpass file, attempting to use credentials"
    
    # Try PostgreSQL direct
    if PGPASSWORD="" psql -h "$PG_HOST" -p "5432" -U "$PG_SUPERUSER" -d "postgres" -c "SELECT 1;" &>/dev/null; then
      PG_PORT="5432"
      USE_PGBOUNCER=false
      log "INFO" "✅ Successfully connected to PostgreSQL on port 5432 using .pgpass credentials"
      return 0
    fi
    
    # Try PgBouncer
    if PGPASSWORD="" psql -h "$PG_HOST" -p "6432" -U "$PG_SUPERUSER" -d "postgres" -c "SELECT 1;" &>/dev/null; then
      PG_PORT="6432"
      USE_PGBOUNCER=true
      log "INFO" "✅ Successfully connected to PgBouncer on port 6432 using .pgpass credentials"
      return 0
    fi
  fi
  
  # No connection methods worked
  log "ERROR" "❌ Could not connect to PostgreSQL or PgBouncer using any of the attempted methods"
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

# Main function
main() {
  log "INFO" "Starting PostgreSQL permission validation tests"
  
  # Auto-detect connection parameters
  if ! auto_detect_connection; then
    log "ERROR" "Could not connect to PostgreSQL. Please check that the server is running."
    log "ERROR" "If PostgreSQL is running, try setting PGPASSWORD environment variable."
    log "ERROR" "Example: PGPASSWORD=mypassword ./$(basename $0)"
    exit 1
  fi
  
  log "INFO" "Using the following connection parameters:"
  log "INFO" "  Host: $PG_HOST"
  log "INFO" "  Port: $PG_PORT"
  log "INFO" "  User: $PG_SUPERUSER"
  if [ "$USE_PGBOUNCER" = true ]; then
    log "INFO" "  Connection via: PgBouncer"
  else
    log "INFO" "  Connection via: Direct PostgreSQL"
  fi
  
  # Cleanup and setup
  cleanup
  setup
  
  # Run tests for both users
  log "INFO" "===== Testing testadmin user (Should have admin rights) ====="
  run_user_tests "testadmin" "testadmin" true
  
  log "INFO" "===== Testing testuser user (Should have limited rights) ====="
  run_user_tests "testuser" "testuser" false
  
  # Summary
  log "INFO" "===== Test Summary ====="
  log "INFO" "✓ Test database created with testadmin as owner"
  log "INFO" "✓ testuser created with limited permissions"
  log "INFO" "✓ All permission tests completed"
  
  # Automatic cleanup to avoid manual input
  log "INFO" "Cleaning up test environment"
  cleanup
  log "INFO" "Test environment cleaned up"
}

# Run the main function
main 