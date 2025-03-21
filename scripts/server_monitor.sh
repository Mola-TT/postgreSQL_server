#!/bin/bash

# Server Monitoring Script
# This script monitors system resources and PostgreSQL/PgBouncer services
# It sends email alerts when thresholds are exceeded

# Set thresholds (percentage)
CPU_THRESHOLD=80
MEMORY_THRESHOLD=80
DISK_THRESHOLD=80
PG_CONN_THRESHOLD=80

# Log file
LOG_FILE="/var/log/server_monitor.log"
HOSTNAME=$(hostname)

# Ensure log directory exists
mkdir -p $(dirname $LOG_FILE)
touch $LOG_FILE

# Load environment variables for email configuration
for ENV_FILE in "./.env" "../.env" "/etc/dbhub/.env"; do
    if [ -f "$ENV_FILE" ]; then
        source "$ENV_FILE"
        break
    fi
done

# Logging function
log() {
    echo "[$(TZ=Asia/Singapore date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Alert function
send_alert() {
    SUBJECT="$HOSTNAME Alert: $1"
    MESSAGE="$2"
    
    if [ -n "$EMAIL_RECIPIENT" ] && [ -n "$EMAIL_SENDER" ] && [ -n "$SMTP_SERVER" ] && [ -n "$SMTP_PORT" ] && [ -n "$SMTP_USER" ] && [ -n "$SMTP_PASS" ]; then
        log "Sending email alert: $SUBJECT"
        curl --ssl-reqd \
            --url "smtps://$SMTP_SERVER:$SMTP_PORT" \
            --user "$SMTP_USER:$SMTP_PASS" \
            --mail-from "$EMAIL_SENDER" \
            --mail-rcpt "$EMAIL_RECIPIENT" \
            --upload-file - << EOF
From: Server Monitor <$EMAIL_SENDER>
To: Admin <$EMAIL_RECIPIENT>
Subject: $SUBJECT

$MESSAGE

Timestamp: $(TZ=Asia/Singapore date +'%Y-%m-%d %H:%M:%S')
Hostname: $HOSTNAME
EOF
    else
        log "Email configuration not found. Alert not sent: $SUBJECT"
    fi
}

# Check CPU usage
check_cpu() {
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}' | cut -d. -f1)
    log "CPU Usage: ${CPU_USAGE}%"
    
    if [ "$CPU_USAGE" -ge "$CPU_THRESHOLD" ]; then
        send_alert "High CPU Usage" "CPU usage is at ${CPU_USAGE}%, which exceeds the threshold of ${CPU_THRESHOLD}%."
    fi
}

# Check memory usage
check_memory() {
    MEMORY_USAGE=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
    log "Memory Usage: ${MEMORY_USAGE}%"
    
    if [ "$MEMORY_USAGE" -ge "$MEMORY_THRESHOLD" ]; then
        send_alert "High Memory Usage" "Memory usage is at ${MEMORY_USAGE}%, which exceeds the threshold of ${MEMORY_THRESHOLD}%."
    fi
}

# Check disk usage
check_disk() {
    DISK_USAGE=$(df -h / | grep / | awk '{print $5}' | cut -d% -f1)
    log "Disk Usage: ${DISK_USAGE}%"
    
    if [ "$DISK_USAGE" -ge "$DISK_THRESHOLD" ]; then
        send_alert "High Disk Usage" "Disk usage is at ${DISK_USAGE}%, which exceeds the threshold of ${DISK_THRESHOLD}%."
    fi
}

# Check PostgreSQL service
check_postgres_service() {
    if systemctl is-active --quiet postgresql; then
        log "PostgreSQL service is running"
        
        # Check if we can actually connect to PostgreSQL
        if sudo -u postgres pg_isready -q; then
            log "PostgreSQL is accepting connections"
        else
            log "PostgreSQL service is running but not accepting connections"
            send_alert "PostgreSQL Not Accepting Connections" "The PostgreSQL service is running but not accepting connections. Check the PostgreSQL logs for errors."
        fi
    else
        log "PostgreSQL service is down"
        send_alert "PostgreSQL Service Down" "The PostgreSQL service is not running."
    fi
}

# Check PgBouncer service
check_pgbouncer_service() {
    if systemctl is-active --quiet pgbouncer; then
        log "PgBouncer service is running"
    else
        log "PgBouncer service is down"
        send_alert "PgBouncer Service Down" "The PgBouncer service is not running."
    fi
}

