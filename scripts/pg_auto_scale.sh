#!/bin/bash

# PostgreSQL Auto-Scaling Script
# Automatically adjusts PostgreSQL configuration based on server resources

# Log file
LOG_FILE="/var/log/pg_auto_scale.log"
PG_CONF="/etc/postgresql/$(ls /etc/postgresql/ | sort -V | tail -n1)/main/postgresql.conf"
PG_VERSION=$(ls /etc/postgresql/ | sort -V | tail -n1)

# Load environment variables
ENV_FILES=("/etc/dbhub/.env" "/opt/dbhub/.env" "$(dirname "$0")/../.env" ".env")
for ENV_FILE in "${ENV_FILES[@]}"; do
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        break
    fi
done

# Logging function
log() {
    echo "[$(TZ=Asia/Singapore date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Create log file if it doesn't exist
if [[ ! -f "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
fi

log "Starting PostgreSQL auto-scaling process"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log "ERROR: This script must be run as root"
    exit 1
fi

# Check if PostgreSQL is installed
if ! command -v psql &> /dev/null; then
    log "ERROR: PostgreSQL is not installed"
    exit 1
fi

# Check if PostgreSQL is running
if ! systemctl is-active --quiet postgresql; then
    log "ERROR: PostgreSQL service is not running"
    exit 1
fi

# Check if configuration file exists
if [[ ! -f "$PG_CONF" ]]; then
    log "ERROR: PostgreSQL configuration file not found at $PG_CONF"
    exit 1
fi

# Get system memory in KB
TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
# Convert to MB
TOTAL_MEM_MB=$((TOTAL_MEM / 1024))
# Get number of CPU cores
CPU_CORES=$(nproc)

log "System has $TOTAL_MEM_MB MB memory and $CPU_CORES CPU cores"

# Calculate optimal PostgreSQL settings
# shared_buffers: 25% of RAM, up to 8GB
SHARED_BUFFERS=$((TOTAL_MEM_MB / 4))
if [[ $SHARED_BUFFERS -gt 8192 ]]; then
    SHARED_BUFFERS=8192
fi

# effective_cache_size: 75% of RAM
EFFECTIVE_CACHE_SIZE=$((TOTAL_MEM_MB * 3 / 4))

# maintenance_work_mem: 5% of RAM up to 1GB
MAINTENANCE_WORK_MEM=$((TOTAL_MEM_MB / 20))
if [[ $MAINTENANCE_WORK_MEM -gt 1024 ]]; then
    MAINTENANCE_WORK_MEM=1024
fi

# work_mem: (TOTAL_MEM_MB - SHARED_BUFFERS) / (4 * max_connections)
# Get current max_connections
MAX_CONNECTIONS=$(grep -E "^max_connections\s*=" "$PG_CONF" | sed -E 's/^max_connections\s*=\s*([0-9]+).*/\1/')
if [[ -z "$MAX_CONNECTIONS" ]]; then
    MAX_CONNECTIONS=100
fi

WORK_MEM=$(( (TOTAL_MEM_MB - SHARED_BUFFERS) / (4 * MAX_CONNECTIONS) ))
if [[ $WORK_MEM -lt 4 ]]; then
    WORK_MEM=4
fi

# wal_buffers: 1/32 of shared_buffers, up to 16MB
WAL_BUFFERS=$((SHARED_BUFFERS / 32))
if [[ $WAL_BUFFERS -gt 16 ]]; then
    WAL_BUFFERS=16
fi

# max_worker_processes and max_parallel_workers: CPU cores
MAX_WORKER_PROCESSES=$CPU_CORES
MAX_PARALLEL_WORKERS=$CPU_CORES

# max_parallel_workers_per_gather: CPU cores / 2
MAX_PARALLEL_WORKERS_PER_GATHER=$((CPU_CORES / 2))
if [[ $MAX_PARALLEL_WORKERS_PER_GATHER -lt 1 ]]; then
    MAX_PARALLEL_WORKERS_PER_GATHER=1
fi

log "Calculated optimal PostgreSQL settings:"
log "shared_buffers = ${SHARED_BUFFERS}MB"
log "effective_cache_size = ${EFFECTIVE_CACHE_SIZE}MB"
log "maintenance_work_mem = ${MAINTENANCE_WORK_MEM}MB"
log "work_mem = ${WORK_MEM}MB"
log "wal_buffers = ${WAL_BUFFERS}MB"
log "max_worker_processes = $MAX_WORKER_PROCESSES"
log "max_parallel_workers = $MAX_PARALLEL_WORKERS"
log "max_parallel_workers_per_gather = $MAX_PARALLEL_WORKERS_PER_GATHER"

# Backup the original configuration file
BACKUP_FILE="${PG_CONF}.$(TZ=Asia/Singapore date +%Y%m%d%H%M%S).bak"
cp "$PG_CONF" "$BACKUP_FILE"
log "Created backup of PostgreSQL configuration: $BACKUP_FILE"

# Update PostgreSQL configuration
update_setting() {
    PARAM=$1
    VALUE=$2
    UNIT=$3
    
    # Check if parameter exists in the file
    if grep -q "^#*\s*${PARAM}\s*=" "$PG_CONF"; then
        # Parameter exists, update it
        sed -i -E "s/^#*\s*${PARAM}\s*=.*/${PARAM} = ${VALUE}${UNIT}/" "$PG_CONF"
        log "Updated $PARAM = $VALUE$UNIT"
    else
        # Parameter doesn't exist, add it
        echo "$PARAM = $VALUE$UNIT" >> "$PG_CONF"
        log "Added $PARAM = $VALUE$UNIT"
    fi
}

update_setting "shared_buffers" "$SHARED_BUFFERS" "MB"
update_setting "effective_cache_size" "$EFFECTIVE_CACHE_SIZE" "MB"
update_setting "maintenance_work_mem" "$MAINTENANCE_WORK_MEM" "MB"
update_setting "work_mem" "$WORK_MEM" "MB"
update_setting "wal_buffers" "$WAL_BUFFERS" "MB"
update_setting "max_worker_processes" "$MAX_WORKER_PROCESSES" ""
update_setting "max_parallel_workers" "$MAX_PARALLEL_WORKERS" ""
update_setting "max_parallel_workers_per_gather" "$MAX_PARALLEL_WORKERS_PER_GATHER" ""

# Additional optimizations based on workload
# These are general optimizations that work well for most workloads
update_setting "random_page_cost" "1.1" ""
update_setting "effective_io_concurrency" "200" ""
update_setting "checkpoint_completion_target" "0.9" ""
update_setting "wal_buffers" "$WAL_BUFFERS" "MB"
update_setting "default_statistics_target" "100" ""
update_setting "synchronous_commit" "off" ""

# Restart PostgreSQL to apply changes
log "Restarting PostgreSQL to apply changes"
systemctl restart postgresql

# Verify PostgreSQL is running after restart
if systemctl is-active --quiet postgresql; then
    log "PostgreSQL restarted successfully with new configuration"
else
    log "ERROR: PostgreSQL failed to restart. Rolling back changes..."
    cp "$BACKUP_FILE" "$PG_CONF"
    systemctl restart postgresql
    if systemctl is-active --quiet postgresql; then
        log "Rollback successful, PostgreSQL is running with original configuration"
    else
        log "CRITICAL ERROR: PostgreSQL failed to start even after rollback"
    fi
fi

log "PostgreSQL auto-scaling process completed"

# Add cron job to run this script daily if not already added
if ! crontab -l | grep -q "pg_auto_scale.sh"; then
    (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/pg_auto_scale.sh") | crontab -
    log "Added cron job to run auto-scaling daily at 2 AM"
fi

exit 0 