#!/bin/bash

# Database Permission Validation Script
# This script tests various permission scenarios to verify proper database isolation.

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

# Function to run SQL and capture result
run_sql() {
  local user=$1
  local password=$2
  local database=$3
  local sql=$4
  local expected_success=$5
  local description=$6
  
  result=$(PGPASSWORD="$password" psql -h localhost -U "$user" -d "$database" -t -c "$sql" 2>&1 || true)
  
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
  PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -t -c "SELECT 1 FROM pg_roles WHERE rolname='$role'" | grep -q 1
  return $?
}

# Function to check if a specific database exists
db_exists() {
  local db=$1
  PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1
  return $?
}

# Cleanup existing test database and users if they exist
cleanup() {
  log "INFO" "Cleaning up existing test environment..."
  
  # Connect as postgres to perform cleanup
  if db_exists "test"; then
    log "INFO" "Terminating all connections to the test database"
    PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='test' AND pid <> pg_backend_pid();" > /dev/null 2>&1 || true
    
    log "INFO" "Dropping test database"
    PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -c "DROP DATABASE IF EXISTS test;" > /dev/null 2>&1 || true
  fi
  
  # Drop test users if they exist
  for user in "testadmin" "testuser"; do
    if role_exists "$user"; then
      log "INFO" "Dropping role $user"
      PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -c "DROP OWNED BY $user CASCADE;" > /dev/null 2>&1 || true
      PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -c "DROP ROLE $user;" > /dev/null 2>&1 || true
    fi
  done
}

# Set up test environment
setup() {
  log "INFO" "Setting up test environment..."
  
  # Create test database owned by postgres initially
  PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -c "CREATE DATABASE test;" > /dev/null 2>&1
  
  # Create test admin user
  PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -c "CREATE USER testadmin WITH PASSWORD 'testadmin';" > /dev/null 2>&1
  
  # Create regular test user
  PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -c "CREATE USER testuser WITH PASSWORD 'testuser';" > /dev/null 2>&1
  
  # Grant admin privileges to testadmin for test database
  PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -c "ALTER DATABASE test OWNER TO testadmin;" > /dev/null 2>&1
  
  # Connect to test database and set up permissions
  PGPASSWORD="postgres" psql -h localhost -U postgres -d test -c "GRANT CONNECT ON DATABASE test TO testuser;" > /dev/null 2>&1
  PGPASSWORD="postgres" psql -h localhost -U postgres -d test -c "GRANT USAGE ON SCHEMA public TO testuser;" > /dev/null 2>&1
  PGPASSWORD="postgres" psql -h localhost -U postgres -d test -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO testuser;" > /dev/null 2>&1
  PGPASSWORD="postgres" psql -h localhost -U postgres -d test -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO testuser;" > /dev/null 2>&1
  
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
  result=$(PGPASSWORD="$password" psql -h localhost -U "$user" -d "test" -t -c "SELECT datname FROM pg_database ORDER BY datname;" 2>/dev/null || echo "ERROR")
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
  log "INFO" "Starting permission validation tests"
  
  # Check PostgreSQL is running
  if ! PGPASSWORD="postgres" psql -h localhost -U postgres -d postgres -c "SELECT 1;" &>/dev/null; then
    log "ERROR" "PostgreSQL is not running or postgres user cannot connect. Please check your setup."
    exit 1
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
  
  # Optional: Cleanup after tests
  read -p "Do you want to clean up the test environment? (y/n): " cleanup_choice
  if [[ "$cleanup_choice" == "y" || "$cleanup_choice" == "Y" ]]; then
    cleanup
    log "INFO" "Test environment cleaned up"
  else
    log "INFO" "Test environment preserved for manual inspection"
  fi
}

# Run the main function
main 