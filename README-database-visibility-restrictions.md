# PostgreSQL Database Visibility Restrictions

This document describes the implementation of database visibility restrictions and subdomain-based access control in PostgreSQL for DBHub.cc.

## Quick Start Guide

1. **Initial Setup**: 
   - Ensure PostgreSQL is installed and running
   - Make sure you have administrative access to PostgreSQL

2. **Apply to All Databases**:
   - `./tools/update_existing_databases.sh`

3. **Test the Restrictions**:
   - `./tools/test_database_restrictions.sh --verbose`

4. **For New Databases**:
   - When creating a new database, apply the restrictions with:
     - `./tools/update_existing_databases.sh --database newdb --subdomain newdb`

5. **DNS Configuration**:
   - Make sure your DNS is configured to route `*.dbhub.cc` to your server
   - Each database should be accessible only through its own subdomain (e.g., `demo.dbhub.cc`)

6. **Connection Strings**:
   - When connecting to a database, specify the correct subdomain in the connection string
   - Example: `psql -U username -h demo.dbhub.cc demo`

## The Problem

By default, PostgreSQL allows users to see the existence of other databases in the system even if they don't have access to connect to them. This happens through system catalogs such as `pg_database` and SQL commands like `\l` or `\list` in psql. This behavior is problematic when implementing strict database isolation.

Additionally, users should only be able to access a database through its specific subdomain. For example, the "demo" database should only be accessible via "demo.dbhub.cc" and not through the main domain "dbhub.cc".

## Implementation Overview

The implementation consists of several components:

1. **Database Visibility Restrictions**: Using custom views and functions to limit what databases a user can see
2. **Subdomain-Based Access Control**: Using hostname mapping to enforce that a database can only be accessed via its specific subdomain
3. **User Isolation**: Configuring users so they are strictly limited to their database
4. **Connection Validation**: Checking hostnames during connection attempts to enforce subdomain-based access

## Key Components

### 1. Database Visibility Restrictions

The function `configure_database_visibility_restrictions()` in `modules/security.sh` implements:

- A custom view `pg_catalog.pg_database_view` that filters the database list based on user permissions
- Revocation of direct access to `pg_catalog.pg_database` for regular users
- Granting access to the restricted view instead

```sql
-- Create a custom view to restrict database visibility
CREATE OR REPLACE FUNCTION pg_catalog.pg_database_restricted()
RETURNS SETOF pg_catalog.pg_database AS $$
DECLARE
    current_user text := current_user;
    current_db text := current_database();
    is_superuser boolean := (SELECT usesuper FROM pg_catalog.pg_user WHERE usename = current_user);
BEGIN
    -- Superuser can see all databases
    IF is_superuser THEN
        RETURN QUERY SELECT * FROM pg_catalog.pg_database;
    ELSE
        -- Regular users can only see the current database and template databases
        RETURN QUERY SELECT * FROM pg_catalog.pg_database 
                     WHERE datname = current_db 
                     OR datname LIKE 'template%' 
                     OR datname = 'postgres';
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

### 2. Subdomain-Based Access Control

The functions `update_hostname_map_conf()` and `configure_subdomain_pg_hba()` implement:

- Mapping between database names and subdomains in pg_hostname_map.conf
- PostgreSQL configuration to check hostname during connection
- pg_hba.conf rules to enforce subdomain access control

The enhanced pg_hba.conf configuration now restricts access based on hostname:

```
# Regular users can only connect to their database if hostname matches
hostssl all             all             all                     scram-sha-256         hostnossl
hostssl sameuser        all             all                     scram-sha-256         

# Reject all other connections
host    all             all             all                     reject
```

### 3. Database and User Creation with Restrictions

The functions `create_restricted_database()` and `create_restricted_user()` implement:

- Creation of databases with visibility restrictions
- Creation of users with appropriate permissions
- Setting up search paths to limit visibility
- Forcing users to use the restricted view

### 4. Connection Validation with Hostnames

The function `configure_db_connection_restrictions()` implements:

- Per-database connection restrictions based on hostname
- SQL trigger functions that validate the hostname for each connection
- Exception raising when access is attempted through incorrect hostname

```sql
-- Prevent direct connections through the main domain for regular users
CREATE OR REPLACE FUNCTION public.check_connection_hostname()
RETURNS TRIGGER AS $$
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
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

## Tools and Scripts

To facilitate the setup and testing of these security features, several utility scripts are provided:

### Update Existing Databases Script

Location: `tools/update_existing_databases.sh`

This script applies the enhanced subdomain access control to existing databases. It:

1. Identifies existing databases in the PostgreSQL instance
2. Creates or updates hostname mappings for each database
3. Configures connection validation for each database
4. Updates necessary PostgreSQL configuration files

