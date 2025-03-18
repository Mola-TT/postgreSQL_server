# DBHub.cc Server Setup - Usage Guide

This guide explains how to use the DBHub.cc server setup scripts to create and manage your PostgreSQL server with advanced features.

## Quick Start

1. **Clone the repository**:
   ```bash
   git clone https://github.com/yourusername/dbhub.cc.git
   cd dbhub.cc
   ```

2. **Configure your environment**:
   ```bash
   cp .env.example .env
   nano .env  # Edit with your settings
   ```

3. **Run the installation script**:
   ```bash
   sudo ./server_init.sh install
   ```

   Note: The installation script automatically makes all modules and scripts executable, so you no longer need to manually run `chmod +x` commands before running the script.

## Configuration Options

Edit the `.env` file to customize your installation:

| Variable | Description | Default |
|----------|-------------|---------|
| `PG_VERSION` | PostgreSQL version to install | 17 |
| `PG_PASSWORD` | PostgreSQL admin password | (random) |
| `DOMAIN_SUFFIX` | Domain for subdomain routing | example.com |
| `ENABLE_REMOTE_ACCESS` | Allow remote connections | false |
| `EMAIL_RECIPIENT` | Email for alerts | (empty) |
| `INSTALL_MONITORING` | Install monitoring tools | false |
| `USE_LETSENCRYPT` | Use Let's Encrypt for SSL | false |

## Managing Databases and Users

### Creating a Database with Restricted User

```bash
sudo /usr/local/bin/db_user_manager.sh create-user mydb myuser mypassword
```

This creates:
- A database named `mydb`
- A user named `myuser` with password `mypassword`
- Proper permissions for the user on the database
- Revoked public privileges for security

### Creating a Subdomain for a Database

```bash
sudo /usr/local/bin/create_db_subdomain.sh create mydb
```

This creates a subdomain configuration that maps `mydb.yourdomain.com` to the `mydb` database.

### Creating Subdomains for All Databases

```bash
sudo /usr/local/bin/create_db_subdomain.sh create-all
```

### Setting Up Automatic Subdomain Creation

```bash
sudo /usr/local/bin/create_db_subdomain.sh setup-trigger
```

This sets up a PostgreSQL trigger that automatically creates a subdomain when a new database is created.

## Monitoring

If you enabled monitoring during installation, you can access:

- Grafana dashboard: `http://your_server_ip:3000` (default credentials: admin/admin)
- Prometheus: `http://your_server_ip:9090`

### Running Monitoring Manually

```bash
sudo /usr/local/bin/server_monitor.sh
```

### Auto-Scaling PostgreSQL

```bash
sudo /usr/local/bin/pg_auto_scale.sh
```

This script automatically optimizes PostgreSQL settings based on your server's resources.

## Backup and Restore

### Backing Up All Databases

```bash
sudo -u postgres pg_dumpall > /path/to/backup/all_databases.sql
```

### Backing Up a Single Database

```bash
sudo -u postgres pg_dump mydb > /path/to/backup/mydb.sql
```

### Restoring All Databases

```bash
sudo -u postgres psql -f /path/to/backup/all_databases.sql postgres
```

### Restoring a Single Database

```bash
sudo -u postgres psql -f /path/to/backup/mydb.sql mydb
```

## Connecting to Databases

### Direct PostgreSQL Connection

```bash
psql "sslmode=require host=mydb.yourdomain.com dbname=mydb user=myuser password=mypassword"
```

### Through PgBouncer (Recommended)

```bash
psql "host=mydb.yourdomain.com port=6432 dbname=mydb user=myuser password=mypassword"
```

## Troubleshooting

### Checking Logs

- PostgreSQL logs: `/var/log/postgresql/postgresql-*.log`
- PgBouncer logs: `/var/log/postgresql/pgbouncer.log`
- Server monitor logs: `/var/log/server_monitor.log`
- Auto-scaling logs: `/var/log/pg_auto_scale.log`
- Subdomain creation logs: `/var/log/db-subdomain.log`

### Common Issues

#### PostgreSQL Won't Start

Check the logs:
```bash
sudo journalctl -u postgresql
```

#### Email Alerts Not Working

Verify your SMTP settings in the `.env` file and test with:
```bash
sudo /usr/local/bin/server_monitor.sh
```

#### Connection Issues

Ensure your DNS is properly configured and check PostgreSQL logs:
```bash
sudo tail -f /var/log/postgresql/postgresql-*.log
```

#### Script Execution Errors

If you're getting permissions errors when running scripts, make sure the script is executable:
```bash
sudo ./server_init.sh install
```
The server initialization script automatically makes all modules and scripts executable.

## Security Best Practices

1. **Change default passwords** immediately after installation
2. **Keep PostgreSQL updated** with security patches
3. **Use SSL/TLS** for all connections
4. **Restrict remote access** to trusted IP addresses
5. **Regularly review logs** for suspicious activity
6. **Back up your data** regularly
7. **Use strong passwords** for all database users

## Advanced Configuration

### Customizing PgBouncer

Edit the PgBouncer configuration file:
```bash
sudo nano /etc/pgbouncer/pgbouncer.ini
```

### Customizing PostgreSQL

Edit the PostgreSQL configuration file:
```bash
sudo nano /etc/postgresql/17/main/postgresql.conf
```

### Customizing Nginx

Edit the Nginx template for database subdomains:
```bash
sudo nano /etc/nginx/sites-available/db-subdomain-template
```

## Support and Contributions

For support or to contribute to this project, please visit the GitHub repository:
https://github.com/yourusername/dbhub.cc 