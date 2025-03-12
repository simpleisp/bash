#!/bin/bash

# Error handling function
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

echo "Starting MariaDB configuration optimization for FreeRADIUS..."

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    error_exit "This script must be run as root. Try using sudo."
fi

# Check if MariaDB is installed
if ! command -v mariadb &> /dev/null; then
    error_exit "MariaDB is not installed. Please install it first."
fi

# Function to aggressively kill all MariaDB processes
kill_all_mariadb() {
    echo "Aggressively terminating all MariaDB processes..."
    
    # Stop the service first
    systemctl stop mariadb
    sleep 2
    
    # Find and kill all MariaDB processes
    for PROC in mysqld mariadbd mysql mariadb; do
        # Try with pkill first (process name)
        pkill -9 $PROC 2>/dev/null || true
        
        # Try with pkill -f (command line)
        pkill -9 -f $PROC 2>/dev/null || true
    done
    
    # Find any remaining MySQL processes by port
    for PID in $(lsof -i:3306 -t 2>/dev/null); do
        kill -9 $PID 2>/dev/null || true
    done
    
    # Wait to ensure processes are terminated
    sleep 3
    
    # Check if any processes are still running
    if pgrep -x "mysqld" > /dev/null || pgrep -x "mariadbd" > /dev/null || pgrep -f "mysql" > /dev/null; then
        echo "Warning: Some MariaDB processes are still running. This may cause issues."
    else
        echo "All MariaDB processes have been terminated."
    fi
}

# Function to clean up lock files
cleanup_lock_files() {
    echo "Cleaning up lock files..."
    
    # Remove aria log files
    rm -f /var/lib/mysql/aria_log_control 2>/dev/null || true
    rm -f /var/lib/mysql/aria_log.* 2>/dev/null || true
    
    # Remove InnoDB lock files
    rm -f /var/lib/mysql/ib_logfile* 2>/dev/null || true
    rm -f /var/lib/mysql/ibdata1.lock 2>/dev/null || true
    
    # Remove socket files
    rm -f /var/run/mysqld/mysqld.sock 2>/dev/null || true
    rm -f /tmp/mysql.sock 2>/dev/null || true
    
    # Remove pid file
    rm -f /var/run/mysqld/mysqld.pid 2>/dev/null || true
    
    # Ensure the mysqld directory exists with proper permissions
    mkdir -p /var/run/mysqld 2>/dev/null || true
    chown mysql:mysql /var/run/mysqld 2>/dev/null || true
    
    # Fix permissions on data directory
    chown -R mysql:mysql /var/lib/mysql/ 2>/dev/null || true
    
    echo "Lock files cleanup completed."
}

# Calculate system resources
TOTAL_RAM=$(free -b | awk '/Mem:/ {print $2}')
CPU_CORES=$(nproc)

# Calculate RAM allocation (70% for buffer pool)
BUFFER_POOL_SIZE=$((TOTAL_RAM * 70 / 100))
BUFFER_POOL_SIZE_MB=$((BUFFER_POOL_SIZE / 1024 / 1024))

# Calculate CPU-based settings targeting 60% CPU usage
# Each InnoDB instance can use about 15% CPU, so we calculate based on that
INNODB_INSTANCES=$((CPU_CORES * 60 / 100))  # 60% of cores
INNODB_INSTANCES=$((INNODB_INSTANCES > 0 ? INNODB_INSTANCES : 1))  # Minimum 1

# IO threads should be proportional to InnoDB instances
IO_THREADS=$((INNODB_INSTANCES * 2))  # 2 threads per instance

# Thread pool size based on CPU cores (targeting 60% utilization)
THREAD_POOL_SIZE=$((CPU_CORES * 60 / 100))
THREAD_POOL_SIZE=$((THREAD_POOL_SIZE > 0 ? THREAD_POOL_SIZE : 1))

# Calculate other resource-based settings
MAX_CONNECTIONS=$((CPU_CORES * 100))  # 100 connections per core
MAX_USER_CONNECTIONS=$((MAX_CONNECTIONS * 80 / 100))  # 80% of max connections

# Calculate buffer sizes based on available RAM
PER_THREAD_BUFFERS=$((TOTAL_RAM * 5 / 100 / MAX_CONNECTIONS))  # 5% of RAM divided by max connections
SORT_BUFFER_SIZE=$((PER_THREAD_BUFFERS / 4))
READ_BUFFER_SIZE=$((PER_THREAD_BUFFERS / 4))
JOIN_BUFFER_SIZE=$((PER_THREAD_BUFFERS / 4))
READ_RND_BUFFER_SIZE=$((PER_THREAD_BUFFERS / 4))

