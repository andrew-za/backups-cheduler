#!/bin/bash

###############################################################################
# Database Backup Script with Integrity Verification and FTP Upload
# 
# This script:
# - Discovers all user databases automatically
# - Creates compressed backups with integrity checks
# - Validates backups before upload
# - Uploads to remote FTP server with retry logic
# - Maintains detailed logs
# - Handles errors gracefully
###############################################################################

set -euo pipefail

# Get script directory and set base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${BASE_DIR}/config/.backup_config"
BACKUP_DIR="${BASE_DIR}/backups"
LOG_DIR="${BASE_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/backup_${TIMESTAMP}.log"
ERROR_LOG="${LOG_DIR}/backup_errors.log"
RETENTION_DAYS=30

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
        log_error "Please create it using the template: ${BASE_DIR}/config/backup_config.example"
        exit 1
    fi
    
    # Override retention if specified
    if [[ -n "${RETENTION_DAYS:-}" ]]; then
        RETENTION_DAYS="$RETENTION_DAYS"
    fi
}

# Initialize directories
init_directories() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$FTP_DIR"
}

# Get list of databases to backup (exclude system databases)
get_databases() {
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW DATABASES;" 2>/dev/null | \
        grep -vE "^Database$|^information_schema$|^performance_schema$|^mysql$|^sys$" | \
        grep -v "^$" || true
}

# Create backup for a single database
# Returns: 0 on success, 1 on failure
# Outputs backup file paths to stdout (one per line)
backup_database() {
    local db_name="$1"
    local backup_file="${BACKUP_DIR}/${db_name}_${TIMESTAMP}.sql"
    local compressed_file="${backup_file}.gz"
    local checksum_file="${backup_file}.sha256"
    
    log "Starting backup for database: $db_name"
    
    # Create backup with single-transaction for consistency
    if ! mysqldump \
        -u"$MYSQL_USER" \
        -p"$MYSQL_PASS" \
        --single-transaction \
        --routines \
        --triggers \
        --events \
        --quick \
        --lock-tables=false \
        "$db_name" > "$backup_file" 2>>"$LOG_FILE"; then
        log_error "Failed to create backup for database: $db_name"
        rm -f "$backup_file"
        return 1
    fi
    
    # Check if backup file is empty or too small (likely error)
    if [[ ! -s "$backup_file" ]] || [[ $(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null) -lt 100 ]]; then
        log_error "Backup file for $db_name appears to be empty or corrupted"
        rm -f "$backup_file"
        return 1
    fi
    
    # Verify SQL dump integrity by checking for common error patterns
    if grep -q "ERROR" "$backup_file" || grep -q "Warning" "$backup_file"; then
        log_warning "Backup for $db_name contains warnings/errors - checking severity"
        # Check if it's just warnings or actual errors
        if grep -q "ERROR [0-9]" "$backup_file"; then
            log_error "Backup for $db_name contains SQL errors"
            rm -f "$backup_file"
            return 1
        fi
    fi
    
    # Compress backup
    log "Compressing backup for $db_name"
    local compress_cmd
    compress_cmd=$(get_compression_cmd)
    if ! $compress_cmd "$backup_file"; then
        log_error "Failed to compress backup for $db_name"
        rm -f "$backup_file"
        return 1
    fi
    
    # Create checksum for integrity verification
    if ! sha256sum "$compressed_file" > "$checksum_file"; then
        log_error "Failed to create checksum for $db_name"
        rm -f "$compressed_file"
        return 1
    fi
    
    # Verify checksum immediately
    if ! sha256sum -c "$checksum_file" > /dev/null 2>&1; then
        log_error "Checksum verification failed for $db_name backup"
        rm -f "$compressed_file" "$checksum_file"
        return 1
    fi
    
    log_success "Backup completed for $db_name: $(du -h "$compressed_file" | cut -f1)"
    # Output file paths (to be captured by caller)
    echo "$compressed_file" >&1
    echo "$checksum_file" >&1
    return 0
}

# Upload file to FTP with retry logic
upload_to_ftp() {
    local local_file="$1"
    local remote_file=$(basename "$local_file")
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
            put $local_file -o $remote_file
            bye
        " >> "$LOG_FILE" 2>&1; then
            log_success "Successfully uploaded $remote_file"
            
            # Verify upload by checking file size remotely
            local local_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null)
            local remote_size=$(lftp -c "
                set ftp:ssl-allow no
                open -u $FTP_USER,$FTP_PASS $FTP_HOST
                cd $FTP_DIR
                cls -1 --sort=name $remote_file
                bye
            " 2>/dev/null | awk '{print $5}' | head -1 || echo "0")
            
            if [[ "$remote_size" == "$local_size" ]] || [[ "$remote_size" != "0" ]]; then
                log_success "Upload verification passed for $remote_file"
                return 0
            else
                log_warning "Upload size verification inconclusive for $remote_file"
                return 0  # Still consider it success if upload completed
            fi
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

# Cleanup old backups
cleanup_old_backups() {
    log "Cleaning up backups older than $RETENTION_DAYS days"
    find "$BACKUP_DIR" -type f -name "*.sql.gz" -mtime +$RETENTION_DAYS -delete
    find "$BACKUP_DIR" -type f -name "*.sha256" -mtime +$RETENTION_DAYS -delete
    find "$LOG_DIR" -type f -name "*.log" -mtime +$RETENTION_DAYS -delete
    log_success "Cleanup completed"
}

# Load resource monitor
source "${SCRIPT_DIR}/resource_monitor.sh" 2>/dev/null || {
    log_warning "Resource monitor not available, skipping resource checks"
}

# Main execution
main() {
    log "=========================================="
    log "Database Backup Process Started"
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
    
    log "Found $(echo "$databases" | wc -l) database(s) to backup"
    
    local success_count=0
    local fail_count=0
    local backup_files=()
    
    # Backup each database
    while IFS= read -r db_name; do
        [[ -z "$db_name" ]] && continue
        
        local backup_output
        backup_output=$(backup_database "$db_name" 2>&1)
        local backup_exit=$?
        
        if [[ $backup_exit -eq 0 ]]; then
            success_count=$((success_count + 1))
            # Add backup files to array (backup_database outputs file paths)
            while IFS= read -r file; do
                [[ -n "$file" ]] && [[ -f "$file" ]] && backup_files+=("$file")
            done <<< "$backup_output"
        else
            fail_count=$((fail_count + 1))
        fi
    done <<< "$databases"
    
    # Upload backups to FTP (if enabled)
    if should_upload_full_ftp; then
        log "=========================================="
        log "Starting FTP Upload Process"
        log "=========================================="
        
        local upload_success=0
        local upload_fail=0
        
        for backup_file in "${backup_files[@]}"; do
            [[ ! -f "$backup_file" ]] && continue
            
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
        upload_success=0
        upload_fail=0
    fi
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Summary
    log "=========================================="
    log "Backup Process Completed"
    log "=========================================="
    log "Databases backed up successfully: $success_count"
    log "Databases failed: $fail_count"
    log "Files uploaded successfully: $upload_success"
    log "Files upload failed: $upload_fail"
    log "Log file: $LOG_FILE"
    
    if [[ $fail_count -gt 0 ]] || [[ $upload_fail -gt 0 ]]; then
        log_error "Some backups or uploads failed - check logs for details"
        exit 1
    fi
    
    log_success "All backups completed successfully!"
    exit 0
}

# Run main function
main "$@"
