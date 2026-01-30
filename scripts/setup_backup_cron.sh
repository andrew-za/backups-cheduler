#!/bin/bash

###############################################################################
# Setup Cron Job for Database Backups
# 
# This script sets up a cron job to run backups on a schedule
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_SCRIPT="${SCRIPT_DIR}/database_backup.sh"
CRON_LOG="${BASE_DIR}/logs/cron_backup.log"
CRON_SCHEDULE="${1:-0 2 * * *}"  # Default: Daily at 2 AM

# Check if backup script exists
if [[ ! -f "$BACKUP_SCRIPT" ]]; then
    echo "ERROR: Backup script not found: $BACKUP_SCRIPT"
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

# Create cron job entry
CRON_ENTRY="${CRON_SCHEDULE} ${BACKUP_SCRIPT} >> ${CRON_LOG} 2>&1"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "$BACKUP_SCRIPT"; then
    echo "Cron job already exists. Removing old entry..."
    crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT" | crontab -
fi

# Add new cron job
(crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -

echo "Cron job installed successfully!"
echo "Schedule: $CRON_SCHEDULE"
echo ""
echo "Current crontab:"
crontab -l | grep "$BACKUP_SCRIPT"
echo ""
echo "To view logs: tail -f ${CRON_LOG}"
echo "To test manually: $BACKUP_SCRIPT"