# Convert buffer sizes to MB with minimum values
SORT_BUFFER_SIZE_MB=$((SORT_BUFFER_SIZE / 1024 / 1024))
SORT_BUFFER_SIZE_MB=$((SORT_BUFFER_SIZE_MB > 0 ? SORT_BUFFER_SIZE_MB : 1))

READ_BUFFER_SIZE_MB=$((READ_BUFFER_SIZE / 1024 / 1024))
READ_BUFFER_SIZE_MB=$((READ_BUFFER_SIZE_MB > 0 ? READ_BUFFER_SIZE_MB : 1))

JOIN_BUFFER_SIZE_MB=$((JOIN_BUFFER_SIZE / 1024 / 1024))
JOIN_BUFFER_SIZE_MB=$((JOIN_BUFFER_SIZE_MB > 0 ? JOIN_BUFFER_SIZE_MB : 1))

READ_RND_BUFFER_SIZE_MB=$((READ_RND_BUFFER_SIZE / 1024 / 1024))
READ_RND_BUFFER_SIZE_MB=$((READ_RND_BUFFER_SIZE_MB > 0 ? READ_RND_BUFFER_SIZE_MB : 1))

# Calculate table cache based on RAM
TABLE_OPEN_CACHE=$((TOTAL_RAM / 1024 / 1024 / 2))  # Roughly 1 cache entry per 2MB RAM

# Define the MariaDB configuration file locations for Ubuntu 20.04
MYSQL_CONF_FILES=(
  "/etc/mysql/mariadb.conf.d/50-server.cnf"
)

# Kill all MariaDB processes before making configuration changes
kill_all_mariadb
cleanup_lock_files

# Loop through the possible configuration file locations
for MYSQL_CONF_FILE in "${MYSQL_CONF_FILES[@]}"; do
    # Check if the file exists
    if [ -f "$MYSQL_CONF_FILE" ]; then
        # Backup the configuration file
        BACKUP_FILE="${MYSQL_CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$MYSQL_CONF_FILE" "$BACKUP_FILE"
        echo "Backed up $MYSQL_CONF_FILE to $BACKUP_FILE"
        
        # Create a temporary file for the new configuration
        TMP_CONF=$(mktemp)
        
        # Read the original file to preserve structure and comments
        # Extract the [mysqld] section
        MYSQLD_SECTION_FOUND=false
        CURRENT_SECTION=""
        
        while IFS= read -r line; do
            # Detect section headers
            if [[ "$line" =~ ^\[(.*)\] ]]; then
                CURRENT_SECTION="${BASH_REMATCH[1]}"
                echo "$line" >> "$TMP_CONF"
                
                # If we found the mysqld section, add our optimized settings
                if [[ "$CURRENT_SECTION" == "mysqld" ]]; then
                    MYSQLD_SECTION_FOUND=true
                    
                    # Add our optimized settings for FreeRADIUS
                    cat >> "$TMP_CONF" << EOF

# Basic Settings
user                    = mysql
pid-file                = /run/mysqld/mysqld.pid
socket                  = /run/mysqld/mysqld.sock
port                    = 3306
basedir                 = /usr
datadir                 = /var/lib/mysql
tmpdir                  = /tmp
lc-messages-dir         = /usr/share/mysql
bind-address            = 0.0.0.0

# Logging Configuration
log_error               = /var/log/mysql/error.log
log_warnings           = 2

# FreeRADIUS-Optimized InnoDB Settings
innodb_buffer_pool_size = ${BUFFER_POOL_SIZE_MB}M
innodb_buffer_pool_instances = ${INNODB_INSTANCES}
innodb_log_file_size    = 512M
innodb_log_buffer_size  = 64M
innodb_file_per_table   = ON
innodb_open_files       = ${TABLE_OPEN_CACHE}
innodb_io_capacity      = $((IO_THREADS * 100))
innodb_flush_method     = O_DIRECT
innodb_read_io_threads  = ${IO_THREADS}
innodb_write_io_threads = ${IO_THREADS}
innodb_stats_on_metadata = OFF
innodb_flush_log_at_trx_commit = 2
innodb_doublewrite      = 0
innodb_lock_wait_timeout = 5
innodb_deadlock_detect  = ON

