#!/bin/bash

###############################################################################
# Incremental Database Backup Script
# 
# This script performs efficient incremental backups by:
# - Only backing up tables modified since last backup
# - Using table modification timestamps to detect changes
# - Creating lightweight incremental dumps
# - Maintaining full backup references
# - Minimal resource usage for frequent backups
###############################################################################

set -euo pipefail

# Get script directory and set base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${BASE_DIR}/config/.backup_config"
BACKUP_DIR="${BASE_DIR}/backups"
INCREMENTAL_DIR="${BACKUP_DIR}/incremental"
LOG_DIR="${BASE_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/incremental_backup_${TIMESTAMP}.log"
ERROR_LOG="${LOG_DIR}/backup_errors.log"
STATE_FILE="${BASE_DIR}/config/.backup_state"
RETENTION_HOURS=168  # Default: Keep incremental backups for 7 days (overridden by config)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

###############################################################################
# Helper Functions
###############################################################################

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

# Load configuration utilities
source "${SCRIPT_DIR}/config_utils.sh" 2>/dev/null || {
    log_error "Failed to load config_utils.sh"
    exit 1
}

# Load configuration
load_config() {
    if ! load_backup_config "$CONFIG_FILE"; then
        log_error "Failed to load configuration"
        exit 1
    fi
    
    # Check if incremental backups are enabled
    if ! is_incremental_enabled; then
        log "Incremental backups are disabled in configuration"
        exit 0
    fi
    
    # Override retention if specified
    if [[ -n "${INCREMENTAL_RETENTION_HOURS:-}" ]]; then
        RETENTION_HOURS="$INCREMENTAL_RETENTION_HOURS"
    fi
}

# Initialize directories
init_directories() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$INCREMENTAL_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$(dirname "$STATE_FILE")"
}

# Get list of all user databases
get_all_databases() {
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW DATABASES;" 2>/dev/null | \
        grep -vE "^Database$|^information_schema$|^performance_schema$|^mysql$|^sys$" | \
        grep -v "^$" || true
}

# Get list of databases to backup (filtered by config)
get_databases() {
    local all_dbs
    all_dbs=$(get_all_databases)
    filter_databases_for_incremental "$all_dbs"
}

# Get table modification times for a database
get_table_mod_times() {
    local db_name="$1"
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$db_name" -e "
        SELECT 
            TABLE_NAME,
            UNIX_TIMESTAMP(UPDATE_TIME) as mod_time
        FROM information_schema.TABLES 
        WHERE TABLE_SCHEMA = '$db_name' 
        AND TABLE_TYPE = 'BASE TABLE'
        ORDER BY TABLE_NAME;
    " 2>/dev/null | tail -n +2 || true
}

# Get last backup time for a table
get_last_backup_time() {
    local db_name="$1"
    local table_name="$2"
    
    if [[ -f "$STATE_FILE" ]]; then
        grep "^${db_name}\.${table_name}:" "$STATE_FILE" | cut -d: -f2 || echo "0"
    else
        echo "0"
    fi
}

# Update backup state
update_backup_state() {
    local db_name="$1"
    local table_name="$2"
    local timestamp="$3"
    
    # Remove old entry if exists
    if [[ -f "$STATE_FILE" ]]; then
        grep -v "^${db_name}\.${table_name}:" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null || true
    fi
    
    # Add new entry
    echo "${db_name}.${table_name}:${timestamp}" >> "$STATE_FILE"
}

# Backup a single table incrementally
backup_table_incremental() {
    local db_name="$1"
    local table_name="$2"
    local backup_file="${INCREMENTAL_DIR}/${db_name}_${table_name}_${TIMESTAMP}.sql"
    local compressed_file="${backup_file}.gz"
    
    log "Backing up table: ${db_name}.${table_name}"
    
    # Create backup with minimal locking
    if ! mysqldump \
        -u"$MYSQL_USER" \
        -p"$MYSQL_PASS" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --no-create-info \
        --skip-triggers \
        "$db_name" "$table_name" > "$backup_file" 2>>"$LOG_FILE"; then
        log_error "Failed to backup table: ${db_name}.${table_name}"
        rm -f "$backup_file"
        return 1
    fi
    
    # Check if backup is empty (no changes)
    if [[ ! -s "$backup_file" ]] || [[ $(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null) -lt 50 ]]; then
        log "Table ${db_name}.${table_name} has no changes, skipping"
        rm -f "$backup_file"
        return 0
    fi
    
    # Compress backup
    if ! gzip -9 "$backup_file"; then
        log_error "Failed to compress backup for ${db_name}.${table_name}"
        rm -f "$backup_file"
        return 1
    fi
    
    # Create checksum
    local checksum_file="${backup_file}.sha256"
    if ! sha256sum "$compressed_file" > "$checksum_file"; then
        log_error "Failed to create checksum for ${db_name}.${table_name}"
        rm -f "$compressed_file"
        return 1
    fi
    
    log_success "Backed up ${db_name}.${table_name}: $(du -h "$compressed_file" | cut -f1)"
    echo "$compressed_file"
    echo "$checksum_file"
    return 0
}

