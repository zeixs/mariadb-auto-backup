#!/bin/bash

# Centralized Logging Utility for MariaDB Auto-Backup System
# This script provides consistent logging across all backup scripts

# Get the directory where this script is located
LOGGING_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOGGING_SCRIPT_DIR}/../logs"

# Ensure logs directory exists
mkdir -p "$LOG_DIR"

# Log file paths
ERROR_LOG="${LOG_DIR}/error.log"
SUCCESS_LOG="${LOG_DIR}/success.log"
WARNING_LOG="${LOG_DIR}/warning.log"
INFO_LOG="${LOG_DIR}/info.log"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to get the calling script name
get_caller_script() {
    local caller_script=""
    
    # Check the call stack to find the script that called this function
    for ((i=1; i<${#BASH_SOURCE[@]}; i++)); do
        local source_file="${BASH_SOURCE[$i]}"
        if [[ "$source_file" != "${BASH_SOURCE[0]}" && "$source_file" != *"logging_utils.sh" ]]; then
            caller_script=$(basename "$source_file")
            break
        fi
    done
    
    # If we couldn't determine from BASH_SOURCE, use a fallback
    if [[ -z "$caller_script" ]]; then
        caller_script="unknown"
    fi
    
    echo "$caller_script"
}

# Function to format log entry
format_log_entry() {
    local level="$1"
    local message="$2"
    local script_name="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] [$script_name] $message"
}

# Main logging function
write_log() {
    local level="$1"
    local message="$2"
    local script_name="${3:-$(get_caller_script)}"
    local show_terminal="${4:-true}"
    
    local log_entry
    log_entry=$(format_log_entry "$level" "$message" "$script_name")
    
    # Write to appropriate log file based on level
    case "$level" in
        "ERROR")
            echo "$log_entry" >> "$ERROR_LOG"
            if [[ "$show_terminal" == "true" ]]; then
                echo -e "${RED}[ERROR]${NC} ${CYAN}[$script_name]${NC} $message" >&2
            fi
            ;;
        "SUCCESS")
            echo "$log_entry" >> "$SUCCESS_LOG"
            if [[ "$show_terminal" == "true" ]]; then
                echo -e "${GREEN}[SUCCESS]${NC} ${CYAN}[$script_name]${NC} $message" >&2
            fi
            ;;
        "WARN"|"WARNING")
            echo "$log_entry" >> "$WARNING_LOG"
            if [[ "$show_terminal" == "true" ]]; then
                echo -e "${YELLOW}[WARN]${NC} ${CYAN}[$script_name]${NC} $message" >&2
            fi
            ;;
        "INFO")
            echo "$log_entry" >> "$INFO_LOG"
            if [[ "$show_terminal" == "true" ]]; then
                echo -e "${BLUE}[INFO]${NC} ${CYAN}[$script_name]${NC} $message" >&2
            fi
            ;;
        "DEBUG")
            # Debug messages only go to info log and are less prominent in terminal
            echo "$log_entry" >> "$INFO_LOG"
            if [[ "$show_terminal" == "true" && "${DEBUG_MODE:-false}" == "true" ]]; then
                echo -e "${CYAN}[DEBUG]${NC} ${CYAN}[$script_name]${NC} $message" >&2
            fi
            ;;
    esac
}

# Convenience functions for different log levels
log_error() {
    write_log "ERROR" "$1" "${2:-$(get_caller_script)}" "${3:-true}"
}

log_success() {
    write_log "SUCCESS" "$1" "${2:-$(get_caller_script)}" "${3:-true}"
}

log_warning() {
    write_log "WARN" "$1" "${2:-$(get_caller_script)}" "${3:-true}"
}

log_info() {
    write_log "INFO" "$1" "${2:-$(get_caller_script)}" "${3:-true}"
}

log_debug() {
    write_log "DEBUG" "$1" "${2:-$(get_caller_script)}" "${3:-true}"
}

# Function to log command execution with results
log_command() {
    local command="$1"
    local script_name="${2:-$(get_caller_script)}"
    
    log_info "Executing command: $command" "$script_name"
    
    local start_time=$(date +%s)
    local output
    local exit_code
    
    # Execute command and capture output and exit code
    if output=$(eval "$command" 2>&1); then
        exit_code=0
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "Command completed successfully in ${duration}s: $command" "$script_name"
        if [[ -n "$output" ]]; then
            log_info "Command output: $output" "$script_name"
        fi
    else
        exit_code=$?
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_error "Command failed after ${duration}s with exit code $exit_code: $command" "$script_name"
        if [[ -n "$output" ]]; then
            log_error "Command error output: $output" "$script_name"
        fi
    fi
    
    return $exit_code
}

