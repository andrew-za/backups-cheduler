#!/bin/bash

###############################################################################
# Enable MySQL Binary Logging for Efficient Incremental Backups
# 
# Binary logging provides the most efficient incremental backup method.
# This script enables it and configures it properly.
###############################################################################

set -euo pipefail

CONFIG_FILE="/etc/mysql/mariadb.conf.d/50-server.cnf"
BACKUP_CONFIG="/etc/mysql/mariadb.conf.d/99-backup-logging.cnf"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "ERROR: $1" >&2
}

# Check if binary logging is already enabled
check_binary_logging() {
    local binlog_status
    binlog_status=$(mysql -e "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null | grep log_bin | awk '{print $2}' || echo "OFF")
    
    if [[ "$binlog_status" == "ON" ]]; then
        log "Binary logging is already enabled"
        mysql -e "SHOW VARIABLES LIKE 'log_bin%';" 2>/dev/null | cat
        return 0
    fi
    
    return 1
}

# Enable binary logging
enable_binary_logging() {
    log "Enabling binary logging..."
    
    # Create backup configuration file
    cat > "$BACKUP_CONFIG" << 'EOF'
# Binary logging configuration for incremental backups
[mysqld]
# Enable binary logging
log-bin=mysql-bin
binlog_format=ROW
expire_logs_days=7
max_binlog_size=100M
sync_binlog=1
binlog_cache_size=1M
max_binlog_cache_size=2G

# Performance optimizations
innodb_flush_log_at_trx_commit=1
EOF

    log "Configuration file created: $BACKUP_CONFIG"
    log "Restarting MariaDB service..."
    
    if systemctl restart mariadb; then
        log "MariaDB restarted successfully"
        sleep 3
        
        # Verify binary logging is enabled
        if check_binary_logging; then
            log "Binary logging enabled successfully!"
            return 0
        else
            log_error "Binary logging may not be enabled. Check logs: journalctl -u mariadb"
            return 1
        fi
    else
        log_error "Failed to restart MariaDB. Please check: systemctl status mariadb"
        return 1
    fi
}

main() {
    if check_binary_logging; then
        exit 0
    fi
    
    log "Binary logging is not enabled. Enabling now..."
    
    if enable_binary_logging; then
        log "=========================================="
        log "Binary logging setup complete!"
        log "=========================================="
        log "You can now use binary log backups for efficient incremental backups"
        log "Binary logs will be kept for 7 days"
        exit 0
    else
        log_error "Failed to enable binary logging"
        exit 1
    fi
}

main "$@"