# Process database for incremental backup
process_database() {
    local db_name="$1"
    local changed_tables=0
    local backup_files=()
    
    log "Processing database: $db_name"
    
    # Get table modification times
    local table_mods
    table_mods=$(get_table_mod_times "$db_name")
    
    if [[ -z "$table_mods" ]]; then
        log_warning "No tables found in database: $db_name"
        return 0
    fi
    
    # Check each table for changes
    while IFS=$'\t' read -r table_name mod_time; do
        [[ -z "$table_name" ]] && continue
        
        # Skip if mod_time is NULL (table never updated)
        [[ "$mod_time" == "NULL" ]] && mod_time="0"
        
        local last_backup_time
        last_backup_time=$(get_last_backup_time "$db_name" "$table_name")
        
        # Compare modification times (with 60 second buffer for clock skew)
        if [[ $mod_time -gt $((last_backup_time + 60)) ]]; then
            changed_tables=$((changed_tables + 1))
            
            local backup_output
            backup_output=$(backup_table_incremental "$db_name" "$table_name" 2>&1)
            local backup_exit=$?
            
            if [[ $backup_exit -eq 0 ]] && [[ -n "$backup_output" ]]; then
                # Update state with current timestamp
                update_backup_state "$db_name" "$table_name" "$mod_time"
                
                # Collect backup files
                while IFS= read -r file; do
                    [[ -n "$file" ]] && [[ -f "$file" ]] && backup_files+=("$file")
                done <<< "$backup_output"
            fi
        fi
    done <<< "$table_mods"
    
    if [[ $changed_tables -eq 0 ]]; then
        log "No changed tables in database: $db_name"
    else
        log_success "Found $changed_tables changed table(s) in $db_name"
    fi
    
    # Return backup files array (via global or output)
    for file in "${backup_files[@]}"; do
        echo "$file"
    done
}

# Upload file to FTP with retry logic
upload_to_ftp() {
    local local_file="$1"
    local remote_file="incremental/$(basename "$local_file")"
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
            mkdir -p incremental
            cd incremental
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

# Cleanup old incremental backups
cleanup_old_backups() {
    log "Cleaning up incremental backups older than $RETENTION_HOURS hours"
    find "$INCREMENTAL_DIR" -type f -name "*.sql.gz" -mmin +$((RETENTION_HOURS * 60)) -delete
    find "$INCREMENTAL_DIR" -type f -name "*.sha256" -mmin +$((RETENTION_HOURS * 60)) -delete
    log_success "Cleanup completed"
}

# Load resource monitor
source "${SCRIPT_DIR}/resource_monitor.sh" 2>/dev/null || {
    log_warning "Resource monitor not available, skipping resource checks"
}

# Main execution
main() {
    log "=========================================="
    log "Incremental Backup Process Started"
    log "=========================================="
    
    # Load configuration
    load_config
    
    # Initialize directories
    init_directories
    
    # Check resources before starting backup
    if [[ "$ENABLE_RESOURCE_CHECKS" == "true" ]]; then
        if ! wait_for_resources "$BACKUP_DIR"; then
            log_error "Backup cancelled due to high server load"
            exit 1
        fi
    fi
    
    # Get list of databases
    local databases
    databases=$(get_databases)
    
    if [[ -z "$databases" ]]; then
        log_error "No databases found to backup"
        exit 1
    fi
    
    log "Found $(echo "$databases" | wc -l) database(s) to check"
    
    local total_backups=0
    local backup_files=()
    
    # Process each database
    while IFS= read -r db_name; do
        [[ -z "$db_name" ]] && continue
        
        local db_backups
        db_backups=$(process_database "$db_name")
        
        # Collect backup files
        while IFS= read -r file; do
            [[ -n "$file" ]] && [[ -f "$file" ]] && backup_files+=("$file") && total_backups=$((total_backups + 1))
        done <<< "$db_backups"
    done <<< "$databases"
    
    # Upload backups to FTP (if enabled)
    if [[ ${#backup_files[@]} -gt 0 ]]; then
        if should_upload_incremental_ftp; then
            log "=========================================="
            log "Starting FTP Upload Process"
            log "=========================================="
            
            local upload_success=0
            local upload_fail=0
            
            for backup_file in "${backup_files[@]}"; do
                if upload_to_ftp "$backup_file"; then
                    upload_success=$((upload_success + 1))
                else
                    upload_fail=$((upload_fail + 1))
                fi
            done
            
            log "Files uploaded successfully: $upload_success"
            log "Files upload failed: $upload_fail"
        else
            log "FTP upload disabled in configuration, skipping upload"
        fi
    else
        log "No changes detected, skipping FTP upload"
    fi
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Summary
    log "=========================================="
    log "Incremental Backup Process Completed"
    log "=========================================="
    log "Tables backed up: $total_backups"
    log "Log file: $LOG_FILE"
    
    if [[ $total_backups -eq 0 ]]; then
        log "No changes detected since last backup"
    fi
    
    exit 0
}

# Run main function
main "$@"