# Function to start a log session for a script
log_session_start() {
    local script_name="${1:-$(get_caller_script)}"
    local session_info="$2"
    
    log_info "========== SESSION START ==========" "$script_name"
    log_info "Script: $script_name" "$script_name"
    log_info "PID: $$" "$script_name"
    log_info "User: $(whoami)" "$script_name"
    log_info "Working Directory: $(pwd)" "$script_name"
    if [[ -n "$session_info" ]]; then
        log_info "Session Info: $session_info" "$script_name"
    fi
    log_info "====================================" "$script_name"
}

# Function to end a log session for a script
log_session_end() {
    local script_name="${1:-$(get_caller_script)}"
    local exit_status="${2:-0}"
    
    log_info "========== SESSION END ==========" "$script_name"
    if [[ "$exit_status" -eq 0 ]]; then
        log_success "Script completed successfully" "$script_name"
    else
        log_error "Script completed with exit code: $exit_status" "$script_name"
    fi
    log_info "====================================" "$script_name"
}

# Function to display log statistics
show_log_stats() {
    local script_name="${1:-$(get_caller_script)}"
    
    log_info "Log Statistics:" "$script_name"
    
    if [[ -f "$ERROR_LOG" ]]; then
        local error_count=$(wc -l < "$ERROR_LOG" 2>/dev/null || echo "0")
        log_info "Total Errors: $error_count" "$script_name"
    fi
    
    if [[ -f "$WARNING_LOG" ]]; then
        local warning_count=$(wc -l < "$WARNING_LOG" 2>/dev/null || echo "0")
        log_info "Total Warnings: $warning_count" "$script_name"
    fi
    
    if [[ -f "$SUCCESS_LOG" ]]; then
        local success_count=$(wc -l < "$SUCCESS_LOG" 2>/dev/null || echo "0")
        log_info "Total Successes: $success_count" "$script_name"
    fi
    
    if [[ -f "$INFO_LOG" ]]; then
        local info_count=$(wc -l < "$INFO_LOG" 2>/dev/null || echo "0")
        log_info "Total Info Messages: $info_count" "$script_name"
    fi
}

# Function to rotate logs if they get too large
rotate_logs() {
    local max_size=${1:-10485760}  # 10MB default
    local script_name="${2:-$(get_caller_script)}"
    
    for log_file in "$ERROR_LOG" "$SUCCESS_LOG" "$WARNING_LOG" "$INFO_LOG"; do
        if [[ -f "$log_file" ]]; then
            local file_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")
            if [[ "$file_size" -gt "$max_size" ]]; then
                local backup_file="${log_file}.$(date +%Y%m%d_%H%M%S)"
                mv "$log_file" "$backup_file"
                log_info "Rotated large log file: $(basename "$log_file") -> $(basename "$backup_file")" "$script_name"
                
                # Compress old log file
                if command -v gzip &> /dev/null; then
                    gzip "$backup_file"
                    log_info "Compressed rotated log: $(basename "$backup_file").gz" "$script_name"
                fi
            fi
        fi
    done
}

# Function to clean old log files
clean_old_logs() {
    local days_to_keep=${1:-30}
    local script_name="${2:-$(get_caller_script)}"
    
    log_info "Cleaning log files older than $days_to_keep days" "$script_name"
    
    local cleaned_count=0
    
    # Clean rotated/compressed logs
    find "$LOG_DIR" -name "*.log.*" -type f -mtime +$days_to_keep -exec rm {} \; 2>/dev/null && {
        cleaned_count=$(find "$LOG_DIR" -name "*.log.*" -type f -mtime +$days_to_keep | wc -l)
        if [[ $cleaned_count -gt 0 ]]; then
            log_info "Cleaned $cleaned_count old log files" "$script_name"
        fi
    }
}

# Export functions so they can be used by other scripts
export -f write_log log_error log_success log_warning log_info log_debug
export -f log_command log_session_start log_session_end show_log_stats
export -f rotate_logs clean_old_logs get_caller_script format_log_entry