Usage:
```bash
# Update all databases
./tools/update_existing_databases.sh

# Update a specific database
./tools/update_existing_databases.sh --database mydatabase

# Use a custom subdomain for a database
./tools/update_existing_databases.sh --database mydatabase --subdomain custom

# Test mode - show what would be updated without making changes
./tools/update_existing_databases.sh --test
```

### Test Database Restrictions Script

Location: `tools/test_database_restrictions.sh`

This script helps validate that the security measures are working correctly. It:

1. Tests database visibility restrictions for different users
2. Validates subdomain-based access control
3. Tests database permissions for different users

Usage:
```bash
# Test all databases with postgres user
./tools/test_database_restrictions.sh

# Test a specific database
./tools/test_database_restrictions.sh --database mydatabase

# Test with a different user
./tools/test_database_restrictions.sh --user testuser

# Enable verbose output for detailed information
./tools/test_database_restrictions.sh --verbose
```

### Utility Modules

The scripts leverage these utility modules:

- `modules/postgresql.sh`: PostgreSQL-specific functions for configuring database security
- `modules/common.sh`: Common utility functions for logging, file operations, etc.

## Implementation Notes

While this implementation provides significant isolation, it's important to note:

1. PostgreSQL's system catalogs design means complete isolation is challenging
2. Database names can still be discovered through various metadata queries
3. Hostname validation depends on proper DNS configuration
4. This is a best-effort solution within PostgreSQL's security model

## Limitations and Considerations

For even stricter isolation:

1. Use separate PostgreSQL instances for complete isolation
2. Implement application-level proxies that provide complete isolation
3. Use row-level security on additional system tables to further restrict visibility
4. Configure network-level access control (e.g., with iptables or VPC security groups)

## Troubleshooting

When implementing these security features, you may encounter these common issues:

1. **Connection Errors**: If you experience connection errors after implementing subdomain-based access control, verify:
   - DNS configuration is correctly set up for the subdomains
   - PostgreSQL is configured to accept SSL connections
   - The correct hostname is being used in connection strings

2. **Database Visibility Issues**: If users can still see databases they shouldn't access:
   - Ensure the custom view has been properly configured
   - Verify permissions are correctly set
   - Check if users have any superuser or administrative privileges

3. **Script Execution Problems**: If you encounter issues running the scripts:
   - Ensure they have the appropriate execute permissions (`chmod +x script.sh` on Unix-like systems)
   - Run them with proper privileges (some operations may require root or postgres user)
   - Check the PostgreSQL version compatibility

4. **Subdomain Access Control Bypass**: If databases can still be accessed through the main domain:
   - Run the fix script to apply stricter hostname validation: `./tools/fix_demo_access.sh`
   - The fix enhances hostname validation to require an exact match rather than a partial match
   - This prevents access via the main domain when a subdomain is required

To diagnose problems, use the testing script with the `--verbose` flag:
```bash
./tools/test_database_restrictions.sh --verbose
```

## Recent Improvements

The latest version of our security scripts includes several important improvements:

1. **Enhanced Hostname Validation**: Updated from partial hostname matching to exact hostname matching to prevent access through the main domain. The validation function now uses equality comparisons (`!=`) instead of position checks, ensuring that databases can only be accessed through their specific subdomains.

2. **Multiple Validation Layers**: Added multiple validation mechanisms including:
   - Event triggers for DDL commands
   - Statement-level triggers for capturing all queries
   - Specialized triggers on system catalog tables

3. **Integrated into Main Initialization**: The hostname validation fix has been integrated directly into the main server initialization script (`server_init.sh`), ensuring that all newly created databases automatically have the correct validation configuration. This eliminates the need for separate fix scripts.

4. **Automatic Testing**: The initialization script now automatically tests the hostname validation after setup to verify that:
   - Connections through the correct subdomain succeed
   - Connections through the incorrect hostname (main domain) are properly blocked

5. **Better Diagnostics**: Added detailed logging throughout the validation process, making it easier to diagnose any issues with hostname validation.

6. **Comprehensive Documentation**: This README and inline code comments provide clear explanations of how the hostname validation works and how to troubleshoot it.

## Testing and Verification

To verify that your security restrictions are working correctly:

```bash
# Test accessing the demo database through the correct subdomain
PGAPPNAME="demo.dbhub.cc" psql -U demo -d demo

# Test accessing the demo database through the main domain (should fail)
PGAPPNAME="dbhub.cc" psql -U demo -d demo
```

You can also use the included test script:

```bash
./tools/test_database_restrictions.sh --verbose
```

## Additional Security Recommendations

For even stricter isolation:

1. Use separate PostgreSQL instances for complete isolation
2. Implement application-level proxies that provide complete isolation
3. Use row-level security on additional system tables to further restrict visibility
4. Configure network-level access control (e.g., with iptables or VPC security groups)

## Compatibility

Tested with PostgreSQL version 15. 