#!/bin/bash

###############################################################################
# Resource Monitor for Backup Scripts
# 
# Monitors server resources and determines if it's safe to run backups
# Can pause operations if server is under high load
###############################################################################

# Default thresholds (can be overridden by config)
CPU_LOAD_THRESHOLD="${CPU_LOAD_THRESHOLD:-2.0}"  # Load average per CPU core
MEMORY_USAGE_THRESHOLD="${MEMORY_USAGE_THRESHOLD:-85}"  # Percentage
DISK_IO_WAIT_THRESHOLD="${DISK_IO_WAIT_THRESHOLD:-50}"  # Percentage
DISK_SPACE_THRESHOLD="${DISK_SPACE_THRESHOLD:-10}"  # Percentage free
MYSQL_CONNECTIONS_THRESHOLD="${MYSQL_CONNECTIONS_THRESHOLD:-80}"  # Percentage of max_connections
ENABLE_RESOURCE_CHECKS="${ENABLE_RESOURCE_CHECKS:-true}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Get number of CPU cores
get_cpu_cores() {
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1"
}

# Check CPU load average
check_cpu_load() {
    local cores
    cores=$(get_cpu_cores)
    local load_1min
    load_1min=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    
    if [[ -z "$load_1min" ]] || [[ "$load_1min" == "0.00" ]]; then
        # Fallback method
        load_1min=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' || echo "0")
    fi
    
    local load_per_core
    load_per_core=$(echo "scale=2; $load_1min / $cores" | bc 2>/dev/null || awk "BEGIN {printf \"%.2f\", $load_1min / $cores}")
    
    echo "$load_per_core"
}

# Check memory usage
check_memory_usage() {
    local mem_info
    mem_info=$(free 2>/dev/null | grep Mem || echo "")
    
    if [[ -z "$mem_info" ]]; then
        echo "0"
        return
    fi
    
    local total_mem used_mem
    total_mem=$(echo "$mem_info" | awk '{print $2}')
    used_mem=$(echo "$mem_info" | awk '{print $3}')
    
    if [[ "$total_mem" -eq 0 ]]; then
        echo "0"
        return
    fi
    
    local usage_percent
    usage_percent=$(echo "scale=2; ($used_mem / $total_mem) * 100" | bc 2>/dev/null || \
        awk "BEGIN {printf \"%.0f\", ($used_mem / $total_mem) * 100}")
    
    echo "$usage_percent"
}

# Check disk I/O wait
check_disk_io_wait() {
    # Use iostat if available, otherwise use /proc/stat
    if command -v iostat >/dev/null 2>&1; then
        local io_wait
        io_wait=$(iostat -c 1 2 2>/dev/null | tail -n +4 | awk '{sum+=$6; count++} END {if(count>0) print sum/count; else print "0"}')
        echo "${io_wait:-0}"
    else
        # Fallback: check /proc/stat
        local cpu_stat
        cpu_stat=$(grep '^cpu ' /proc/stat 2>/dev/null || echo "")
        if [[ -n "$cpu_stat" ]]; then
            local total idle iowait
            total=$(echo "$cpu_stat" | awk '{sum=$2+$3+$4+$5+$6+$7+$8; print sum}')
            idle=$(echo "$cpu_stat" | awk '{print $5}')
            iowait=$(echo "$cpu_stat" | awk '{print $6}')
            
            if [[ "$total" -gt 0 ]]; then
                local io_wait_percent
                io_wait_percent=$(echo "scale=2; ($iowait / $total) * 100" | bc 2>/dev/null || \
                    awk "BEGIN {printf \"%.2f\", ($iowait / $total) * 100}")
                echo "$io_wait_percent"
            else
                echo "0"
            fi
        else
            echo "0"
        fi
    fi
}

# Check disk space for backup directory
check_disk_space() {
    local backup_dir="$1"
    local df_output
    df_output=$(df "$backup_dir" 2>/dev/null | tail -n 1 || echo "")
    
    if [[ -z "$df_output" ]]; then
        echo "0"
        return
    fi
    
    local usage_percent
    usage_percent=$(echo "$df_output" | awk '{print $5}' | sed 's/%//')
    local free_percent
    free_percent=$((100 - usage_percent))
    
    echo "$free_percent"
}

# Check MySQL connection usage
check_mysql_connections() {
    local mysql_user="${MYSQL_USER:-root}"
    local mysql_pass="${MYSQL_PASS:-}"
    
    if [[ -z "$mysql_user" ]]; then
        echo "0"
        return
    fi
    
    local max_conn current_conn
    max_conn=$(mysql -u"$mysql_user" -p"$mysql_pass" -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | \
        grep max_connections | awk '{print $2}' || echo "0")
    
    current_conn=$(mysql -u"$mysql_user" -p"$mysql_pass" -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null | \
        grep Threads_connected | awk '{print $2}' || echo "0")
    
    if [[ "$max_conn" -eq 0 ]]; then
        echo "0"
        return
    fi
    
    local usage_percent
    usage_percent=$(echo "scale=2; ($current_conn / $max_conn) * 100" | bc 2>/dev/null || \
        awk "BEGIN {printf \"%.0f\", ($current_conn / $max_conn) * 100}")
    
    echo "$usage_percent"
}