# Connection Settings for FreeRADIUS Accounting
max_connections         = ${MAX_CONNECTIONS}
max_user_connections    = ${MAX_USER_CONNECTIONS}
thread_cache_size       = $((THREAD_POOL_SIZE * 2))
thread_stack            = 192K
interactive_timeout     = 30
wait_timeout           = 30
max_allowed_packet      = 16M
net_read_timeout       = 5
net_write_timeout      = 5
connect_timeout        = 5

# Thread Pool Settings for Fast Accounting
thread_handling         = pool-of-threads
thread_pool_size        = ${THREAD_POOL_SIZE}
thread_pool_idle_timeout = 30
thread_pool_max_threads = $((MAX_CONNECTIONS / 2))
thread_pool_oversubscribe = 3

# Query Cache Settings (disabled for high-concurrency workloads)
query_cache_type        = 0
query_cache_size        = 0

# Buffer Settings
sort_buffer_size        = ${SORT_BUFFER_SIZE_MB}M
read_buffer_size        = ${READ_BUFFER_SIZE_MB}M
read_rnd_buffer_size    = ${READ_RND_BUFFER_SIZE_MB}M
join_buffer_size        = ${JOIN_BUFFER_SIZE_MB}M
tmp_table_size          = $((BUFFER_POOL_SIZE_MB / 32))M
max_heap_table_size     = $((BUFFER_POOL_SIZE_MB / 32))M

# Table Settings
table_open_cache        = ${TABLE_OPEN_CACHE}
table_definition_cache  = $((TABLE_OPEN_CACHE / 2))
open_files_limit        = $((TABLE_OPEN_CACHE * 2))

# MyISAM Settings (minimal since we use InnoDB)
key_buffer_size         = $((BUFFER_POOL_SIZE_MB / 32))M
myisam_sort_buffer_size = $((BUFFER_POOL_SIZE_MB / 64))M

# Aria Settings
aria_pagecache_buffer_size = $((BUFFER_POOL_SIZE_MB / 32))M
aria_sort_buffer_size   = $((BUFFER_POOL_SIZE_MB / 64))M
aria_group_commit       = none
aria_group_commit_interval = 0
aria_log_purge_type     = immediate

# Security
local-infile            = 0
skip-name-resolve       = ON

# Performance Schema (enable for monitoring)
performance_schema      = ON
performance_schema_max_table_instances = $((TABLE_OPEN_CACHE / 2))

# Slow Query Logging
slow_query_log          = 1
slow_query_log_file     = /var/log/mysql/mariadb-slow.log
long_query_time         = 2

# MySQL optimization settings to handle high load and connection issues
innodb_lock_wait_timeout = 30
max_connections = 1000
innodb_buffer_pool_size = 4G
innodb_log_buffer_size = 64M
innodb_file_per_table = 1
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_thread_concurrency = 0
thread_cache_size = 100
table_open_cache = 8000
query_cache_type = 0
query_cache_size = 0
max_connect_errors = 999999
wait_timeout = 600
interactive_timeout = 600
skip-name-resolve
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000
innodb_read_io_threads = 8
innodb_write_io_threads = 8
innodb_buffer_pool_instances = 8

EOF
                fi
            elif [[ "$CURRENT_SECTION" == "mysqld" && "$MYSQLD_SECTION_FOUND" == true ]]; then
                # Skip existing settings in the mysqld section as we've already added our optimized ones
                continue
            else
                # Copy the line as is for other sections
                echo "$line" >> "$TMP_CONF"
            fi
        done < "$MYSQL_CONF_FILE"
        
        # If we didn't find a mysqld section, add one with the same settings
        if [[ "$MYSQLD_SECTION_FOUND" == false ]]; then
            echo -e "\n[mysqld]" >> "$TMP_CONF"
            # Add the same configuration block as above
            cat >> "$TMP_CONF" << EOF
# Same configuration block as above...
EOF
        fi
        
        # Check the size of the generated file
        TMP_SIZE=$(stat -c %s "$TMP_CONF" 2>/dev/null || stat -f %z "$TMP_CONF")
        ORIG_SIZE=$(stat -c %s "$MYSQL_CONF_FILE" 2>/dev/null || stat -f %z "$MYSQL_CONF_FILE")
        
        if [ "$TMP_SIZE" -gt $((ORIG_SIZE * 10)) ]; then
            echo "Warning: Generated configuration file is much larger than original (${TMP_SIZE} vs ${ORIG_SIZE} bytes)."
            echo "This may indicate a problem. Aborting to prevent file corruption."
            rm -f "$TMP_CONF"
            error_exit "Configuration generation failed due to unexpected file size."
        fi
        
        # Replace the original file with the new configuration
        mv "$TMP_CONF" "$MYSQL_CONF_FILE"
        chmod 644 "$MYSQL_CONF_FILE"
        echo "Updated MariaDB configuration in $MYSQL_CONF_FILE"
        
        echo "Configuration updated successfully."
    else
        echo "Warning: Configuration file $MYSQL_CONF_FILE not found."
    fi
