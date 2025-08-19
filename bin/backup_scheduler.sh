#!/bin/bash

# Backup Scheduler - Handles scheduled full backups and cleanup
# Usage: ./backup_scheduler.sh [check|force-full|cleanup]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/logging_utils.sh"

CONFIG_FILE="$SCRIPT_DIR/conf/server_config.json"

# Source only the validation function we need
validate_config_file() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "Configuration file not found: $config_file"
        return 1
    fi
    
    if ! jq empty "$config_file" 2>/dev/null; then
        log "ERROR" "Invalid JSON in configuration file: $config_file"
        return 1
    fi
    
    return 0
}

# Parse command line arguments
ACTION="${1:-check}"

# Initialize logging
log() {
    local level="$1"
    shift
    write_log "$level" "$*" "backup_scheduler"
}

log_session_start "backup_scheduler.sh" "Action: $ACTION"

# Function to parse interval string to seconds
parse_interval() {
    local interval="$1"
    case "$interval" in
        "manual"|"") echo "0" ;;
        *d) echo "$((${interval%d} * 86400))" ;;
        *h) echo "$((${interval%h} * 3600))" ;;
        *m) echo "$((${interval%m} * 60))" ;;
        *) 
            log "ERROR" "Invalid interval format: $interval. Use format like '7d', '24h', '60m', or 'manual'"
            exit 1
            ;;
    esac
}

