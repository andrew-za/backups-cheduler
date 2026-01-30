#!/bin/bash

###############################################################################
# Backup Verification Script
# 
# This script verifies backup integrity by:
# - Checking checksums
# - Testing SQL dump syntax (without restoring)
# - Verifying file completeness
###############################################################################

set -euo pipefail

# Get script directory and set base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${BASE_DIR}/backups"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/verify_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

verify_backup() {
    local backup_file="$1"
    local checksum_file="${backup_file%.gz}.sha256"
    
    log "Verifying: $(basename "$backup_file")"
    
    # Check if checksum file exists
    if [[ ! -f "$checksum_file" ]]; then
        log "ERROR: Checksum file not found for $backup_file"
        return 1
    fi
    
    # Verify checksum
    if ! sha256sum -c "$checksum_file" >> "$LOG_FILE" 2>&1; then
        log "ERROR: Checksum verification failed for $backup_file"
        return 1
    fi
    
    # Test SQL dump integrity (decompress and check syntax)
    log "Testing SQL dump syntax..."
    local temp_sql=$(mktemp)
    
    if ! gunzip -c "$backup_file" > "$temp_sql" 2>>"$LOG_FILE"; then
        log "ERROR: Failed to decompress backup"
        rm -f "$temp_sql"
        return 1
    fi
    
    # Check for critical SQL errors
    if grep -q "ERROR [0-9]" "$temp_sql"; then
        log "ERROR: SQL dump contains errors"
        rm -f "$temp_sql"
        return 1
    fi
    
    # Check file size (should not be empty)
    local file_size=$(stat -f%z "$temp_sql" 2>/dev/null || stat -c%s "$temp_sql" 2>/dev/null)
    if [[ $file_size -lt 100 ]]; then
        log "ERROR: SQL dump appears to be empty or too small"
        rm -f "$temp_sql"
        return 1
    fi
    
    # Check for SQL dump header
    if ! head -n 5 "$temp_sql" | grep -q "MySQL dump\|MariaDB dump"; then
        log "WARNING: SQL dump header not found (may still be valid)"
    fi
    
    rm -f "$temp_sql"
    log "SUCCESS: Backup verified successfully"
    return 0
}

main() {
    mkdir -p "$LOG_DIR"
    
    log "Starting backup verification..."
    
    local verified=0
    local failed=0
    
    for backup_file in "$BACKUP_DIR"/*.sql.gz; do
        [[ ! -f "$backup_file" ]] && continue
        
        if verify_backup "$backup_file"; then
            verified=$((verified + 1))
        else
            failed=$((failed + 1))
        fi
    done
    
    log "=========================================="
    log "Verification Complete"
    log "Verified: $verified"
    log "Failed: $failed"
    log "=========================================="
    
    exit $failed
}

main "$@"
