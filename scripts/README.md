# Scripts Directory

This directory contains standalone Bash scripts that provide various functionalities for managing PostgreSQL servers and related services. These scripts can be executed directly or called by the main installation script.

## Script Descriptions

### server_monitor.sh

A comprehensive monitoring script for PostgreSQL servers that continuously checks system health and sends alerts when predefined thresholds are exceeded.

**Key features:**
- Monitors CPU, memory, and disk usage against configurable thresholds
- Checks PostgreSQL and PgBouncer service status
- Monitors PostgreSQL connection count and compares against maximum connections
- Tracks database sizes and their growth over time
- Identifies slow queries that may impact performance
- Detects and reports database locks that could cause problems
- Monitors for failed login attempts and potential security issues
- Sends email alerts when thresholds are exceeded or problems are detected

This script is typically installed as a cron job to run at regular intervals (e.g., every 15 minutes) to ensure continuous monitoring of the database server.

### backup_postgres.sh

An automated backup solution for PostgreSQL databases that handles creation, compression, and rotation of backups.

**Key features:**
- Creates full database dumps of all databases or specific ones
- Includes schema and data in the backups
- Compresses backups to save disk space
- Implements backup rotation based on configurable retention periods
- Sends email notifications on backup completion or failure
- Logs all backup operations for audit purposes
- Verifies backup integrity after creation

When installed as part of the main system, this script is scheduled to run daily to ensure regular backups of your database data.

### restore_postgres.sh

A companion script to backup_postgres.sh that facilitates database restoration from previously created backups.

**Key features:**
- Lists available backups with timestamps
- Shows databases contained in each backup
- Restores entire backup sets or individual databases
- Supports restoring to a different database name for testing
- Handles global objects (roles, tablespaces) restoration
- Validates backup files before attempting restoration
- Provides detailed logging of restoration process

This script is essential for disaster recovery scenarios and for migrating databases between servers.

### db_user_manager.sh

A database user management utility that helps create and manage PostgreSQL users with appropriate security restrictions.

**Key features:**
- Creates database users with access limited to specific databases
- Enforces secure password policies
- Revokes dangerous default permissions
- Lists existing databases and users
- Creates new databases with proper ownership
- Modifies user permissions and attributes
- Deletes users and their owned objects safely
- Automatically updates PgBouncer user authentication in real-time
- Provides password update functionality with immediate PgBouncer sync
- Includes a manual sync command to force synchronization of all users
- Reloads PgBouncer configuration without service disruption

This script follows security best practices by limiting user privileges to only what's necessary, helping maintain the principle of least privilege. It also solves the login delay issue by updating PgBouncer's authentication immediately when users are created, modified, or deleted.

**Usage Examples:**
```bash
# Create a new user with access to a specific database
sudo ./db_user_manager.sh create-user mydb myuser mypassword

# Update a user's password
sudo ./db_user_manager.sh update-password myuser newpassword

# Delete a user (removes from both PostgreSQL and PgBouncer)
sudo ./db_user_manager.sh delete-user myuser

# Manually synchronize all PostgreSQL users with PgBouncer
sudo ./db_user_manager.sh sync-pgbouncer
```

### update_pgbouncer_users.sh

A utility script that synchronizes PostgreSQL users with PgBouncer's authentication file, ensuring connection pooling works for all database users.

**Key features:**
- Automatically extracts user information from PostgreSQL
- Updates PgBouncer's userlist.txt with current password hashes
- Maintains admin users configuration
- Handles different authentication methods
- Reloads PgBouncer configuration without service disruption
- Logs all changes for auditing purposes
- Supports individual user updates (add, update, delete)
- Integrates with db_user_manager.sh for real-time updates
- Includes command-line arguments for flexible usage
- Provides quiet mode for automated/scripted usage
- Detects and fixes formatting issues in userlist file automatically
- Properly handles whitespace in password hashes to prevent broken authentication

This script is typically scheduled to run daily to ensure PgBouncer's user list stays in sync with PostgreSQL. It can also be called on-demand for individual user updates by the db_user_manager.sh script.

**Usage Examples:**
```bash
# Update all PostgreSQL users in PgBouncer
sudo ./update_pgbouncer_users.sh

# Update a single user
sudo ./update_pgbouncer_users.sh -u myuser -a add

# Delete a user from PgBouncer
sudo ./update_pgbouncer_users.sh -u myuser -a delete

# Update all users but skip reloading PgBouncer
sudo ./update_pgbouncer_users.sh -s

# Quiet mode for scripted usage
sudo ./update_pgbouncer_users.sh -q -u myuser -a update

# Fix formatting issues in userlist.txt without updating users
sudo ./update_pgbouncer_users.sh -f
```

### pg_auto_scale.sh

An intelligent PostgreSQL configuration optimizer that automatically tunes database settings based on available server resources.

**Key features:**
- Detects server CPU, memory, and disk specifications
- Calculates optimal PostgreSQL configuration parameters
- Adjusts shared buffers, work memory, and connection settings
- Optimizes WAL (Write-Ahead Log) configurations
- Tunes background writer parameters
- Updates effective_io_concurrency based on storage type
- Creates backup of current configuration before making changes
- Applies changes and validates them

This script helps achieve better PostgreSQL performance by tailoring configuration to your specific hardware capabilities.

