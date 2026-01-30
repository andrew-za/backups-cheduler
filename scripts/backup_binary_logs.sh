#!/bin/bash

###############################################################################
# Binary Log Backup Script
# 
# This script backs up MySQL binary logs for point-in-time recovery.
# Binary logs contain ALL changes (INSERTs, UPDATEs, DELETEs) since the last full backup.
# This is the ONLY method that captures UPDATEs and DELETEs, not just new rows.
# Most efficient and complete incremental backup method.
###############################################################################

set -euo pipefail

# Get script directory and set base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${BASE_DIR}/config/.backup_config"
BACKUP_DIR="${BASE_DIR}/backups"
BINLOG_DIR="${BACKUP_DIR}/binlogs"
LOG_DIR="${BASE_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/binlog_backup_${TIMESTAMP}.log"
ERROR_LOG="${LOG_DIR}/backup_errors.log"
STATE_FILE="${BASE_DIR}/config/.binlog_state"
RETENTION_DAYS=7

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE" | tee -a "$ERROR_LOG"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# Load configuration
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    local required_vars=("FTP_HOST" "FTP_USER" "FTP_PASS" "FTP_DIR" "MYSQL_USER" "MYSQL_PASS")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required configuration variable not set: $var"
            exit 1
        fi
    done
}

# Check if binary logging is enabled
check_binary_logging() {
    local binlog_status
    binlog_status=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null | grep log_bin | awk '{print $2}' || echo "OFF")
    
    if [[ "$binlog_status" != "ON" ]]; then
        log_error "Binary logging is not enabled. Run enable_binary_logging.sh first"
        return 1
    fi
    
    return 0
}

# Get list of binary log files
get_binary_logs() {
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW BINARY LOGS;" 2>/dev/null | tail -n +2 | awk '{print $1}' || true
}

# Get last backed up binary log
get_last_backed_log() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE" | head -1 || echo ""
    else
        echo ""
    fi
}

# Backup binary log file
backup_binary_log() {
    local binlog_name="$1"
    local binlog_path=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW VARIABLES LIKE 'datadir';" 2>/dev/null | grep datadir | awk '{print $2}')
    local source_file="${binlog_path}/${binlog_name}"
    local backup_file="${BINLOG_DIR}/${binlog_name}"
    local compressed_file="${backup_file}.gz"
    
    log "Backing up binary log: $binlog_name"
    
    # Check if file exists
    if [[ ! -f "$source_file" ]]; then
        log_warning "Binary log file not found: $source_file"
        return 1
    fi
    
    # Check if this is the current active log (might be actively written to)
    local current_log
    current_log=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW MASTER STATUS\G" 2>/dev/null | grep "File:" | awk '{print $2}' || echo "")
    
    # For active log, flush logs first to ensure we get a complete copy
    if [[ "$binlog_name" == "$current_log" ]]; then
        log "Flushing binary logs to ensure complete backup of active log"
        mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "FLUSH BINARY LOGS;" 2>/dev/null || true
        sleep 1  # Brief pause to ensure flush completes
    fi
    
    # Copy binary log using mysqlbinlog for safety (handles active logs better)
    # But first try direct copy (faster)
    if ! cp "$source_file" "$backup_file" 2>/dev/null; then
        log_warning "Direct copy failed, trying alternative method..."
        # Alternative: use mysqlbinlog to read and save
        if ! mysqlbinlog "$source_file" > "${backup_file}.txt" 2>/dev/null; then
            log_error "Failed to backup binary log: $binlog_name"
            rm -f "${backup_file}.txt"
            return 1
        fi
        mv "${backup_file}.txt" "$backup_file"
    fi
    
    # Compress
    if ! gzip -9 "$backup_file"; then
        log_error "Failed to compress binary log: $binlog_name"
        rm -f "$backup_file"
        return 1
    fi
    
    # Create checksum
    local checksum_file="${backup_file}.sha256"
    if ! sha256sum "$compressed_file" > "$checksum_file"; then
        log_error "Failed to create checksum for $binlog_name"
        rm -f "$compressed_file"
        return 1
    fi
    
    log_success "Backed up $binlog_name: $(du -h "$compressed_file" | cut -f1)"
    echo "$compressed_file"
    echo "$checksum_file"
    return 0
}

