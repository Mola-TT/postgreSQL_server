# DBHub.cc - PostgreSQL Server Management Scripts

A collection of scripts for setting up and managing PostgreSQL servers with PgBouncer for connection pooling, enhanced security, and monitoring capabilities.

## Overview

This project provides a comprehensive set of scripts for:

- Installing and configuring PostgreSQL and PgBouncer
- Managing database users with proper security restrictions
- Backing up and restoring PostgreSQL databases
- Monitoring server resources and PostgreSQL performance
- Updating PgBouncer user lists from PostgreSQL

## Scripts

### Main Scripts

- `server_init.sh` - Main server initialization script that installs and configures PostgreSQL and PgBouncer
- `scripts/server_monitor.sh` - Monitors system resources and PostgreSQL/PgBouncer services
- `scripts/backup_postgres.sh` - Creates backups of PostgreSQL databases with rotation
- `scripts/restore_postgres.sh` - Restores PostgreSQL databases from backups
- `scripts/db_user_manager.sh` - Creates and manages restricted PostgreSQL users
- `scripts/update_pgbouncer_users.sh` - Updates PgBouncer user list from PostgreSQL

## Requirements

- Ubuntu Server (tested on 20.04 LTS and 22.04 LTS)
- Root or sudo access
- Internet connection for package installation

## Installation

1. Clone this repository:
   ```
   git clone https://github.com/yourusername/dbhub.cc.git
   cd dbhub.cc
   ```

2. Run the server initialization script:
   ```
   sudo ./server_init.sh install
   ```

   Note: The script automatically makes all modules and scripts executable, so you no longer need to manually run `chmod +x` commands before running the script.

## Configuration

The server initialization script creates a configuration file at `/etc/dbhub/.env` with default settings. You can modify this file to customize your installation.

Key configuration options:

- `PG_VERSION` - PostgreSQL version to install
- `ENABLE_REMOTE_ACCESS` - Whether to allow remote connections to PostgreSQL
- `EMAIL_*` - Email settings for alerts
- `DOMAIN_SUFFIX` - Domain suffix for server

## Usage

### Managing Database Users

Create a restricted user with access to a specific database:

```
sudo ./scripts/db_user_manager.sh create-user mydb myuser mypassword
```

List all databases:

```
sudo ./scripts/db_user_manager.sh list-dbs
```

List all users:

```
sudo ./scripts/db_user_manager.sh list-users
```

Create a new database:

```
sudo ./scripts/db_user_manager.sh create-db mydb [owner]
```

Delete a user:

```
sudo ./scripts/db_user_manager.sh delete-user myuser
```

### Backing Up Databases

The backup script is automatically scheduled to run daily at 2 AM. You can also run it manually:

```
sudo ./scripts/backup_postgres.sh
```

Backups are stored in `/var/backups/postgresql` with a timestamp directory for each backup run.

### Restoring Databases

List available backups:

```
sudo ./scripts/restore_postgres.sh list-backups
```

List databases in a backup:

```
sudo ./scripts/restore_postgres.sh list-databases latest
```

Restore a database:

```
sudo ./scripts/restore_postgres.sh restore-db latest mydb
```

Restore a database to a new name:

```
sudo ./scripts/restore_postgres.sh restore-db latest mydb mydb_restored
```

Restore global objects (roles, tablespaces):

```
sudo ./scripts/restore_postgres.sh restore-globals latest
```

### Monitoring

The server monitoring script is automatically scheduled to run every 15 minutes. You can also run it manually:

```
sudo ./scripts/server_monitor.sh
```

The script checks:
- CPU, memory, and disk usage
- PostgreSQL and PgBouncer service status
- PostgreSQL connection count
- Database sizes
- Slow queries
- Database locks
- Failed login attempts

Alerts are sent via email if thresholds are exceeded.

### Updating PgBouncer Users

The PgBouncer user update script is automatically scheduled to run daily at 3 AM. You can also run it manually:

```
sudo ./scripts/update_pgbouncer_users.sh
```

## Security Features

- Restricted database users with minimal privileges
- Firewall configuration with UFW
- fail2ban integration for brute force protection
- Secure password storage
- Proper file permissions

## Logs

All scripts log their activities to files in `/var/log/dbhub/`:

- `server_init.log` - Server initialization log
- `server_monitor.log` - Monitoring log
- `backup.log` - Backup log
- `restore.log` - Restore log
- `db_user_manager.log` - User management log
- `pgbouncer_update.log` - PgBouncer user update log

## Troubleshooting

If you encounter issues:

1. Check the log files in `/var/log/dbhub/`
2. Verify PostgreSQL is running: `systemctl status postgresql`
3. Verify PgBouncer is running: `systemctl status pgbouncer`
4. Check PostgreSQL logs: `tail -f /var/log/postgresql/postgresql-*-main.log`
5. Check PgBouncer logs: `tail -f /var/log/postgresql/pgbouncer.log`

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Key Features

- **PostgreSQL Installation**: Automated installation and configuration of PostgreSQL
- **PgBouncer Setup**: Connection pooling with PgBouncer for improved performance
- **Security Hardening**: Secure configurations for PostgreSQL and PgBouncer
  - SCRAM-SHA-256 authentication for both PostgreSQL and PgBouncer
  - Proper pg_hba.conf configuration for PgBouncer compatibility
  - Automatic detection and fixing of userlist formatting issues
- **User Management**: Scripts for managing database users with proper permissions
- **Monitoring**: System and database monitoring with email alerts
- **Backup and Restore**: Tools for backing up and restoring databases
- **Auto-scaling**: Automatic optimization of PostgreSQL settings based on server resources