### secure_permissions.sh

A security hardening script that enforces proper file and directory permissions for PostgreSQL and PgBouncer installations.

**Key features:**
- Sets correct ownership for PostgreSQL data directories
- Restricts permissions on configuration files
- Secures SSL certificates and key files
- Protects password files
- Ensures proper permissions for log directories
- Secures backup locations
- Verifies and corrects script executable permissions
- Generates detailed permission audit report

Running this script helps maintain a secure PostgreSQL installation by preventing unauthorized access to sensitive files and directories.

### create_db_subdomain.sh

A utility that creates and manages Nginx configurations for database subdomains, enabling easy access to different databases through unique URLs.

**Key features:**
- Maps PostgreSQL databases to subdomains automatically
- Creates Nginx server blocks for each database
- Configures SSL/TLS for secure connections
- Sets up proxy settings for database routing
- Manages automatic creation of subdomains for new databases
- Removes configurations for deleted databases
- Supports Let's Encrypt certificate integration
- Creates DNS configuration guidelines

This script enables accessing databases through URLs like `dbname.yourdomain.com` with automatic routing to the correct database.

## Integrated Features

The following functionality is directly integrated into the main `server_init.sh` script:

### SSL Support for PgBouncer

The main installation script automatically configures SSL support for PgBouncer, including:
- Creating self-signed SSL certificates if they don't exist
- Setting proper permissions for SSL certificates
- Configuring PgBouncer to use SSL
- Setting client_tls_sslmode to allow both SSL and non-SSL connections

### PgBouncer Parameter Handling

The main installation script automatically configures PgBouncer to handle unsupported PostgreSQL parameters:
- Adds `ignore_startup_parameters = extra_float_digits` to PgBouncer configuration
- Fixes the "FATAL: unsupported startup parameter: extra_float_digits" error
- Properly sets file permissions after configuration

### PgBouncer Authentication

The main installation script configures PgBouncer to use SCRAM-SHA-256 authentication, which:
- Matches the PostgreSQL authentication method
- Uses properly formatted SCRAM password hashes in userlist.txt
- Automatically adds all database users to PgBouncer with correct auth
- Implements auth_query for proper SASL authentication
- Prevents "FATAL: password authentication failed" and "FATAL: SASL authentication failed" errors

The script also handles upgrading existing installations:
- Detects when an existing PgBouncer installation uses MD5 authentication
- Creates backups of all configuration files before making changes
- Automatically converts existing user password hashes to SCRAM-SHA-256 format
- Properly restarts PgBouncer to apply changes

All these features are integrated directly into the `configure_pgbouncer()` function in the main script, eliminating the need for separate fix scripts.

## Using These Scripts

Most scripts accept command-line arguments to control their behavior. For detailed usage instructions, run each script with the `--help` or `-h` flag:

```bash
./script_name.sh --help
```

The scripts can be executed directly from the command line:

```bash
# Example: Creating a database user
sudo ./db_user_manager.sh create-user mydb myuser mypassword

# Example: Backing up all databases
sudo ./backup_postgres.sh

# Example: Restoring a database
sudo ./restore_postgres.sh restore-db latest mydb
```

When installed via the main server_init.sh script, these scripts are copied to a system location (typically /usr/local/bin) and can be executed from anywhere.

## Script Dependencies

Most scripts rely on:
- Properly installed PostgreSQL server
- PgBouncer for connection pooling scripts
- Environment variables typically loaded from a .env file
- Required system utilities (mail, ufw, etc.)

The main server_init.sh installation script ensures all dependencies are properly installed and configured.

## Troubleshooting

If you encounter issues with any script:

1. Check the script-specific log file in `/var/log/dbhub/` or as specified in the script
2. Verify that all required environment variables are set correctly
3. Ensure that you're running the script with sufficient privileges (usually as root or with sudo)
4. Check that PostgreSQL and related services are running properly

### PgBouncer Authentication Issues

If you encounter PgBouncer authentication errors:

1. **PostgreSQL pg_hba.conf configuration**:
   - Ensure the postgres user is configured to use scram-sha-256 authentication:
     ```bash
     grep postgres /etc/postgresql/*/main/pg_hba.conf
     ```
   - If it shows "peer" instead of "scram-sha-256", modify it:
     ```bash
     sed -i 's/local\s\+all\s\+postgres\s\+peer/local all postgres scram-sha-256/' /etc/postgresql/*/main/pg_hba.conf
     systemctl restart postgresql
     ```

2. **PgBouncer userlist format**:
   - Fix formatting issues in the userlist file:
     ```bash
     pgbouncer-users -f
     ```

3. **Reset user passwords**:
   - Update a user's password in both PostgreSQL and PgBouncer:
     ```bash
     db-user update-password username newpassword
     ```

For detailed debugging, increase verbosity by setting the `DEBUG=true` environment variable before running most scripts:

```bash
DEBUG=true ./script_name.sh
```

## Extending Scripts

To modify or extend these scripts:

1. Follow the established patterns for logging and error handling
2. Always create backups of configuration files before modifying them
3. Test changes in a non-production environment first
4. Update command-line help and documentation to reflect changes
5. Ensure any new functionalities are properly logged

For significant enhancements, consider creating a new script that can be integrated into the existing framework. 