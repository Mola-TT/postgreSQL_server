# Monitoring Module

# Monitoring-related functions for PostgreSQL server setup

# Main monitoring setup function
_module_setup_monitoring() {
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
    
    # Install dependencies
    log "Installing dependencies"
    apt-get update
    apt-get install -y wget curl tar adduser libfontconfig1 gnupg
    
    # Create service users
    log "Creating service users"
    if id -u prometheus >/dev/null 2>&1; then
        log "Prometheus user already exists"
    else
        useradd --no-create-home --shell /bin/false prometheus
    fi
    
    if id -u node_exporter >/dev/null 2>&1; then
        log "Node Exporter user already exists"
    else
        useradd --no-create-home --shell /bin/false node_exporter
    fi
    
    # Create directories
    log "Creating directories"
    mkdir -p /etc/prometheus /var/lib/prometheus
    chown prometheus:prometheus /etc/prometheus /var/lib/prometheus
    
    # Install Prometheus
    log "Installing Prometheus $PROMETHEUS_VERSION"
    
    # Check if Prometheus is already installed
    if [ -f "/usr/local/bin/prometheus" ]; then
        # Stop Prometheus service if running
        if systemctl is-active --quiet prometheus; then
            log "Stopping Prometheus service before upgrade"
            systemctl stop prometheus
            sleep 2
        fi
    fi
    
    # Download and extract Prometheus
    PROMETHEUS_ARCHIVE="prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz"
    wget -q "https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION/$PROMETHEUS_ARCHIVE"
    tar xzf "$PROMETHEUS_ARCHIVE"
    
    # Copy Prometheus binaries
    if [ -f "/usr/local/bin/prometheus" ]; then
        log "Removing existing Prometheus binary"
        rm -f /usr/local/bin/prometheus
    fi
    if [ -f "/usr/local/bin/promtool" ]; then
        log "Removing existing Promtool binary"
        rm -f /usr/local/bin/promtool
    fi
    
    # Copy with proper error handling
    cp "prometheus-$PROMETHEUS_VERSION.linux-amd64/prometheus" "/usr/local/bin/" || {
        log "ERROR: Failed to copy prometheus binary, retrying after delay"
        sleep 3
        cp "prometheus-$PROMETHEUS_VERSION.linux-amd64/prometheus" "/usr/local/bin/" || {
            log "ERROR: Failed to copy prometheus binary again, using alternative method"
            cat "prometheus-$PROMETHEUS_VERSION.linux-amd64/prometheus" > "/usr/local/bin/prometheus"
        }
    }
    
    cp "prometheus-$PROMETHEUS_VERSION.linux-amd64/promtool" "/usr/local/bin/" || {
        log "ERROR: Failed to copy promtool binary, retrying after delay"
        sleep 3
        cp "prometheus-$PROMETHEUS_VERSION.linux-amd64/promtool" "/usr/local/bin/" || {
            log "ERROR: Failed to copy promtool binary again, using alternative method"
            cat "prometheus-$PROMETHEUS_VERSION.linux-amd64/promtool" > "/usr/local/bin/promtool"
        }
    }
    
    # Set permissions
    chmod 755 /usr/local/bin/prometheus /usr/local/bin/promtool
    chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
    
    # Copy configuration files
    cp -r "prometheus-$PROMETHEUS_VERSION.linux-amd64/consoles" /etc/prometheus/
    cp -r "prometheus-$PROMETHEUS_VERSION.linux-amd64/console_libraries" /etc/prometheus/
    cp "prometheus-$PROMETHEUS_VERSION.linux-amd64/prometheus.yml" /etc/prometheus/
    
    # Set permissions
    chown -R prometheus:prometheus /etc/prometheus/consoles /etc/prometheus/console_libraries
    chown prometheus:prometheus /etc/prometheus/prometheus.yml
    
    # Clean up
    rm -rf "prometheus-$PROMETHEUS_VERSION.linux-amd64" "$PROMETHEUS_ARCHIVE"
    
    # Configure Prometheus
    log "Configuring Prometheus"
    cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node_exporter'
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'postgres_exporter'
    scrape_interval: 5s
    static_configs:
      - targets: ['localhost:9187']
EOF
    
    chown prometheus:prometheus /etc/prometheus/prometheus.yml
    
    # Create Prometheus systemd service
    log "Creating Prometheus systemd service"
    cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus/ \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOF
    
    # Install Node Exporter
    log "Installing Node Exporter $NODE_EXPORTER_VERSION"
    
    # Check if Node Exporter is already installed
    if [ -f "/usr/local/bin/node_exporter" ]; then
        # Stop Node Exporter service if running
        if systemctl is-active --quiet node_exporter; then
            log "Stopping Node Exporter service before upgrade"
            systemctl stop node_exporter
            sleep 2
        fi
    fi
    
    # Download and extract Node Exporter
    NODE_EXPORTER_ARCHIVE="node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz"
    wget -q "https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/$NODE_EXPORTER_ARCHIVE"
    tar xzf "$NODE_EXPORTER_ARCHIVE"
    
    # Copy Node Exporter binary
    if [ -f "/usr/local/bin/node_exporter" ]; then
        log "Removing existing Node Exporter binary"
        rm -f /usr/local/bin/node_exporter
    fi
    
    # Copy with proper error handling
    cp "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter" "/usr/local/bin/" || {
        log "ERROR: Failed to copy node_exporter binary, retrying after delay"
        sleep 3
        cp "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter" "/usr/local/bin/" || {
            log "ERROR: Failed to copy node_exporter binary again, using alternative method"
            cat "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64/node_exporter" > "/usr/local/bin/node_exporter"
        }
    }
    
    # Set permissions
    chmod 755 /usr/local/bin/node_exporter
    chown node_exporter:node_exporter /usr/local/bin/node_exporter
    
    # Clean up
    rm -rf "node_exporter-$NODE_EXPORTER_VERSION.linux-amd64" "$NODE_EXPORTER_ARCHIVE"
    
    # Create Node Exporter systemd service
    log "Creating Node Exporter systemd service"
    cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF
    
    # Install PostgreSQL Exporter
    log "Installing PostgreSQL Exporter"
    
    # Check if PostgreSQL Exporter is already installed
    if [ -f "/usr/local/bin/postgres_exporter" ]; then
        # Stop PostgreSQL Exporter service if running
        if systemctl is-active --quiet postgres_exporter; then
            log "Stopping PostgreSQL Exporter service before upgrade"
            systemctl stop postgres_exporter
            sleep 2
        fi
    fi
    
    # Create PostgreSQL Exporter user
    if id -u postgres_exporter >/dev/null 2>&1; then
        log "PostgreSQL Exporter user already exists"
    else
        useradd --no-create-home --shell /bin/false postgres_exporter
    fi
    
    # Download and extract PostgreSQL Exporter
    POSTGRES_EXPORTER_ARCHIVE="postgres_exporter-$POSTGRES_EXPORTER_VERSION.linux-amd64.tar.gz"
    wget -q "https://github.com/prometheus-community/postgres_exporter/releases/download/v$POSTGRES_EXPORTER_VERSION/$POSTGRES_EXPORTER_ARCHIVE"
    tar xzf "$POSTGRES_EXPORTER_ARCHIVE"
    
    # Copy PostgreSQL Exporter binary
    if [ -f "/usr/local/bin/postgres_exporter" ]; then
        log "Removing existing PostgreSQL Exporter binary"
        rm -f /usr/local/bin/postgres_exporter
    fi
    
    # Copy with proper error handling
    cp "postgres_exporter-$POSTGRES_EXPORTER_VERSION.linux-amd64/postgres_exporter" "/usr/local/bin/" || {
        log "ERROR: Failed to copy postgres_exporter binary, retrying after delay"
        sleep 3
        cp "postgres_exporter-$POSTGRES_EXPORTER_VERSION.linux-amd64/postgres_exporter" "/usr/local/bin/" || {
            log "ERROR: Failed to copy postgres_exporter binary again, using alternative method"
            cat "postgres_exporter-$POSTGRES_EXPORTER_VERSION.linux-amd64/postgres_exporter" > "/usr/local/bin/postgres_exporter"
        }
    }
    
    # Set permissions
    chmod 755 /usr/local/bin/postgres_exporter
    chown postgres_exporter:postgres_exporter /usr/local/bin/postgres_exporter
    
    # Clean up
    rm -rf "postgres_exporter-$POSTGRES_EXPORTER_VERSION.linux-amd64" "$POSTGRES_EXPORTER_ARCHIVE"
    
    # Create PostgreSQL Exporter configuration
    mkdir -p /etc/postgres_exporter
    cat > /etc/postgres_exporter/postgres_exporter.env << EOF
DATA_SOURCE_NAME="postgresql://postgres:$PG_PASSWORD@localhost:5432/postgres?sslmode=disable"
EOF
    
    chown postgres_exporter:postgres_exporter /etc/postgres_exporter/postgres_exporter.env
    chmod 600 /etc/postgres_exporter/postgres_exporter.env
    
    # Create PostgreSQL Exporter systemd service
    log "Creating PostgreSQL Exporter systemd service"
    cat > /etc/systemd/system/postgres_exporter.service << EOF
[Unit]
Description=PostgreSQL Exporter
Wants=network-online.target
After=network-online.target postgresql.service

[Service]
User=postgres_exporter
Group=postgres_exporter
Type=simple
EnvironmentFile=/etc/postgres_exporter/postgres_exporter.env
ExecStart=/usr/local/bin/postgres_exporter

[Install]
WantedBy=multi-user.target
EOF
    
    # Install Grafana
    log "Installing Grafana $GRAFANA_VERSION"
    GRAFANA_DEB="grafana_${GRAFANA_VERSION}_amd64.deb"
    wget -q "https://dl.grafana.com/oss/release/$GRAFANA_DEB"
    dpkg -i "$GRAFANA_DEB"
    
    # Clean up
    rm -f "$GRAFANA_DEB"
    
    # Configure Grafana
    log "Configuring Grafana"
    
    # Create basic dashboard
    log "Creating basic dashboard"
    mkdir -p /var/lib/grafana/dashboards
    
    # Enable and start services
    log "Enabling and starting services"
    systemctl daemon-reload
    systemctl enable grafana-server
    systemctl enable prometheus
    systemctl enable node_exporter
    systemctl enable postgres_exporter
    
    # Configure firewall rules
    log "Configuring firewall rules"
    ufw allow 9090/tcp comment "Prometheus"
    ufw allow 3000/tcp comment "Grafana"
    ufw reload
    
    # Create monitoring info file
    log "Creating monitoring info file"
    cat > /root/monitoring_info.txt << EOF
Monitoring Information
=====================

Prometheus: http://$(hostname -f):9090
Grafana: http://$(hostname -f):3000
Node Exporter: http://$(hostname -f):9100
PostgreSQL Exporter: http://$(hostname -f):9187

Grafana Default Login:
Username: admin
Password: admin

Generated: $(date +'%Y-%m-%d %H:%M:%S')
EOF
    
    log "Monitoring setup completed successfully"
    log "Monitoring info available at /root/monitoring_info.txt"
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