# Function to get last full backup timestamp
get_last_full_backup_time() {
    local server_name="$1"
    local database="$2"
    local backup_path="$3"
    
    local backup_dir="$backup_path/$server_name/$database"
    local last_full_file="$backup_dir/.last_full_backup"
    
    if [[ -f "$last_full_file" ]]; then
        local backup_date_str
        backup_date_str=$(cat "$last_full_file" 2>/dev/null || echo "")
        
        if [[ -n "$backup_date_str" ]]; then
            # Convert from format YYYYMMDD_HHMMSS to Unix timestamp
            local year="${backup_date_str:0:4}"
            local month="${backup_date_str:4:2}"
            local day="${backup_date_str:6:2}"
            local hour="${backup_date_str:9:2}"
            local minute="${backup_date_str:11:2}"
            local second="${backup_date_str:13:2}"
            
            # Use date command to convert to Unix timestamp
            local timestamp
            timestamp=$(date -j -f "%Y%m%d_%H%M%S" "$backup_date_str" "+%s" 2>/dev/null || echo "0")
            echo "$timestamp"
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# Function to check if full backup is needed
needs_full_backup() {
    local server_name="$1"
    local config="$2"
    
    # Get schedule configuration
    local interval
    interval=$(echo "$config" | jq -r --arg server "$server_name" '.[$server].schedule.full_backup_interval // "manual"')
    
    if [[ "$interval" == "manual" || "$interval" == "" ]]; then
        log "DEBUG" "[$server_name] Full backup interval set to manual - no automatic scheduling"
        return 1
    fi
    
    local interval_seconds
    interval_seconds=$(parse_interval "$interval")
    
    if [[ "$interval_seconds" -eq 0 ]]; then
        return 1
    fi
    
    # Get backup path
    local backup_path
    backup_path=$(echo "$config" | jq -r --arg server "$server_name" '.[$server].backup_path // "backups"')
    
    # Check each database
    local databases
    databases=$(echo "$config" | jq -r --arg server "$server_name" '.[$server].backup_config.databases[]? // empty')
    
    if [[ -z "$databases" ]]; then
        log "DEBUG" "[$server_name] No specific databases configured, checking all databases"
        return 0  # If no specific databases, assume we need to check
    fi
    
    local current_time
    current_time=$(date +%s)
    
    while read -r database; do
        [[ -z "$database" ]] && continue
        
        local last_backup_time
        last_backup_time=$(get_last_full_backup_time "$server_name" "$database" "$backup_path")
        
        local time_since_backup=$((current_time - last_backup_time))
        
        if [[ "$time_since_backup" -ge "$interval_seconds" ]]; then
            local last_backup_date
            if [[ "$last_backup_time" -gt 0 ]]; then
                last_backup_date=$(date -r "$last_backup_time" 2>/dev/null || echo "unknown")
            else
                last_backup_date="never"
            fi
            log "INFO" "[$server_name] Database '$database' needs full backup (last backup: $last_backup_date)"
            return 0
        fi
    done <<< "$databases"
    
    log "DEBUG" "[$server_name] All databases are up to date with full backup schedule"
    return 1
}

# Function to perform cleanup
perform_cleanup() {
    local server_name="$1"
    local config="$2"
    
    # Check if cleanup is enabled
    local cleanup_enabled
    cleanup_enabled=$(echo "$config" | jq -r --arg server "$server_name" '.[$server].cleanup.enabled // false')
    
    if [[ "$cleanup_enabled" != "true" ]]; then
        log "DEBUG" "[$server_name] Cleanup is disabled"
        return 0
    fi
    
    # Get cleanup configuration
    local min_full_backups
    local max_age_days
    min_full_backups=$(echo "$config" | jq -r --arg server "$server_name" '.[$server].cleanup.min_full_backups // 2')
    max_age_days=$(echo "$config" | jq -r --arg server "$server_name" '.[$server].cleanup.max_age_days // 30')
    
    # Get backup path
    local backup_path
    backup_path=$(echo "$config" | jq -r --arg server "$server_name" '.[$server].backup_path // "backups"')
    
    local server_backup_dir="$backup_path/$server_name"
    
    if [[ ! -d "$server_backup_dir" ]]; then
        log "DEBUG" "[$server_name] No backup directory found: $server_backup_dir"
        return 0
    fi
    
    log "INFO" "[$server_name] Starting cleanup (keep >= $min_full_backups full backups, delete > $max_age_days days old)"
    
    local cleanup_count=0
    local cutoff_date
    cutoff_date=$(date -v-${max_age_days}d +%s)
    
    # Process each database directory
    find "$server_backup_dir" -mindepth 1 -maxdepth 1 -type d | while read -r db_dir; do
        local database
        database=$(basename "$db_dir")
        
        log "DEBUG" "[$server_name] Cleaning up database: $database"
        
        # Find all full backup files sorted by modification time (newest first)
        local full_backups
        full_backups=$(find "$db_dir" -name "full_backup_*.sql.gz" -exec stat -f "%m %N" {} \; | sort -nr)
        
        if [[ -z "$full_backups" ]]; then
            log "DEBUG" "[$server_name] No full backups found for database: $database"
            continue
        fi
        
        local full_backup_count=0
        
        while read -r timestamp filepath; do
            [[ -z "$timestamp" || -z "$filepath" ]] && continue
            
            full_backup_count=$((full_backup_count + 1))
            
            # Keep minimum number of full backups regardless of age
            if [[ "$full_backup_count" -le "$min_full_backups" ]]; then
                log "DEBUG" "[$server_name] Keeping full backup (required): $(basename "$filepath")"
                continue
            fi
            
            # Check if backup is older than max age
            local timestamp_int
            timestamp_int=${timestamp%.*}  # Remove decimal part if present
            
            if [[ "$timestamp_int" -lt "$cutoff_date" ]]; then
                log "INFO" "[$server_name] Deleting old full backup: $(basename "$filepath") (age: $max_age_days+ days)"
                rm -f "$filepath"
                cleanup_count=$((cleanup_count + 1))
                
                # Also clean up related incremental backups
                local backup_date
                backup_date=$(basename "$filepath" | sed 's/full_backup_.*_\([0-9]*_[0-9]*\)\.sql\.gz/\1/')
                
                if [[ -n "$backup_date" ]]; then
                    find "$db_dir" -name "incremental_backup_*_${backup_date}*.sql.gz" -delete 2>/dev/null || true
                fi
            else
                log "DEBUG" "[$server_name] Keeping full backup (within age limit): $(basename "$filepath")"
            fi
        done <<< "$full_backups"
        
        # Clean up orphaned incremental backups (those without corresponding full backups)
        find "$db_dir" -name "incremental_backup_*.sql.gz" | while read -r inc_backup; do
            local inc_basename
            inc_basename=$(basename "$inc_backup")
            local inc_date
            inc_date=$(echo "$inc_basename" | sed 's/incremental_backup_.*_\([0-9]*_[0-9]*\)\.sql\.gz/\1/')
            
            if [[ -n "$inc_date" ]]; then
                # Check if corresponding full backup exists
                if ! find "$db_dir" -name "full_backup_*_${inc_date}*.sql.gz" | grep -q .; then
                    log "INFO" "[$server_name] Deleting orphaned incremental backup: $inc_basename"
                    rm -f "$inc_backup"
                    cleanup_count=$((cleanup_count + 1))
                fi
            fi
        done
    done
    
    if [[ "$cleanup_count" -gt 0 ]]; then
        log "SUCCESS" "[$server_name] Cleanup completed: removed $cleanup_count backup files"
    else
        log "INFO" "[$server_name] Cleanup completed: no files to remove"
    fi
}

# Function to run scheduled backups
check_and_run_backups() {
    local config
    if ! config=$(cat "$CONFIG_FILE"); then
        log "ERROR" "Failed to read configuration file: $CONFIG_FILE"
        exit 1
    fi
    
    if ! validate_config_file "$CONFIG_FILE"; then
        log "ERROR" "Configuration validation failed"
        exit 1
    fi
    
    # Get list of servers
    local servers
    servers=$(echo "$config" | jq -r 'keys[]')
    
    local backup_needed=false
    
    while read -r server_name; do
        [[ -z "$server_name" ]] && continue
        
        log "INFO" "Checking backup schedule for server: $server_name"
        
        if needs_full_backup "$server_name" "$config"; then
            log "INFO" "[$server_name] Running scheduled full backup"
            if "$SCRIPT_DIR/lib/mariadb_backup.sh" full "$server_name"; then
                log "SUCCESS" "[$server_name] Scheduled full backup completed"
                backup_needed=true
            else
                log "ERROR" "[$server_name] Scheduled full backup failed"
            fi
        fi
        
        # Run cleanup after backup
        perform_cleanup "$server_name" "$config"
        
    done <<< "$servers"
    
    if [[ "$backup_needed" == "false" ]]; then
        log "INFO" "No scheduled backups needed at this time"
    fi
}

# Function to force full backup for all servers
force_full_backup() {
    local config
    if ! config=$(cat "$CONFIG_FILE"); then
        log "ERROR" "Failed to read configuration file: $CONFIG_FILE"
        exit 1
    fi
    
    log "INFO" "Forcing full backup for all servers"
    
    if "$SCRIPT_DIR/lib/mariadb_backup.sh" full; then
        log "SUCCESS" "Forced full backup completed"
    else
        log "ERROR" "Forced full backup failed"
        exit 1
    fi
}

# Function to run cleanup only
cleanup_only() {
    local config
    if ! config=$(cat "$CONFIG_FILE"); then
        log "ERROR" "Failed to read configuration file: $CONFIG_FILE"
        exit 1
    fi
    
    local servers
    servers=$(echo "$config" | jq -r 'keys[]')
    
    while read -r server_name; do
        [[ -z "$server_name" ]] && continue
        log "INFO" "Running cleanup for server: $server_name"
        perform_cleanup "$server_name" "$config"
    done <<< "$servers"
}

# Main execution
case "$ACTION" in
    "check")
        log "INFO" "Checking backup schedules and running cleanup"
        check_and_run_backups
        ;;
    "force-full")
        log "INFO" "Forcing full backup for all servers"
        force_full_backup
        ;;
    "cleanup")
        log "INFO" "Running cleanup only"
        cleanup_only
        ;;
    *)
        log "ERROR" "Invalid action: $ACTION"
        echo "Usage: $0 [check|force-full|cleanup]"
        echo "  check      - Check schedules and run backups if needed (default)"
        echo "  force-full - Force full backup for all servers"
        echo "  cleanup    - Run cleanup only"
        exit 1
        ;;
esac

log_session_end "backup_scheduler.sh" 0
