#!/bin/bash

###############################################################################
# Configuration Utilities
# 
# Shared functions for loading and validating backup configuration
###############################################################################

# Load and validate configuration with defaults
load_backup_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: $config_file" >&2
        return 1
    fi
    
    # Source the config file
    source "$config_file"
    
    # Validate required variables
    local required_vars=("MYSQL_USER" "MYSQL_PASS" "FTP_HOST" "FTP_USER" "FTP_PASS" "FTP_DIR")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: Required configuration variable not set: $var" >&2
            return 1
        fi
    done
    
    # Set defaults for optional variables
    INCREMENTAL_BACKUPS_ENABLED="${INCREMENTAL_BACKUPS_ENABLED:-true}"
    INCREMENTAL_METHOD="${INCREMENTAL_METHOD:-binary_logs}"
    INCREMENTAL_UPLOAD_FTP="${INCREMENTAL_UPLOAD_FTP:-true}"
    INCREMENTAL_RETENTION_HOURS="${INCREMENTAL_RETENTION_HOURS:-168}"
    INCREMENTAL_DATABASES="${INCREMENTAL_DATABASES:-}"
    COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-9}"
    LOG_VERBOSITY="${LOG_VERBOSITY:-normal}"
    FULL_BACKUP_UPLOAD_FTP="${FULL_BACKUP_UPLOAD_FTP:-true}"
    RETENTION_DAYS="${RETENTION_DAYS:-30}"
    BINLOG_BACKUP_INTERVAL_MINUTES="${BINLOG_BACKUP_INTERVAL_MINUTES:-15}"
    BINLOG_RETENTION_DAYS="${BINLOG_RETENTION_DAYS:-7}"
    
    # Resource monitoring defaults
    ENABLE_RESOURCE_CHECKS="${ENABLE_RESOURCE_CHECKS:-true}"
    CPU_LOAD_THRESHOLD="${CPU_LOAD_THRESHOLD:-2.0}"
    MEMORY_USAGE_THRESHOLD="${MEMORY_USAGE_THRESHOLD:-85}"
    DISK_IO_WAIT_THRESHOLD="${DISK_IO_WAIT_THRESHOLD:-50}"
    DISK_SPACE_THRESHOLD="${DISK_SPACE_THRESHOLD:-10}"
    MYSQL_CONNECTIONS_THRESHOLD="${MYSQL_CONNECTIONS_THRESHOLD:-80}"
    RESOURCE_WAIT_MAX_MINUTES="${RESOURCE_WAIT_MAX_MINUTES:-30}"
    RESOURCE_CHECK_INTERVAL="${RESOURCE_CHECK_INTERVAL:-60}"
    
    # Normalize boolean values (case-insensitive)
    INCREMENTAL_BACKUPS_ENABLED=$(echo "${INCREMENTAL_BACKUPS_ENABLED}" | tr '[:upper:]' '[:lower:]')
    INCREMENTAL_UPLOAD_FTP=$(echo "${INCREMENTAL_UPLOAD_FTP}" | tr '[:upper:]' '[:lower:]')
    FULL_BACKUP_UPLOAD_FTP=$(echo "${FULL_BACKUP_UPLOAD_FTP}" | tr '[:upper:]' '[:lower:]')
    
    # Convert retention days to hours if needed
    if [[ -n "${INCREMENTAL_RETENTION_DAYS:-}" ]]; then
        INCREMENTAL_RETENTION_HOURS=$((INCREMENTAL_RETENTION_DAYS * 24))
    fi
    
    return 0
}

# Check if incremental backups are enabled
is_incremental_enabled() {
    [[ "$INCREMENTAL_BACKUPS_ENABLED" == "true" ]]
}

# Check if FTP upload is enabled for incremental backups
should_upload_incremental_ftp() {
    [[ "$INCREMENTAL_UPLOAD_FTP" == "true" ]]
}

# Check if FTP upload is enabled for full backups
should_upload_full_ftp() {
    [[ "$FULL_BACKUP_UPLOAD_FTP" == "true" ]]
}

# Filter databases based on INCREMENTAL_DATABASES configuration
filter_databases_for_incremental() {
    local databases="$1"
    local filtered_dbs=()
    
    # If no filter specified, return all databases
    if [[ -z "$INCREMENTAL_DATABASES" ]]; then
        echo "$databases"
        return 0
    fi
    
    # Parse the filter
    local filter_mode=""
    local filter_list=""
    
    if [[ "$INCREMENTAL_DATABASES" =~ ^\+ ]]; then
        # Include mode: only specified databases
        filter_mode="include"
        filter_list="${INCREMENTAL_DATABASES#+}"
    elif [[ "$INCREMENTAL_DATABASES" =~ ^\- ]]; then
        # Exclude mode: all except specified databases
        filter_mode="exclude"
        filter_list="${INCREMENTAL_DATABASES#-}"
    else
        # Default to include if no prefix
        filter_mode="include"
        filter_list="$INCREMENTAL_DATABASES"
    fi
    
    # Convert comma-separated list to array
    IFS=',' read -ra FILTER_ARRAY <<< "$filter_list"
    
    # Process each database
    while IFS= read -r db_name; do
        [[ -z "$db_name" ]] && continue
        
        local should_include=false
        
        if [[ "$filter_mode" == "include" ]]; then
            # Check if database is in include list
            for filter_db in "${FILTER_ARRAY[@]}"; do
                filter_db=$(echo "$filter_db" | xargs)  # Trim whitespace
                if [[ "$db_name" == "$filter_db" ]]; then
                    should_include=true
                    break
                fi
            done
        else
            # Exclude mode: include unless in exclude list
            should_include=true
            for filter_db in "${FILTER_ARRAY[@]}"; do
                filter_db=$(echo "$filter_db" | xargs)  # Trim whitespace
                if [[ "$db_name" == "$filter_db" ]]; then
                    should_include=false
                    break
                fi
            done
        fi
        
        if [[ "$should_include" == "true" ]]; then
            filtered_dbs+=("$db_name")
        fi
    done <<< "$databases"
    
    # Output filtered databases
    for db in "${filtered_dbs[@]}"; do
        echo "$db"
    done
}

# Get compression command with level
get_compression_cmd() {
    local level="${COMPRESSION_LEVEL:-9}"
    echo "gzip -${level}"
}

# Check if database should be backed up incrementally
should_backup_database_incremental() {
    local db_name="$1"
    local all_databases="$2"
    
    # If incremental backups disabled, return false
    if ! is_incremental_enabled; then
        return 1
    fi
    
    # Filter databases
    local filtered
    filtered=$(filter_databases_for_incremental "$all_databases")
    
    # Check if database is in filtered list
    while IFS= read -r filtered_db; do
        [[ -z "$filtered_db" ]] && continue
        if [[ "$filtered_db" == "$db_name" ]]; then
            return 0
        fi
    done <<< "$filtered"
    
    return 1
}