# Upload to FTP
upload_to_ftp() {
    local local_file="$1"
    local remote_file="binlogs/$(basename "$local_file")"
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        log "Uploading $remote_file to FTP (attempt $((retry_count + 1))/$max_retries)"
        
        if lftp -c "
            set ftp:ssl-allow no
            set net:timeout 30
            set net:max-retries 3
            open -u $FTP_USER,$FTP_PASS $FTP_HOST
            cd $FTP_DIR
            mkdir -p binlogs
            cd binlogs
            put $local_file -o $(basename "$local_file")
            bye
        " >> "$LOG_FILE" 2>&1; then
            log_success "Successfully uploaded $remote_file"
            return 0
        else
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                log_warning "Upload failed, retrying in 10 seconds..."
                sleep 10
            else
                log_error "Failed to upload $remote_file after $max_retries attempts"
                return 1
            fi
        fi
    done
    
    return 1
}

# Cleanup old binary logs
cleanup_old_backups() {
    log "Cleaning up binary log backups older than $RETENTION_DAYS days"
    find "$BINLOG_DIR" -type f -name "*.gz" -mtime +$RETENTION_DAYS -delete
    find "$BINLOG_DIR" -type f -name "*.sha256" -mtime +$RETENTION_DAYS -delete
    log_success "Cleanup completed"
}

# Main execution
main() {
    log "=========================================="
    log "Binary Log Backup Process Started"
    log "=========================================="
    
    load_config
    
    if ! check_binary_logging; then
        exit 1
    fi
    
    mkdir -p "$BINLOG_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$(dirname "$STATE_FILE")"
    
    local last_backed_log
    last_backed_log=$(get_last_backed_log)
    local binlogs
    binlogs=$(get_binary_logs)
    
    if [[ -z "$binlogs" ]]; then
        log "No binary logs found"
        exit 0
    fi
    
    local new_logs=0
    local backup_files=()
    local latest_log=""
    
    # Process each binary log
    while IFS= read -r binlog_name; do
        [[ -z "$binlog_name" ]] && continue
        
        # Skip if already backed up
        if [[ -n "$last_backed_log" ]] && [[ "$binlog_name" == "$last_backed_log" ]]; then
            last_backed_log=""  # Clear flag, backup remaining logs
            continue
        fi
        
        if [[ -z "$last_backed_log" ]] || [[ -n "$last_backed_log" ]]; then
            new_logs=$((new_logs + 1))
            latest_log="$binlog_name"
            
            local backup_output
            backup_output=$(backup_binary_log "$binlog_name" 2>&1)
            local backup_exit=$?
            
            if [[ $backup_exit -eq 0 ]] && [[ -n "$backup_output" ]]; then
                while IFS= read -r file; do
                    [[ -n "$file" ]] && [[ -f "$file" ]] && backup_files+=("$file")
                done <<< "$backup_output"
            fi
        fi
    done <<< "$binlogs"
    
    # Update state file
    if [[ -n "$latest_log" ]]; then
        echo "$latest_log" > "$STATE_FILE"
    fi
    
    # Upload backups
    if [[ ${#backup_files[@]} -gt 0 ]]; then
        log "Uploading ${#backup_files[@]} file(s) to FTP..."
        local upload_success=0
        local upload_fail=0
        
        for backup_file in "${backup_files[@]}"; do
            if upload_to_ftp "$backup_file"; then
                upload_success=$((upload_success + 1))
            else
                upload_fail=$((upload_fail + 1))
            fi
        done
        
        log "Uploaded: $upload_success, Failed: $upload_fail"
    fi
    
    cleanup_old_backups
    
    log "=========================================="
    log "Binary Log Backup Completed"
    log "New logs backed up: $new_logs"
    log "=========================================="
    
    exit 0
}

main "$@"
