#!/bin/bash

###############################################################################
# Row-Level Incremental Database Backup Script
# 
# This script performs true incremental backups by backing up only NEW rows:
# - Uses auto-increment IDs or timestamps to detect new rows
# - Only backs up rows added/modified since last backup
# - Minimal resource usage - only processes new data
# - Works best with tables that have auto-increment IDs or timestamp columns
###############################################################################

set -euo pipefail

# Get script directory and set base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${BASE_DIR}/config/.backup_config"
BACKUP_DIR="${BASE_DIR}/backups"
INCREMENTAL_DIR="${BACKUP_DIR}/incremental_rows"
LOG_DIR="${BASE_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/incremental_rows_backup_${TIMESTAMP}.log"
ERROR_LOG="${LOG_DIR}/backup_errors.log"
STATE_FILE="${BASE_DIR}/config/.backup_rows_state"
RETENTION_HOURS=168  # Keep incremental backups for 7 days

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

# Initialize directories
init_directories() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$INCREMENTAL_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$(dirname "$STATE_FILE")"
}

# Get list of databases to backup
get_databases() {
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW DATABASES;" 2>/dev/null | \
        grep -vE "^Database$|^information_schema$|^performance_schema$|^mysql$|^sys$" | \
        grep -v "^$" || true
}

# Get tables in a database
get_tables() {
    local db_name="$1"
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$db_name" -e "SHOW TABLES;" 2>/dev/null | tail -n +2 || true
}

# Detect best incremental column for a table
detect_incremental_column() {
    local db_name="$1"
    local table_name="$2"
    
    # Try to find auto-increment primary key first
    local auto_inc_col
    auto_inc_col=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$db_name" -e "
        SELECT COLUMN_NAME 
        FROM information_schema.COLUMNS 
        WHERE TABLE_SCHEMA = '$db_name' 
        AND TABLE_NAME = '$table_name' 
        AND EXTRA LIKE '%auto_increment%'
        LIMIT 1;
    " 2>/dev/null | tail -n +2 | head -1)
    
    if [[ -n "$auto_inc_col" ]]; then
        echo "$auto_inc_col"
        return 0
    fi
    
    # Try to find timestamp/datetime column (created_at, updated_at, date_created, etc.)
    local timestamp_col
    timestamp_col=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$db_name" -e "
        SELECT COLUMN_NAME 
        FROM information_schema.COLUMNS 
        WHERE TABLE_SCHEMA = '$db_name' 
        AND TABLE_NAME = '$table_name' 
        AND COLUMN_TYPE IN ('timestamp', 'datetime', 'date')
        AND (COLUMN_NAME LIKE '%created%' OR COLUMN_NAME LIKE '%updated%' OR COLUMN_NAME LIKE '%date%')
        ORDER BY COLUMN_NAME LIKE '%created%' DESC, COLUMN_NAME LIKE '%updated%' DESC
        LIMIT 1;
    " 2>/dev/null | tail -n +2 | head -1)
    
    if [[ -n "$timestamp_col" ]]; then
        echo "$timestamp_col"
        return 0
    fi
    
    # Try any ID column
    local id_col
    id_col=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$db_name" -e "
        SELECT COLUMN_NAME 
        FROM information_schema.COLUMNS 
        WHERE TABLE_SCHEMA = '$db_name' 
        AND TABLE_NAME = '$table_name' 
        AND COLUMN_NAME LIKE '%id%'
        AND COLUMN_KEY = 'PRI'
        LIMIT 1;
    " 2>/dev/null | tail -n +2 | head -1)
    
    if [[ -n "$id_col" ]]; then
        echo "$id_col"
        return 0
    fi
    
    return 1
}

# Get last backed up value for a table
get_last_backed_value() {
    local db_name="$1"
    local table_name="$2"
    
    if [[ -f "$STATE_FILE" ]]; then
        grep "^${db_name}\.${table_name}:" "$STATE_FILE" | cut -d: -f2 || echo ""
    else
        echo ""
    fi
}

# Update backup state
update_backup_state() {
    local db_name="$1"
    local table_name="$2"
    local last_value="$3"
    
    # Remove old entry if exists
    if [[ -f "$STATE_FILE" ]]; then
        grep -v "^${db_name}\.${table_name}:" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE" 2>/dev/null || true
    fi
    
    # Add new entry
    echo "${db_name}.${table_name}:${last_value}" >> "$STATE_FILE"
}

