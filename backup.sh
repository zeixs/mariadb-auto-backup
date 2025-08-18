#!/bin/bash

# MariaDB Auto-Backup Execution Script
# This script handles validation, checks, and backup execution

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/server_config.json"
LOG_DIR="${SCRIPT_DIR}/logs"

# Source the centralized logging utility
source "${SCRIPT_DIR}/logging_utils.sh"

# Legacy log function for backward compatibility
log() {
    local level="$1"
    shift
    write_log "$level" "$*" "backup.sh"
}

# Pre-execution validation
validate_environment() {
    log_info "Validating environment and configuration"
    
    # Check if configuration exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_info "Run './setup.sh' to create initial configuration"
        return 1
    fi
    
    # Validate configuration
    if ! "${SCRIPT_DIR}/validate_config.sh" validate >/dev/null 2>&1; then
        log_error "Configuration validation failed"
        log_info "Run './validate_config.sh validate' for detailed error information"
        return 1
    fi
    
    log_success "Environment validation passed"
    return 0
}

# Pre-execution checks
perform_checks() {
    log_info "Performing pre-execution system checks"
    
    # Check dependencies
    local missing_deps=()
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v mariadb &> /dev/null && ! command -v mysql &> /dev/null; then
        missing_deps+=("mysql/mariadb")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Run './setup.sh' to install dependencies"
        return 1
    fi
    
    # Check disk space
    local backup_dir="${SCRIPT_DIR}/backups"
    local available_space
    available_space=$(df "$backup_dir" | awk 'NR==2 {print $4}')
    local available_gb=$((available_space / 1024 / 1024))
    
    if [[ $available_gb -lt 1 ]]; then
        log_warning "Low disk space: ${available_gb}GB available in backup directory"
        log_warning "Consider cleaning old backups or increasing storage"
    else
        log_info "Disk space check passed: ${available_gb}GB available"
    fi
    
    # Check if backup is already running
    local lock_file="${SCRIPT_DIR}/backup.lock"
    if [[ -f "$lock_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$lock_file")
        if kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Backup is already running (PID: $lock_pid)"
            return 1
        else
            log_warning "Removing stale lock file"
            rm -f "$lock_file"
        fi
    fi
    
    log_success "Pre-execution checks passed"
    return 0
}

# Execute backup
execute_backup() {
    local backup_type="${1:-auto}"
    local test_mode="${2:-false}"
    
    if [[ "$test_mode" == "true" ]]; then
        log "INFO" "Running in TEST MODE - no actual backup will be performed"
        log "INFO" "Testing backup configuration and connections..."
        
        # Test connections
        if "${SCRIPT_DIR}/validate_config.sh" test; then
            log "INFO" "Connection tests passed"
            
            # Test backup directory creation
            local servers
            servers=$(jq -r 'keys[]' "$CONFIG_FILE")
            while IFS= read -r server; do
                [[ -z "$server" ]] && continue
                local test_dir="${SCRIPT_DIR}/backups/${server}/test"
                if mkdir -p "$test_dir" 2>/dev/null; then
                    rmdir "$test_dir" 2>/dev/null || true
                    log "INFO" "[$server] Backup directory test passed"
                else
                    log "ERROR" "[$server] Cannot create backup directory"
                    return 1
                fi
            done <<< "$servers"
            
            log "INFO" "TEST MODE completed successfully"
            return 0
        else
            log "ERROR" "Connection tests failed"
            return 1
        fi
    fi
    
    log "INFO" "Starting backup execution (type: $backup_type)..."
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Execute the main backup script
    if "${SCRIPT_DIR}/mariadb_backup.sh" "$backup_type"; then
        log "INFO" "Backup execution completed successfully"
        
        # Show backup summary
        show_backup_summary
        
        return 0
    else
        log "ERROR" "Backup execution failed"
        log "INFO" "Check logs: tail -f ${LOG_DIR}/backup_$(date '+%Y%m%d').log"
        return 1
    fi
}

# Show backup summary
show_backup_summary() {
    log "INFO" "Backup Summary:"
    
    local servers
    servers=$(jq -r 'keys[]' "$CONFIG_FILE")
    
    while IFS= read -r server; do
        [[ -z "$server" ]] && continue
        
        local backup_dir="${SCRIPT_DIR}/backups/${server}"
        if [[ -d "$backup_dir" ]]; then
            local db_count
            db_count=$(find "$backup_dir" -type d -mindepth 1 -maxdepth 1 | wc -l)
            local backup_count
            backup_count=$(find "$backup_dir" -name "*.sql.gz" -type f | wc -l)
            local total_size
            total_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
            
            echo "  [$server] $db_count databases, $backup_count backups, $total_size total"
        else
            echo "  [$server] No backups found"
        fi
    done <<< "$servers"
    
    # Show recent log entries
    local today_log="${LOG_DIR}/backup_$(date '+%Y%m%d').log"
    if [[ -f "$today_log" ]]; then
        echo ""
        echo "Recent log entries:"
        tail -n 5 "$today_log" | while read -r line; do
            echo "  $line"
        done
    fi
}

# Show status information
show_status() {
    log "INFO" "MariaDB Auto-Backup Status"
    echo ""
    
    # Configuration status
    if [[ -f "$CONFIG_FILE" ]]; then
        local server_count
        server_count=$(jq -r 'keys | length' "$CONFIG_FILE")
        echo "📋 Configuration: $server_count server(s) configured"
        
        # List servers
        local servers
        servers=$(jq -r 'keys[]' "$CONFIG_FILE")
        while IFS= read -r server; do
            [[ -z "$server" ]] && continue
            local mode
            mode=$(jq -r ".\"$server\".backup_config.mode // \"all\"" "$CONFIG_FILE")
            echo "  • $server (mode: $mode)"
        done <<< "$servers"
    else
        echo "❌ Configuration: Not found"
    fi
    
    echo ""
    
    # Backup status
    local backup_base="${SCRIPT_DIR}/backups"
    if [[ -d "$backup_base" ]]; then
        local total_backups
        total_backups=$(find "$backup_base" -name "*.sql.gz" -type f | wc -l)
        local total_size
        total_size=$(du -sh "$backup_base" 2>/dev/null | cut -f1 || echo "0B")
        echo "💾 Backups: $total_backups files, $total_size total"
        
        # Recent backups
        echo "   Recent backups:"
        find "$backup_base" -name "*.sql.gz" -type f -mtime -1 -exec basename {} \; | head -3 | while read -r backup; do
            [[ -n "$backup" ]] && echo "   • $backup"
        done || echo "   • None in last 24 hours"
    else
        echo "💾 Backups: No backup directory found"
    fi
    
    echo ""
    
    # Cron status
    if crontab -l 2>/dev/null | grep -q "backup.sh"; then
        echo "⏰ Scheduled: Active (daily at midnight)"
        local next_run
        # This is a simplified next run calculation
        local current_hour
        current_hour=$(date '+%H')
        if [[ $current_hour -lt 12 ]]; then
            echo "   Next run: Today at 00:00"
        else
            echo "   Next run: Tomorrow at 00:00"
        fi
    else
        echo "⏰ Scheduled: Not configured"
    fi
    
    echo ""
    
    # Log status
    local today_log="${LOG_DIR}/backup_$(date '+%Y%m%d').log"
    if [[ -f "$today_log" ]]; then
        local log_lines
        log_lines=$(wc -l < "$today_log")
        local last_entry
        last_entry=$(tail -n 1 "$today_log" | cut -d']' -f1 | tr -d '[' || echo "No entries")
        echo "📝 Logs: $log_lines entries today (last: $last_entry)"
    else
        echo "📝 Logs: No activity today"
    fi
}

# Usage information
usage() {
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  run [type]    Run backup (default command)"
    echo "  test          Test backup configuration without execution"
    echo "  status        Show system status"
    echo "  help          Show this help"
    echo ""
    echo "Backup types:"
    echo "  auto          Automatic mode - full on 1st, incremental otherwise (default)"
    echo "  full          Force full backup"
    echo "  incremental   Force incremental backup"
    echo ""
    echo "Options:"
    echo "  --test        Run in test mode (no actual backup)"
    echo ""
    echo "Examples:"
    echo "  $0                    # Run automatic backup"
    echo "  $0 run full           # Run full backup"
    echo "  $0 test               # Test configuration"
    echo "  $0 status             # Show status"
    echo "  $0 --test             # Test backup without execution"
}

# Main function
main() {
    local command="run"
    local backup_type="auto"
    local test_mode=false
    
    # Start logging session
    log_session_start "backup.sh" "Command: $* (PID: $$)"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            run)
                command="run"
                shift
                if [[ $# -gt 0 ]] && [[ "$1" =~ ^(auto|full|incremental)$ ]]; then
                    backup_type="$1"
                    shift
                fi
                ;;
            test)
                command="test"
                shift
                ;;
            status)
                command="status"
                shift
                ;;
            --test)
                test_mode=true
                shift
                ;;
            help|--help|-h)
                usage
                log_session_end "backup.sh" 0
                exit 0
                ;;
            auto|full|incremental)
                backup_type="$1"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                log_session_end "backup.sh" 1
                exit 1
                ;;
        esac
    done
    
    local exit_code=0
    
    case "$command" in
        "run")
            # Validate environment
            if ! validate_environment; then
                log_session_end "backup.sh" 1
                exit 1
            fi
            
            # Perform checks
            if ! perform_checks; then
                log_session_end "backup.sh" 1
                exit 1
            fi
            
            # Execute backup
            if ! execute_backup "$backup_type" "$test_mode"; then
                log_session_end "backup.sh" 1
                exit 1
            fi
            ;;
        "test")
            # Validate environment
            if ! validate_environment; then
                log_session_end "backup.sh" 1
                exit 1
            fi
            
            # Perform checks
            if ! perform_checks; then
                log_session_end "backup.sh" 1
                exit 1
            fi
            
            # Execute in test mode
            if ! execute_backup "auto" true; then
                log_session_end "backup.sh" 1
                exit 1
            fi
            ;;
        "status")
            show_status
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            log_session_end "backup.sh" 1
            exit 1
            ;;
    esac
    
    log_session_end "backup.sh" $exit_code
}

main "$@"