# Check if MySQL is responsive
check_mysql_health() {
    local mysql_user="${MYSQL_USER:-root}"
    local mysql_pass="${MYSQL_PASS:-}"
    
    if mysql -u"$mysql_user" -p"$mysql_pass" -e "SELECT 1;" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Comprehensive resource check
check_resources() {
    local backup_dir="${1:-/tmp}"
    local verbose="${2:-false}"
    
    if [[ "$ENABLE_RESOURCE_CHECKS" != "true" ]]; then
        if [[ "$verbose" == "true" ]]; then
            log "Resource checks disabled in configuration"
        fi
        return 0
    fi
    
    local issues=0
    local warnings=0
    
    # Check CPU load
    local cpu_load
    cpu_load=$(check_cpu_load)
    local cpu_threshold
    cpu_threshold=$(echo "$CPU_LOAD_THRESHOLD" | bc 2>/dev/null || echo "$CPU_LOAD_THRESHOLD")
    
    if (( $(echo "$cpu_load > $cpu_threshold" | bc -l 2>/dev/null || echo "0") )); then
        log_warning "High CPU load detected: ${cpu_load} (threshold: ${cpu_threshold})"
        issues=$((issues + 1))
    elif [[ "$verbose" == "true" ]]; then
        log "CPU load: ${cpu_load} (threshold: ${cpu_threshold}) ✓"
    fi
    
    # Check memory usage
    local mem_usage
    mem_usage=$(check_memory_usage)
    if (( $(echo "$mem_usage > $MEMORY_USAGE_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
        log_warning "High memory usage: ${mem_usage}% (threshold: ${MEMORY_USAGE_THRESHOLD}%)"
        issues=$((issues + 1))
    elif [[ "$verbose" == "true" ]]; then
        log "Memory usage: ${mem_usage}% (threshold: ${MEMORY_USAGE_THRESHOLD}%) ✓"
    fi
    
    # Check disk I/O wait
    local io_wait
    io_wait=$(check_disk_io_wait)
    if (( $(echo "$io_wait > $DISK_IO_WAIT_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
        log_warning "High disk I/O wait: ${io_wait}% (threshold: ${DISK_IO_WAIT_THRESHOLD}%)"
        warnings=$((warnings + 1))
    elif [[ "$verbose" == "true" ]]; then
        log "Disk I/O wait: ${io_wait}% (threshold: ${DISK_IO_WAIT_THRESHOLD}%) ✓"
    fi
    
    # Check disk space
    local disk_free
    disk_free=$(check_disk_space "$backup_dir")
    if (( $(echo "$disk_free < $DISK_SPACE_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
        log_error "Low disk space: ${disk_free}% free (threshold: ${DISK_SPACE_THRESHOLD}%)"
        issues=$((issues + 1))
    elif [[ "$verbose" == "true" ]]; then
        log "Disk space: ${disk_free}% free (threshold: ${DISK_SPACE_THRESHOLD}%) ✓"
    fi
    
    # Check MySQL connections
    local mysql_conn_usage
    mysql_conn_usage=$(check_mysql_connections)
    if (( $(echo "$mysql_conn_usage > $MYSQL_CONNECTIONS_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
        log_warning "High MySQL connection usage: ${mysql_conn_usage}% (threshold: ${MYSQL_CONNECTIONS_THRESHOLD}%)"
        warnings=$((warnings + 1))
    elif [[ "$verbose" == "true" ]]; then
        log "MySQL connections: ${mysql_conn_usage}% (threshold: ${MYSQL_CONNECTIONS_THRESHOLD}%) ✓"
    fi
    
    # Check MySQL health
    if ! check_mysql_health; then
        log_error "MySQL is not responding"
        issues=$((issues + 1))
    elif [[ "$verbose" == "true" ]]; then
        log "MySQL health: OK ✓"
    fi
    
    # Return status
    if [[ $issues -gt 0 ]]; then
        return 1  # Critical issues
    elif [[ $warnings -gt 0 ]]; then
        return 2  # Warnings only
    else
        return 0  # All OK
    fi
}

# Wait for resources to become available
wait_for_resources() {
    local backup_dir="${1:-/tmp}"
    local max_wait_minutes="${RESOURCE_WAIT_MAX_MINUTES:-30}"
    local check_interval="${RESOURCE_CHECK_INTERVAL:-60}"  # seconds
    
    local waited=0
    local max_wait_seconds=$((max_wait_minutes * 60))
    
    log "Checking server resources before backup..."
    
    while [[ $waited -lt $max_wait_seconds ]]; do
        check_resources "$backup_dir" "false"
        local status=$?
        
        if [[ $status -eq 0 ]]; then
            log_success "Resources available, proceeding with backup"
            return 0
        elif [[ $status -eq 2 ]]; then
            log_warning "Resources have warnings but proceeding..."
            return 0
        else
            log_warning "Server under high load, waiting ${check_interval}s before retry... (waited: ${waited}s / ${max_wait_seconds}s)"
            sleep "$check_interval"
            waited=$((waited + check_interval))
        fi
    done
    
    log_error "Timeout waiting for resources to become available (waited ${max_wait_minutes} minutes)"
    return 1
}

# Main function for direct script execution
main() {
    local backup_dir="${1:-/tmp}"
    local action="${2:-check}"
    
    case "$action" in
        check)
            check_resources "$backup_dir" "true"
            exit $?
            ;;
        wait)
            wait_for_resources "$backup_dir"
            exit $?
            ;;
        *)
            echo "Usage: $0 <backup_dir> [check|wait]"
            exit 1
            ;;
    esac
}

# If script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