# Backup new rows from a table
backup_table_rows() {
    local db_name="$1"
    local table_name="$2"
    local inc_column="$3"
    local last_value="$4"
    local backup_file="${INCREMENTAL_DIR}/${db_name}_${table_name}_${TIMESTAMP}.sql"
    local compressed_file="${backup_file}.gz"
    
    log "Backing up new rows from ${db_name}.${table_name} (column: $inc_column, after: ${last_value:-"beginning"})"
    
    # Build WHERE clause based on column type
    local where_clause=""
    if [[ -n "$last_value" ]]; then
        # Check if it's numeric (ID) or timestamp
        if [[ "$last_value" =~ ^[0-9]+$ ]]; then
            where_clause="WHERE \`$inc_column\` > $last_value"
        else
            where_clause="WHERE \`$inc_column\` > '$last_value'"
        fi
    fi
    
    # Get new rows count first
    local row_count
    row_count=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$db_name" -e "
        SELECT COUNT(*) FROM \`$table_name\` $where_clause;
    " 2>/dev/null | tail -n +2 || echo "0")
    
    if [[ "$row_count" == "0" ]] || [[ -z "$row_count" ]]; then
        log "No new rows in ${db_name}.${table_name}"
        return 0
    fi
    
    log "Found $row_count new row(s) in ${db_name}.${table_name}"
    
    # Create backup with only new rows
    if ! mysqldump \
        -u"$MYSQL_USER" \
        -p"$MYSQL_PASS" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --no-create-info \
        --skip-triggers \
        --where="$where_clause" \
        "$db_name" "$table_name" > "$backup_file" 2>>"$LOG_FILE"; then
        log_error "Failed to backup new rows from ${db_name}.${table_name}"
        rm -f "$backup_file"
        return 1
    fi
    
    # Check if backup is empty
    if [[ ! -s "$backup_file" ]] || [[ $(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null) -lt 50 ]]; then
        log "No new rows backed up for ${db_name}.${table_name}"
        rm -f "$backup_file"
        return 0
    fi
    
    # Get the maximum value for state tracking
    local max_value
    max_value=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$db_name" -e "
        SELECT MAX(\`$inc_column\`) FROM \`$table_name\`;
    " 2>/dev/null | tail -n +2 || echo "")
    
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
    
    # Update state
    if [[ -n "$max_value" ]]; then
        update_backup_state "$db_name" "$table_name" "$max_value"
    fi
    
    log_success "Backed up $row_count new row(s) from ${db_name}.${table_name}: $(du -h "$compressed_file" | cut -f1)"
    echo "$compressed_file"
    echo "$checksum_file"
    return 0
}

# Process database for row-level incremental backup
process_database() {
    local db_name="$1"
    local backed_up_tables=0
    local backup_files=()
    
    log "Processing database: $db_name"
    
    # Get tables
    local tables
    tables=$(get_tables "$db_name")
    
    if [[ -z "$tables" ]]; then
        log_warning "No tables found in database: $db_name"
        return 0
    fi
    
    # Process each table
    while IFS= read -r table_name; do
        [[ -z "$table_name" ]] && continue
        
        # Detect incremental column
        local inc_column
        inc_column=$(detect_incremental_column "$db_name" "$table_name")
        
        if [[ -z "$inc_column" ]]; then
            log_warning "No suitable incremental column found for ${db_name}.${table_name}, skipping"
            continue
        fi
        
        # Get last backed up value
        local last_value
        last_value=$(get_last_backed_value "$db_name" "$table_name")
        
        # Backup new rows
        local backup_output
        backup_output=$(backup_table_rows "$db_name" "$table_name" "$inc_column" "$last_value" 2>&1)
        local backup_exit=$?
        
        if [[ $backup_exit -eq 0 ]] && [[ -n "$backup_output" ]]; then
            backed_up_tables=$((backed_up_tables + 1))
            
            # Collect backup files
            while IFS= read -r file; do
                [[ -n "$file" ]] && [[ -f "$file" ]] && backup_files+=("$file")
            done <<< "$backup_output"
        fi
    done <<< "$tables"
    
    if [[ $backed_up_tables -eq 0 ]]; then
        log "No new rows found in database: $db_name"
    else
        log_success "Backed up new rows from $backed_up_tables table(s) in $db_name"
    fi
    
    # Return backup files
    for file in "${backup_files[@]}"; do
        echo "$file"
    done
}

# Upload file to FTP with retry logic
upload_to_ftp() {
    local local_file="$1"
    local remote_file="incremental_rows/$(basename "$local_file")"
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
            mkdir -p incremental_rows
            cd incremental_rows
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

# Cleanup old backups
cleanup_old_backups() {
    log "Cleaning up incremental backups older than $RETENTION_HOURS hours"
    find "$INCREMENTAL_DIR" -type f -name "*.sql.gz" -mmin +$((RETENTION_HOURS * 60)) -delete
    find "$INCREMENTAL_DIR" -type f -name "*.sha256" -mmin +$((RETENTION_HOURS * 60)) -delete
    log_success "Cleanup completed"
}

# Main execution
main() {
    log "=========================================="
    log "Row-Level Incremental Backup Process Started"
    log "=========================================="
    
    # Load configuration
    load_config
    
    # Initialize directories
    init_directories
    
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
    
    # Upload backups to FTP
    if [[ ${#backup_files[@]} -gt 0 ]]; then
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
        log "No new rows detected, skipping FTP upload"
    fi
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Summary
    log "=========================================="
    log "Row-Level Incremental Backup Process Completed"
    log "=========================================="
    log "Tables with new rows backed up: $total_backups"
    log "Log file: $LOG_FILE"
    
    if [[ $total_backups -eq 0 ]]; then
        log "No new rows detected since last backup"
    fi
    
    exit 0
}

# Run main function
main "$@"
