#!/bin/bash

###############################################################################
# Setup Incremental Backup Cron Jobs
# 
# This script sets up hourly incremental backups
# Option 1: Table-level incremental (works immediately, no MySQL config needed)
# Option 2: Binary log backups (most efficient, requires binary logging enabled)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
INCREMENTAL_SCRIPT="${SCRIPT_DIR}/incremental_backup.sh"
BINLOG_SCRIPT="${SCRIPT_DIR}/backup_binary_logs.sh"
CRON_LOG="${BASE_DIR}/logs/cron_incremental.log"

# Check if scripts exist
if [[ ! -f "$INCREMENTAL_SCRIPT" ]]; then
    echo "ERROR: Incremental backup script not found: $INCREMENTAL_SCRIPT"
    exit 1
fi

# Check if config file exists
CONFIG_FILE="${BASE_DIR}/config/.backup_config"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please create it from ${BASE_DIR}/config/backup_config.example"
    exit 1
fi

# Ensure log directory exists
mkdir -p "$(dirname "$CRON_LOG")"

echo "=========================================="
echo "Incremental Backup Setup"
echo "=========================================="
echo ""
echo "Choose backup method:"
echo "1) Table-level incremental (works immediately, no MySQL config)"
echo "2) Binary log backups (most efficient, requires binary logging)"
echo "3) Both (table-level hourly + binary logs every 15 minutes)"
echo ""
read -p "Enter choice [1-3]: " choice

case $choice in
    1)
        BACKUP_SCRIPT="$INCREMENTAL_SCRIPT"
        SCHEDULE="0 * * * *"  # Every hour
        METHOD="table-level incremental"
        ;;
    2)
        BACKUP_SCRIPT="$BINLOG_SCRIPT"
        SCHEDULE="*/15 * * * *"  # Every 15 minutes
        METHOD="binary log"
        
        # Check if binary logging is enabled
        echo ""
        echo "Checking binary logging status..."
        if mysql -e "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null | grep -q "ON"; then
            echo "Binary logging is enabled ✓"
        else
            echo "WARNING: Binary logging is not enabled!"
            echo "Run: ${SCRIPT_DIR}/enable_binary_logging.sh"
            read -p "Continue anyway? [y/N]: " continue_choice
            if [[ "$continue_choice" != "y" ]] && [[ "$continue_choice" != "Y" ]]; then
                exit 1
            fi
        fi
        ;;
    3)
        # Setup both
        echo ""
        echo "Setting up both methods..."
        
        # Remove old cron entries
        crontab -l 2>/dev/null | grep -v "$INCREMENTAL_SCRIPT" | grep -v "$BINLOG_SCRIPT" | crontab - || true
        
        # Add table-level incremental (hourly)
        (crontab -l 2>/dev/null; echo "0 * * * * ${INCREMENTAL_SCRIPT} >> ${CRON_LOG} 2>&1") | crontab -
        
        # Add binary log backup (every 15 minutes)
        (crontab -l 2>/dev/null; echo "*/15 * * * * ${BINLOG_SCRIPT} >> ${CRON_LOG} 2>&1") | crontab -
        
        echo ""
        echo "Both backup methods configured!"
        echo "Table-level incremental: Every hour"
        echo "Binary log backups: Every 15 minutes"
        echo ""
        echo "Current crontab entries:"
        crontab -l | grep -E "($INCREMENTAL_SCRIPT|$BINLOG_SCRIPT)"
        exit 0
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

# Remove old cron entries for this script
if crontab -l 2>/dev/null | grep -q "$BACKUP_SCRIPT"; then
    echo "Removing old cron entry..."
    crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" | crontab -
fi

# Add new cron job
CRON_ENTRY="${SCHEDULE} ${BACKUP_SCRIPT} >> ${CRON_LOG} 2>&1"
(crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -

echo ""
echo "=========================================="
echo "Incremental Backup Cron Job Installed"
echo "=========================================="
echo "Method: $METHOD"
echo "Schedule: $SCHEDULE"
echo "Script: $BACKUP_SCRIPT"
echo ""
echo "Current crontab entry:"
crontab -l | grep "$BACKUP_SCRIPT"
echo ""
echo "To view logs: tail -f ${CRON_LOG}"
echo "To test manually: $BACKUP_SCRIPT"