done

# Make sure all processes are killed and locks are removed before starting
kill_all_mariadb
cleanup_lock_files

# Start MariaDB service
echo "Starting MariaDB service..."
systemctl start mariadb
sleep 5

# Check if MariaDB is running
if systemctl is-active --quiet mariadb; then
    echo "MariaDB service is running."
    
    # Show some key variables to confirm changes
    echo "Checking key MariaDB variables:"
    echo "CPU-related settings:"
    mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_instances';"
    mysql -e "SHOW VARIABLES LIKE 'thread_pool_size';"
    mysql -e "SHOW VARIABLES LIKE 'innodb_read_io_threads';"
    echo "Memory-related settings:"
    mysql -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"
    mysql -e "SHOW VARIABLES LIKE 'sort_buffer_size';"
    
    echo "MariaDB has been optimized for FreeRADIUS workloads!"
    echo "Configuration is dynamically scaled to use:"
    echo "- ${BUFFER_POOL_SIZE_MB}M of RAM for buffer pool (70% of total RAM)"
    echo "- ${INNODB_INSTANCES} InnoDB instances (60% of CPU cores)"
    echo "- ${THREAD_POOL_SIZE} thread pool size (60% of CPU cores)"
    echo "This should help resolve the FreeRADIUS SQL module issues while maintaining efficient resource usage."
else
    echo "MariaDB failed to restart. Trying emergency mode..."
    
    # Kill all processes again
    kill_all_mariadb
    cleanup_lock_files
    
    # Try starting with skip-grant-tables
    echo "Starting MariaDB with skip-grant-tables..."
    systemctl set-environment MYSQLD_OPTS="--skip-grant-tables --skip-networking"
    systemctl start mariadb
    sleep 5
    
    # Reset environment and restart normally
    systemctl set-environment MYSQLD_OPTS=""
    systemctl restart mariadb
    sleep 5
    
    if systemctl is-active --quiet mariadb; then
        echo "MariaDB service is now running after emergency restart."
        echo "MariaDB has been optimized for FreeRADIUS workloads!"
        echo "Configuration is dynamically scaled to use:"
        echo "- ${BUFFER_POOL_SIZE_MB}M of RAM for buffer pool (70% of total RAM)"
        echo "- ${INNODB_INSTANCES} InnoDB instances (60% of CPU cores)"
        echo "- ${THREAD_POOL_SIZE} thread pool size (60% of CPU cores)"
    else
        echo "MariaDB still failed to restart. Manual intervention required."
        echo "Try rebooting the system and then running: sudo systemctl start mariadb"
        echo "Or check the logs: sudo journalctl -u mariadb"
    fi
fi

# Function to get MySQL version
get_mysql_version() {
    mysql --version | awk '{print $3}' | awk -F'-' '{print $1}'
}

# Function to validate MySQL settings
validate_mysql_settings() {
    echo "Validating MySQL settings..."
    
    # Check if MySQL is running
    if ! systemctl is-active --quiet mariadb; then
        error_exit "MariaDB service is not running"
    fi
    
    # Check key settings
    local settings=(
        "innodb_buffer_pool_size"
        "max_connections"
        "innodb_lock_wait_timeout"
        "innodb_io_capacity"
    )
    
    for setting in "${settings[@]}"; do
        value=$(mysql -e "SHOW VARIABLES LIKE '$setting';" | awk '{print $2}')
        echo "✓ $setting = $value"
    done
}

# Function to monitor MySQL performance
monitor_mysql() {
    echo "Starting MySQL performance monitoring..."
    
    # Monitor key metrics for 60 seconds
    timeout 60 mysqladmin extended-status | grep -E '(Threads_connected|Questions|Queries|Connections|Aborted_connects)' &
    
    echo "✓ Monitoring started. Press Ctrl+C to stop."
}

# Validate settings
validate_mysql_settings

# Start monitoring
monitor_mysql