#!/bin/bash

# Server Monitoring Script
# This script monitors server resources and sends email alerts if thresholds are exceeded

# Configuration
THRESHOLD=80  # Percentage threshold for alerts (CPU, memory, disk)
LOG_FILE="/var/log/server_monitor.log"
HOSTNAME=$(hostname)

# Load environment variables for email configuration
for ENV_PATH in "/.env" "/root/.env" "/home/ubuntu/.env" "$HOME/.env" "./.env"; do
    if [ -f "$ENV_PATH" ]; then
        source "$ENV_PATH"
        break
    fi
done

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $HOSTNAME $1" | tee -a "$LOG_FILE"
}

# Function to send email alerts
send_alert() {
    local subject="$1"
    local message="$2"
    
    log "Sending alert: $subject"
    
    # Create email content
    local email_content=$(cat <<EOF_EMAIL
From: Server Monitor <$EMAIL_SENDER>
To: $EMAIL_RECIPIENT
Subject: $subject
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: 8bit

$message

--
This is an automated message from your server monitoring system.
Server: $HOSTNAME
Time: $(date)
EOF_EMAIL
)
    
    # Send email using curl with SSL
    curl --url "smtps://$SMTP_SERVER:$SMTP_PORT" \
         --ssl-reqd \
         --mail-from "$EMAIL_SENDER" \
         --mail-rcpt "$EMAIL_RECIPIENT" \
         --user "$SMTP_USER:$SMTP_PASS" \
         --upload-file - <<< "$email_content"
}

# Create log file if it doesn't exist
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

log "Starting server monitoring..."

# Check CPU usage
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' | cut -d. -f1)
log "CPU usage: $CPU_USAGE%"

if [ "$CPU_USAGE" -gt "$THRESHOLD" ]; then
    send_alert "ALERT: High CPU Usage on $HOSTNAME" "CPU usage is currently at ${CPU_USAGE}%.

Top CPU consuming processes:
$(ps aux --sort=-%cpu | head -n 6)

Please investigate and take appropriate action."
fi

# Check memory usage
MEM_USAGE=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
log "Memory usage: $MEM_USAGE%"

if [ "$MEM_USAGE" -gt "$THRESHOLD" ]; then
    send_alert "ALERT: High Memory Usage on $HOSTNAME" "Memory usage is currently at ${MEM_USAGE}%.

Memory usage details:
$(free -h)

Top memory consuming processes:
$(ps aux --sort=-%mem | head -n 6)

Please investigate and take appropriate action."
fi

# Check disk usage
DISK_ALERT=false
DISK_MESSAGE="The following filesystems are running low on space:\n\n"

while read -r line; do
    # Skip lines that don't start with /dev
    if [[ ! $line =~ ^/dev ]]; then
        continue
    fi
    
    FILESYSTEM=$(echo "$line" | awk '{print $1}')
    MOUNT_POINT=$(echo "$line" | awk '{print $6}')
    USAGE=$(echo "$line" | awk '{print $5}' | sed 's/%//')
    
    log "Filesystem $FILESYSTEM mounted on $MOUNT_POINT: $USAGE% used"
    
    if [ "$USAGE" -gt "$THRESHOLD" ]; then
        DISK_ALERT=true
        DISK_MESSAGE+="$MOUNT_POINT: $USAGE% used\n"
    fi
done < <(df -h | grep -v "tmpfs|udev")

if [ "$DISK_ALERT" = true ]; then
    DISK_MESSAGE+="
Full disk usage details:
$(df -h)

Please investigate and take appropriate action."
    send_alert "ALERT: High Disk Usage on $HOSTNAME" "$DISK_MESSAGE"
fi

# Check PostgreSQL status
if ! systemctl is-active --quiet postgresql; then
    send_alert "ALERT: PostgreSQL Service Down on $HOSTNAME" "The PostgreSQL service is currently not running.

Last log entries:
$(tail -n 20 /var/log/postgresql/postgresql-*.log 2>/dev/null || echo 'No recent logs found')

Please investigate and restart the service if needed."
fi

# Check PgBouncer status
if ! systemctl is-active --quiet pgbouncer; then
    send_alert "ALERT: PgBouncer Service Down on $HOSTNAME" "The PgBouncer service is currently not running.

Please investigate and restart the service if needed."
fi

# Check PostgreSQL connection count
PG_MAX_CONN=$(sudo -u postgres psql -t -c "SHOW max_connections;" | tr -d ' ')
PG_CURRENT_CONN=$(sudo -u postgres psql -t -c "SELECT count(*) FROM pg_stat_activity;" | tr -d ' ')
PG_CONN_PERCENT=$((PG_CURRENT_CONN * 100 / PG_MAX_CONN))

log "PostgreSQL connections: $PG_CURRENT_CONN/$PG_MAX_CONN ($PG_CONN_PERCENT%)"

if [ "$PG_CONN_PERCENT" -gt "$THRESHOLD" ]; then
    send_alert "ALERT: High PostgreSQL Connection Count on $HOSTNAME" "PostgreSQL connection count is currently at ${PG_CONN_PERCENT}% of maximum (${PG_CURRENT_CONN}/${PG_MAX_CONN}).

Connection details:
$(sudo -u postgres psql -c "SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname ORDER BY count(*) DESC;")

Please investigate and take appropriate action."
fi

# Check PostgreSQL database sizes
DB_SIZES=$(sudo -u postgres psql -t -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;")
log "PostgreSQL database sizes:\n$DB_SIZES"

# Check for slow queries
SLOW_QUERIES=$(sudo -u postgres psql -t -c "SELECT pid, now() - query_start AS duration, usename, datname, query FROM pg_stat_activity WHERE state = 'active' AND now() - query_start > '30 seconds'::interval ORDER BY duration DESC;")

if [ -n "$SLOW_QUERIES" ]; then
    send_alert "ALERT: Slow PostgreSQL Queries on $HOSTNAME" "The following queries have been running for more than 30 seconds:

$SLOW_QUERIES

Please investigate and take appropriate action."
fi

# Check for database locks
DB_LOCKS=$(sudo -u postgres psql -t -c "SELECT blocked_locks.pid AS blocked_pid, blocked_activity.usename AS blocked_user, blocking_locks.pid AS blocking_pid, blocking_activity.usename AS blocking_user, blocked_activity.query AS blocked_statement, blocking_activity.query AS blocking_statement FROM pg_catalog.pg_locks blocked_locks JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid JOIN pg_catalog.pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid AND blocking_locks.pid != blocked_locks.pid JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid WHERE NOT blocked_locks.granted;")

if [ -n "$DB_LOCKS" ]; then
    send_alert "ALERT: PostgreSQL Database Locks on $HOSTNAME" "The following database locks are currently active:

$DB_LOCKS

Please investigate and take appropriate action."
fi

# Check for failed login attempts
FAILED_LOGINS=$(grep "authentication failed" /var/log/postgresql/postgresql-*.log 2>/dev/null | tail -n 10)

if [ -n "$FAILED_LOGINS" ]; then
    send_alert "ALERT: Failed PostgreSQL Login Attempts on $HOSTNAME" "The following failed login attempts were detected:

$FAILED_LOGINS

Please investigate and take appropriate action."
fi

log "Server monitoring completed."
exit 0
