# Modules Directory

This directory contains modular Bash scripts that are sourced by the main `server_init.sh` script to provide organized and reusable functionality. Each module focuses on a specific aspect of the PostgreSQL and PgBouncer setup and configuration.

## Module Descriptions

### common.sh

This module provides shared utility functions used across all other modules. It forms the foundation of the entire framework.

**Key functions:**
- `log()` - Standardized logging function for consistent output
- `error_handler()` - Central error handling for proper script termination
- `generate_password()` - Creates secure random passwords
- `command_exists()` - Checks if a command is available
- `package_installed()` - Verifies if a package is installed
- `install_package()` - Installs packages if not already present
- `backup_file()` - Creates backups of configuration files
- `setup_environment()` - Loads and verifies environment variables

This module ensures consistent behavior across all other modules and provides helper functions that simplify common tasks.

### postgresql.sh

This module handles the installation, configuration, and management of PostgreSQL databases.

**Key functions:**
- `install_postgresql()` - Adds PostgreSQL repositories and installs the specified version
- `configure_postgresql()` - Sets up PostgreSQL configuration files with security and performance optimizations
- `optimize_postgresql()` - Tunes PostgreSQL parameters based on server resources
- `setup_database_permissions()` - Configures secure database access permissions
- `fix_postgresql_cluster()` - Diagnoses and repairs PostgreSQL cluster issues
- `setup_replica()` - Configures PostgreSQL replication (if enabled)

This module ensures PostgreSQL is properly installed with secure defaults and optimized for performance based on server resources.

### pgbouncer.sh

This module handles PgBouncer connection pooling setup and configuration.

**Key functions:**
- `install_pgbouncer()` - Installs the PgBouncer connection pooler
- `configure_pgbouncer()` - Creates PgBouncer configuration with optimal settings
- `update_pgbouncer_users()` - Synchronizes PostgreSQL users with PgBouncer
- `setup_pgbouncer_auth()` - Configures authentication for PgBouncer
- `restart_pgbouncer()` - Safely restarts PgBouncer service

PgBouncer provides connection pooling for PostgreSQL, which improves performance by reducing the overhead of establishing new database connections.

### security.sh

This module implements security best practices for the PostgreSQL server.

**Key functions:**
- `setup_security()` - Main function that calls all security-related setup
- `configure_firewall()` - Sets up UFW firewall rules to protect the server
- `configure_fail2ban()` - Configures fail2ban to prevent brute force attacks
- `setup_ssl_certificates()` - Generates or configures SSL certificates for encrypted connections
- `secure_postgresql()` - Applies PostgreSQL-specific security settings
- `revoke_public_permissions()` - Removes insecure default PUBLIC permissions

This module ensures the database server is protected according to security best practices, minimizing potential attack vectors.

### monitoring.sh

This module sets up comprehensive monitoring for the PostgreSQL server and related services.

**Key functions:**
- `setup_monitoring()` - Main function that calls all monitoring-related setup
- `copy_monitoring_scripts()` - Deploys monitoring scripts to appropriate locations
- `install_monitoring_tools()` - Installs Prometheus, Grafana, and related exporters
- `setup_monitoring_services()` - Configures systemd services for monitoring tools
- `send_test_email()` - Verifies email alerting functionality
- `setup_dashboards()` - Configures pre-built Grafana dashboards

This module ensures that the server's health and performance are continuously monitored, with alerts for potential issues.

### subdomain.sh

This module implements database-to-subdomain mapping for easy access to PostgreSQL databases.

**Key functions:**
- `setup_subdomain_routing()` - Main function for subdomain configuration
- `setup_nginx_template()` - Creates Nginx configuration templates
- `copy_subdomain_script()` - Installs the subdomain management script
- `setup_automatic_subdomain_creation()` - Configures PostgreSQL triggers for automatic subdomain creation
- `create_subdomain_for_database()` - Maps a specific database to a subdomain
- `create_subdomains_for_all_databases()` - Maps all existing databases to subdomains

This module enables accessing different PostgreSQL databases through different subdomains, with automatic routing and configuration.

## Module Execution Order

When the main `server_init.sh` script runs, it sources these modules in a specific order to ensure proper dependency resolution:

1. `common.sh` - Always loaded first to provide utility functions
2. `postgresql.sh` - Installs and configures the core PostgreSQL database
3. `pgbouncer.sh` - Sets up connection pooling
4. `security.sh` - Applies security measures
5. `monitoring.sh` - Configures monitoring and alerting
6. `subdomain.sh` - Sets up subdomain routing (if enabled)

## How to Use These Modules

These modules are primarily designed to be sourced by the main `server_init.sh` script, but advanced users can also source individual modules for specific tasks:

```bash
# Example: Source common and PostgreSQL modules for database-specific operations
source modules/common.sh
source modules/postgresql.sh

# Then call specific functions
install_postgresql
configure_postgresql
```

## Module Dependencies

- `common.sh` - No dependencies
- `postgresql.sh` - Depends on `common.sh`
- `pgbouncer.sh` - Depends on `common.sh` and `postgresql.sh`
- `security.sh` - Depends on `common.sh`
- `monitoring.sh` - Depends on `common.sh`
- `subdomain.sh` - Depends on `common.sh`

## Extending Modules

To add functionality to a module:

1. Add your function to the appropriate module file
2. Follow the existing function naming and logging conventions
3. Use the `log()` function for consistent output
4. Handle errors properly using the provided error handling

To create a new module:

1. Create a new file following the naming pattern `modulename.sh`
2. Start with the standard module header and include utility functions
3. Implement your functionality with proper error handling
4. Source your new module in the main `server_init.sh` script

## Troubleshooting Module Issues

If you encounter issues with a specific module:

1. Check the logs at `/var/log/dbhub_setup.log` for detailed error messages
2. Verify that all dependencies for the module are correctly installed
3. Ensure that the environment variables required by the module are set correctly
4. Try running individual functions from the module to isolate the issue

For more complex issues, refer to the full documentation or submit an issue on the GitHub repository. 