# Check PostgreSQL connections
check_postgres_connections() {
    if systemctl is-active --quiet postgresql && sudo -u postgres pg_isready -q; then
        MAX_CONNECTIONS=$(sudo -u postgres psql -t -c "SHOW max_connections;" | tr -d ' ')
        CURRENT_CONNECTIONS=$(sudo -u postgres psql -t -c "SELECT count(*) FROM pg_stat_activity;" | tr -d ' ')
        
        if [ -n "$MAX_CONNECTIONS" ] && [ -n "$CURRENT_CONNECTIONS" ] && [ "$MAX_CONNECTIONS" -gt 0 ]; then
            CONNECTION_PERCENTAGE=$((CURRENT_CONNECTIONS * 100 / MAX_CONNECTIONS))
            
            log "PostgreSQL Connections: $CURRENT_CONNECTIONS/$MAX_CONNECTIONS (${CONNECTION_PERCENTAGE}%)"
            
            if [ "$CONNECTION_PERCENTAGE" -ge "$PG_CONN_THRESHOLD" ]; then
                send_alert "High PostgreSQL Connections" "PostgreSQL connections are at ${CONNECTION_PERCENTAGE}% (${CURRENT_CONNECTIONS}/${MAX_CONNECTIONS}), which exceeds the threshold of ${PG_CONN_THRESHOLD}%."
            fi
        else
            log "Could not determine PostgreSQL connection count"
        fi
    fi
}

# Check database sizes
check_database_sizes() {
    if systemctl is-active --quiet postgresql && sudo -u postgres pg_isready -q; then
        log "Database Sizes:"
        DB_SIZES=$(sudo -u postgres psql -t -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database ORDER BY pg_database_size(datname) DESC;")
        if [ -n "$DB_SIZES" ]; then
            echo "$DB_SIZES" | while read line; do
                log "  $line"
            done
        else
            log "  Could not retrieve database sizes"
        fi
    else
        log "PostgreSQL is not available. Skipping database size check."
    fi
}

# Check for slow queries
check_slow_queries() {
    if systemctl is-active --quiet postgresql && sudo -u postgres pg_isready -q; then
        SLOW_QUERIES=$(sudo -u postgres psql -t -c "SELECT pid, now() - query_start AS duration, usename, query FROM pg_stat_activity WHERE state = 'active' AND now() - query_start > '30 seconds'::interval ORDER BY duration DESC;")
        
        if [ -n "$SLOW_QUERIES" ]; then
            log "Slow Queries Detected:"
            echo "$SLOW_QUERIES" | while read line; do
                log "  $line"
            done
            
            send_alert "Slow PostgreSQL Queries" "Slow queries detected running for more than 30 seconds. Check the server monitor log for details."
        else
            log "No slow queries detected"
        fi
    else
        log "PostgreSQL is not available. Skipping slow query check."
    fi
}

# Check for database locks
check_database_locks() {
    if systemctl is-active --quiet postgresql && sudo -u postgres pg_isready -q; then
        LOCKS=$(sudo -u postgres psql -t -c "SELECT blocked_locks.pid AS blocked_pid, blocked_activity.usename AS blocked_user, blocking_locks.pid AS blocking_pid, blocking_activity.usename AS blocking_user, blocked_activity.query AS blocked_statement, blocking_activity.query AS blocking_statement FROM pg_catalog.pg_locks blocked_locks JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid JOIN pg_catalog.pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid AND blocking_locks.pid != blocked_locks.pid JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid WHERE NOT blocked_locks.granted;")
        
        if [ -n "$LOCKS" ]; then
            log "Database Locks Detected:"
            echo "$LOCKS" | while read line; do
                log "  $line"
            done
            
            send_alert "PostgreSQL Database Locks" "Database locks detected. Check the server monitor log for details."
        else
            log "No database locks detected"
        fi
    else
        log "PostgreSQL is not available. Skipping database lock check."
    fi
}

# Check for failed login attempts
check_failed_logins() {
    if [ -f "/var/log/auth.log" ]; then
        FAILED_LOGINS=$(grep "Failed password" /var/log/auth.log | grep -c "$(TZ=Asia/Singapore date +"%b %d")")
        
        if [ "$FAILED_LOGINS" -gt 10 ]; then
            log "High number of failed login attempts: $FAILED_LOGINS"
            send_alert "High Failed Login Attempts" "There have been $FAILED_LOGINS failed login attempts today."
        else
            log "Failed login attempts today: $FAILED_LOGINS"
        fi
    fi
}

# Main function
main() {
    log "Starting server monitoring check"
    
    check_cpu
    check_memory
    check_disk
    check_postgres_service
    check_pgbouncer_service
    check_postgres_connections
    check_database_sizes
    check_slow_queries
    check_database_locks
    check_failed_logins
    
    log "Server monitoring check completed"
    echo ""
}

# Run the main function
main
