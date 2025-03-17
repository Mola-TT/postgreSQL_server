#!/bin/bash

# Monitoring-related functions for PostgreSQL server setup

# Function to set up monitoring
setup_monitoring() {
    log "Setting up monitoring"
    
    # Copy monitoring scripts
    copy_monitoring_scripts
    
    # Install monitoring tools
    install_monitoring_tools
    
    # Set up monitoring services
    setup_monitoring_services
    
    # Send test email
    send_test_email
}

# Function to copy monitoring scripts
copy_monitoring_scripts() {
    log "Copying monitoring scripts"
    
    # Create scripts directory
    mkdir -p /usr/local/bin
    
    # Copy server monitor script
    cp "$(dirname "$0")/scripts/server_monitor.sh" /usr/local/bin/
    chmod +x /usr/local/bin/server_monitor.sh
    
    # Copy auto-scaling script
    cp "$(dirname "$0")/scripts/pg_auto_scale.sh" /usr/local/bin/
    chmod +x /usr/local/bin/pg_auto_scale.sh
}

# Function to install monitoring tools
install_monitoring_tools() {
    log "Installing monitoring tools"
    
    # Check if monitoring tools installation script exists
    if [ -f "$(dirname "$0")/scripts/install_monitoring.sh" ]; then
        log "Running monitoring tools installation script"
        
        # Copy script to temporary location
        cp "$(dirname "$0")/scripts/install_monitoring.sh" /tmp/
        chmod +x /tmp/install_monitoring.sh
        
        # Run the script
        /tmp/install_monitoring.sh
        
        # Clean up
        rm /tmp/install_monitoring.sh
    else
        log "WARNING: Monitoring tools installation script not found"
    fi
}

# Function to set up monitoring services
setup_monitoring_services() {
    log "Setting up monitoring services"
    
    # Create server monitor service
    cat > "/etc/systemd/system/server-monitor.service" << EOF
[Unit]
Description=Server Monitoring Service
After=network.target postgresql.service pgbouncer.service

[Service]
Type=simple
ExecStart=/usr/local/bin/server_monitor.sh
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

    # Create server monitor timer
    cat > "/etc/systemd/system/server-monitor.timer" << EOF
[Unit]
Description=Run server monitoring every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF

    # Create auto-scaling service
    cat > "/etc/systemd/system/pg-auto-scale.service" << EOF
[Unit]
Description=PostgreSQL Auto-Scaling Service
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pg_auto_scale.sh

[Install]
WantedBy=multi-user.target
EOF

    # Create auto-scaling timer
    cat > "/etc/systemd/system/pg-auto-scale.timer" << EOF
[Unit]
Description=Run PostgreSQL auto-scaling daily

[Timer]
OnBootSec=15min
OnCalendar=daily

[Install]
WantedBy=timers.target
EOF

    # Enable and start services
    systemctl daemon-reload
    systemctl enable server-monitor.timer
    systemctl start server-monitor.timer
    systemctl enable pg-auto-scale.timer
    systemctl start pg-auto-scale.timer
}

# Function to send test email
send_test_email() {
    log "Sending test email"
    
    # Check if email configuration is complete
    if [ -n "$EMAIL_RECIPIENT" ] && [ -n "$EMAIL_SENDER" ] && [ -n "$SMTP_SERVER" ]; then
        # Create test message
        local message="This is a test email from your PostgreSQL server.

Server: $(hostname)
IP Address: $(hostname -I | awk '{print $1}')
Date: $(date)

Your PostgreSQL server has been set up successfully with the following components:
- PostgreSQL $PG_VERSION
- PgBouncer
- Monitoring services
- Security enhancements

Connection Information:
- PostgreSQL: localhost:5432
- PgBouncer: localhost:${PGBOUNCER_PORT:-6432}
"
        
        # Send email
        send_email "PostgreSQL Server Setup Complete" "$message"
        
        log "Test email sent to $EMAIL_RECIPIENT"
    else
        log "Email configuration not complete, skipping test email"
    fi
} 