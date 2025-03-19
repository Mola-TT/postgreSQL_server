# PostgreSQL Database Visibility Restrictions

This document explains the implementation of PostgreSQL database visibility restrictions for DBHub.cc, according to the requirements in `002.postgresql_server_rules.mdc`.

## The Problem

By default, PostgreSQL allows users to see the existence of other databases in the system even if they don't have access to connect to them. This happens through system catalogs such as `pg_database` and SQL commands like `\l` or `\list` in psql. This behavior is problematic when implementing strict database isolation.

## Implementation Overview

The implementation consists of several components:

1. **Database Visibility Restrictions**: Using custom views and functions to limit what databases a user can see
2. **Subdomain-Based Access Control**: Using hostname mapping to enforce that a database can only be accessed via its specific subdomain
3. **User Isolation**: Configuring users so they are strictly limited to their database

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

The functions `update_pg_hostname_map()` and `configure_subdomain_pg_hba()` implement:

- Mapping between database names and subdomains
- PostgreSQL configuration to check hostname during connection
- pg_hba.conf rules to enforce subdomain access control

### 3. Database and User Creation with Restrictions

The functions `create_restricted_database()` and `create_restricted_user()` implement:

- Creation of databases with visibility restrictions
- Creation of users with appropriate permissions
- Setting up search paths to limit visibility
- Forcing users to use the restricted view

## Usage

### Creating a Database with Visibility Restrictions

```bash
# Create a new database with restricted visibility
create_restricted_database "demo" "password" "demo"
```

### Creating a User with Restricted Access

```bash
# Create a read-only user with restricted visibility
create_restricted_user "demo" "user1" "password" "true"
```

## Limitations

While this implementation provides significant isolation, it's important to note:

1. PostgreSQL's system catalogs design means complete isolation is challenging
2. Database names can still be discovered through various metadata queries
3. This is a best-effort solution within PostgreSQL's security model

## Further Improvements

For even stricter isolation:

1. Use separate PostgreSQL instances for complete isolation
2. Implement application-level proxies that provide complete isolation
3. Use row-level security on additional system tables to further restrict visibility

## Compatibility

Tested with PostgreSQL version 15. 