# DBHub.cc - PostgreSQL Server Management Suite

A comprehensive suite of scripts for setting up, managing, and monitoring PostgreSQL servers with advanced features like connection pooling, automatic subdomain routing, and security hardening.

## Features

- **One-command PostgreSQL setup** with PgBouncer connection pooling
- **Automatic subdomain routing** for databases using Nginx
- **Secure by default** with restricted users, SSL, and proper permissions
- **Comprehensive monitoring** with email alerts and performance tracking
- **Auto-scaling** PostgreSQL based on server resources
- **Modular design** for easy customization and extension

## Quick Installation

```bash
git clone https://github.com/Mola-TT/postgreSQL_server.git
cd postgreSQL_server
cp .env.example .env
# Edit .env with your settings

# Make scripts executable
chmod +x server_init.sh
chmod +x scripts/*.sh
chmod +x modules/*.sh

# Run the main installation script
sudo ./server_init.sh
```

## Documentation

For detailed usage instructions, see the [Usage Guide](USAGE_GUIDE.md).

## Components

- **server_init.sh**: Main installation script
- **modules/**: Modular components for different features
  - **postgresql.sh**: PostgreSQL installation and configuration
  - **pgbouncer.sh**: PgBouncer setup and management
  - **security.sh**: Security hardening features
  - **monitoring.sh**: Server monitoring setup
  - **subdomain.sh**: Subdomain routing configuration
- **scripts/**: Utility scripts
  - **db_user_manager.sh**: Database and user management
  - **create_db_subdomain.sh**: Subdomain creation for databases
  - **server_monitor.sh**: Server resource monitoring
  - **pg_auto_scale.sh**: PostgreSQL auto-scaling

## Requirements

- Ubuntu 20.04+ or Debian 11+
- Sudo access
- Internet connection for package installation

## Security Features

- Restricted database users with minimal privileges
- SSL/TLS for all connections
- Automatic security updates
- Proper file permissions
- Comprehensive logging
- Email alerts for suspicious activities

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- PostgreSQL community
- PgBouncer developers
- Nginx team
- All open-source contributors who made this possible

## Repository

GitHub: [@https://github.com/Mola-TT/postgreSQL_server.git](https://github.com/Mola-TT/postgreSQL_server.git)