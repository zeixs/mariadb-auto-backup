#!/bin/bash

# MariaDB Auto-Backup System - Restore Script
# Automatically detects and restores from full and incremental backups
# Ensures data integrity by applying backups in correct chronological order

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the logging utility
source "$SCRIPT_DIR/logging_utils.sh"

# Configuration files
CONFIG_FILE="$SCRIPT_DIR/server_config.json"

# Global variables
RESTORE_MODE=""
TARGET_DATE=""
SERVER_NAME=""
DATABASE_NAME=""
TARGET_HOST=""
TARGET_USERNAME=""
TARGET_PASSWORD=""
TARGET_PORT="3306"
DRY_RUN=false
FORCE_RESTORE=false
SSL_MODE="auto"

# Display usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] <server_name> <database_name>

Restore MariaDB/MySQL databases from backup files with automatic detection
of full and incremental backups.

ARGUMENTS:
  server_name     Name of the server configuration
  database_name   Name of the database to restore

OPTIONS:
  -d, --date DATE        Restore to specific date (YYYY-MM-DD)
                         Default: latest available backup
  -t, --target HOST      Target database host (default: same as backup source)
  -u, --username USER    Target database username (default: same as backup source)
  -p, --password PASS    Target database password (default: same as backup source)
  -P, --port PORT        Target database port (default: 3306)
  --ssl-mode MODE        SSL mode: auto, disable, require, verify_ca, verify_identity
  --dry-run              Show what would be restored without executing
  --force                Force restore without confirmation prompts
  -h, --help             Show this help message

EXAMPLES:
  # Restore latest backup
  $0 production_server app_database

  # Restore to specific date
  $0 -d 2025-08-15 production_server app_database

  # Restore to different target server
  $0 -t 192.168.1.200 -u restore_user -p password production_server app_database

  # Dry run to see what would be restored
  $0 --dry-run production_server app_database

  # Force restore without prompts
  $0 --force production_server app_database

RESTORE PROCESS:
  1. Analyzes available backups for the specified database
  2. Identifies the appropriate full backup baseline
  3. Finds all incremental backups since the full backup
  4. Sorts backups chronologically to ensure proper order
  5. Restores full backup first, then applies incrementals in sequence
  6. Validates each step to prevent data corruption

BACKUP DETECTION:
  - Full backups: full_backup_<database>_<timestamp>.sql.gz
  - Incremental backups: incremental_backup_<database>_<timestamp>.sql.gz
  - Automatically handles backup chains and chronological ordering

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--date)
                TARGET_DATE="$2"
                shift 2
                ;;
            -t|--target)
                TARGET_HOST="$2"
                shift 2
                ;;
            -u|--username)
                TARGET_USERNAME="$2"
                shift 2
                ;;
            -p|--password)
                TARGET_PASSWORD="$2"
                shift 2
                ;;
            -P|--port)
                TARGET_PORT="$2"
                shift 2
                ;;
            --ssl-mode)
                SSL_MODE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE_RESTORE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [[ -z "$SERVER_NAME" ]]; then
                    SERVER_NAME="$1"
                elif [[ -z "$DATABASE_NAME" ]]; then
                    DATABASE_NAME="$1"
                else
                    log_error "Too many arguments: $1"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$SERVER_NAME" || -z "$DATABASE_NAME" ]]; then
        log_error "Missing required arguments: server_name and database_name"
        show_usage
        exit 1
    fi
}

# Validate target date format
validate_date() {
    local date_str="$1"
    if [[ ! "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log_error "Invalid date format: $date_str (expected: YYYY-MM-DD)"
        return 1
    fi
    
    # Check if date is valid using date command
    if ! date -j -f "%Y-%m-%d" "$date_str" "+%Y-%m-%d" &>/dev/null; then
        log_error "Invalid date: $date_str"
        return 1
    fi
    
    return 0
}

# Load server configuration
load_server_config() {
    local server_name="$1"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    # Check if server exists in configuration
    if ! jq -e ".\"$server_name\"" "$CONFIG_FILE" &>/dev/null; then
        log_error "Server '$server_name' not found in configuration"
        log_info "Available servers: $(jq -r 'keys[]' "$CONFIG_FILE" | tr '\n' ', ' | sed 's/, $//')"
        return 1
    fi
    
    local server_config
    server_config=$(jq ".\"$server_name\"" "$CONFIG_FILE")
    
    # Extract database configuration
    local db_config
    db_config=$(echo "$server_config" | jq -r '.database')
    
    # Set defaults from configuration if not specified
    if [[ -z "$TARGET_HOST" ]]; then
        TARGET_HOST=$(echo "$db_config" | jq -r '.host // "localhost"')
    fi
    
    if [[ -z "$TARGET_USERNAME" ]]; then
        TARGET_USERNAME=$(echo "$db_config" | jq -r '.username // empty')
    fi
    
    if [[ -z "$TARGET_PASSWORD" ]]; then
        TARGET_PASSWORD=$(echo "$db_config" | jq -r '.password // empty')
    fi
    
    if [[ "$TARGET_PORT" == "3306" ]]; then
        TARGET_PORT=$(echo "$db_config" | jq -r '.port // 3306')
    fi
    
    # Get SSL mode from configuration if not specified
    if [[ "$SSL_MODE" == "auto" ]]; then
        SSL_MODE=$(echo "$db_config" | jq -r '.ssl_mode // "auto"')
    fi
    
    # Validate required connection parameters
    if [[ -z "$TARGET_USERNAME" || -z "$TARGET_PASSWORD" ]]; then
        log_error "Database username and password are required"
        log_info "Specify with -u/--username and -p/--password, or ensure they're in the configuration"
        return 1
    fi
    
    log_info "Loaded configuration for server: $server_name"
    log_info "Target database: $TARGET_HOST:$TARGET_PORT"
    log_info "SSL mode: $SSL_MODE"
    
    return 0
}

# Build MySQL connection command with SSL options
build_mysql_command() {
    local additional_opts="${1:-}"
    
    # Build SSL options based on configuration
    local ssl_opts=""
    case "$SSL_MODE" in
        "disable"|"disabled")
            ssl_opts="--skip-ssl"
            ;;
        "require"|"required")
            ssl_opts="--ssl-mode=REQUIRED"
            ;;
        "verify_ca")
            ssl_opts="--ssl-mode=VERIFY_CA"
            ;;
        "verify_identity")
            ssl_opts="--ssl-mode=VERIFY_IDENTITY"
            ;;
        "auto"|*)
            # Auto mode: let MySQL/MariaDB handle SSL negotiation
            ssl_opts=""
            ;;
    esac
    
    echo "mysql -h\"$TARGET_HOST\" -P\"$TARGET_PORT\" -u\"$TARGET_USERNAME\" -p\"$TARGET_PASSWORD\" $ssl_opts $additional_opts"
}

# Test database connection
test_connection() {
    log_info "Testing database connection to $TARGET_HOST:$TARGET_PORT"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_command "-e 'SELECT 1;'")
    
    if eval "$mysql_cmd" &>/dev/null; then
        log_success "Database connection successful"
        return 0
    else
        log_error "Failed to connect to database $TARGET_HOST:$TARGET_PORT"
        log_error "Please verify connection parameters and SSL configuration"
        return 1
    fi
}

# Find backup directory for server and database
find_backup_directory() {
    local server_name="$1"
    local database_name="$2"
    
    local backup_dir="$SCRIPT_DIR/backups/$server_name/$database_name"
    
    if [[ ! -d "$backup_dir" ]]; then
        log_error "Backup directory not found: $backup_dir"
        return 1
    fi
    
    echo "$backup_dir"
    return 0
}

# Parse backup filename to extract timestamp
parse_backup_timestamp() {
    local filename="$1"
    
    # Extract timestamp from filename (format: *_YYYYMMDD_HHMMSS.sql.gz)
    if [[ "$filename" =~ _([0-9]{8}_[0-9]{6})\.sql\.gz$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    else
        log_warning "Could not parse timestamp from filename: $filename"
        return 1
    fi
}

# Convert timestamp to date for comparison
timestamp_to_date() {
    local timestamp="$1"
    
    # Convert YYYYMMDD_HHMMSS to YYYY-MM-DD
    echo "${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2}"
}

# Find available backups
find_backups() {
    local backup_dir="$1"
    local target_date="$2"
    
    log_info "Analyzing available backups in: $backup_dir"
    
    # Find all backup files
    local full_backups=()
    local incremental_backups=()
    
    while IFS= read -r -d '' file; do
        local filename=$(basename "$file")
        local timestamp
        
        if ! timestamp=$(parse_backup_timestamp "$filename"); then
            continue
        fi
        
        local backup_date
        backup_date=$(timestamp_to_date "$timestamp")
        
        # Filter by target date if specified
        if [[ -n "$target_date" ]] && [[ "$backup_date" > "$target_date" ]]; then
            continue
        fi
        
        if [[ "$filename" =~ ^full_backup_ ]]; then
            full_backups+=("$file|$timestamp")
        elif [[ "$filename" =~ ^incremental_backup_ ]]; then
            incremental_backups+=("$file|$timestamp")
        fi
    done < <(find "$backup_dir" -name "*.sql.gz" -type f -print0)
    
    if [[ ${#full_backups[@]} -eq 0 ]]; then
        log_error "No full backups found for database: $DATABASE_NAME"
        return 1
    fi
    
    # Sort backups by timestamp (newest first for full, oldest first for incremental)
    IFS=$'\n' full_backups=($(printf '%s\n' "${full_backups[@]}" | sort -t'|' -k2,2r))
    IFS=$'\n' incremental_backups=($(printf '%s\n' "${incremental_backups[@]}" | sort -t'|' -k2,2))
    
    # Find the appropriate full backup
    local selected_full=""
    local selected_full_timestamp=""
    
    for backup_entry in "${full_backups[@]}"; do
        local backup_file="${backup_entry%|*}"
        local backup_timestamp="${backup_entry#*|}"
        local backup_date
        backup_date=$(timestamp_to_date "$backup_timestamp")
        
        if [[ -z "$target_date" ]] || [[ "$backup_date" < "$target_date" ]] || [[ "$backup_date" == "$target_date" ]]; then
            selected_full="$backup_file"
            selected_full_timestamp="$backup_timestamp"
            break
        fi
    done
    
    if [[ -z "$selected_full" ]]; then
        log_error "No suitable full backup found before date: $target_date"
        return 1
    fi
    
    # Find incremental backups after the selected full backup
    local applicable_incrementals=()
    
    for backup_entry in "${incremental_backups[@]}"; do
        local backup_file="${backup_entry%|*}"
        local backup_timestamp="${backup_entry#*|}"
        local backup_date
        backup_date=$(timestamp_to_date "$backup_timestamp")
        
        # Include if after full backup and before/on target date
        if [[ "$backup_timestamp" > "$selected_full_timestamp" ]]; then
            if [[ -z "$target_date" ]] || [[ "$backup_date" < "$target_date" ]] || [[ "$backup_date" == "$target_date" ]]; then
                applicable_incrementals+=("$backup_file")
            fi
        fi
    done
    
    # Output results
    echo "FULL_BACKUP:$selected_full"
    echo "FULL_TIMESTAMP:$selected_full_timestamp"
    echo "FULL_DATE:$(timestamp_to_date "$selected_full_timestamp")"
    
    if [[ ${#applicable_incrementals[@]} -gt 0 ]]; then
        for incremental in "${applicable_incrementals[@]}"; do
            echo "INCREMENTAL:$incremental"
        done
    fi
    
    return 0
}

# Display restore plan
show_restore_plan() {
    local full_backup="$1"
    local incremental_backups=("${@:2}")
    
    log_info "=== RESTORE PLAN ==="
    log_info "Database: $DATABASE_NAME"
    log_info "Target: $TARGET_HOST:$TARGET_PORT"
    log_info "Target Date: ${TARGET_DATE:-latest available}"
    echo
    
    log_info "1. Full Backup Restore:"
    log_info "   File: $(basename "$full_backup")"
    log_info "   Date: $(timestamp_to_date "$(parse_backup_timestamp "$(basename "$full_backup")")")"
    echo
    
    if [[ ${#incremental_backups[@]} -gt 0 ]]; then
        log_info "2. Incremental Backups (in order):"
        local counter=1
        for incremental in "${incremental_backups[@]}"; do
            log_info "   $counter. $(basename "$incremental")"
            log_info "      Date: $(timestamp_to_date "$(parse_backup_timestamp "$(basename "$incremental")")")"
            ((counter++))
        done
    else
        log_info "2. No incremental backups to apply"
    fi
    echo
    
    log_info "=== END RESTORE PLAN ==="
}

# Execute restore operation
execute_restore() {
    local full_backup="$1"
    local incremental_backups=("${@:2}")
    
    log_info "Starting database restore process"
    
    # Check if database exists and warn about overwrite
    local mysql_cmd
    mysql_cmd=$(build_mysql_command "-e 'USE $DATABASE_NAME;'")
    
    if eval "$mysql_cmd" &>/dev/null; then
        if [[ "$FORCE_RESTORE" != "true" ]]; then
            log_warning "Database '$DATABASE_NAME' already exists and will be overwritten!"
            read -p "Continue with restore? (y/N): " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Restore cancelled by user"
                return 1
            fi
        else
            log_warning "Database '$DATABASE_NAME' exists - proceeding with forced restore"
        fi
    fi
    
    # Restore full backup
    log_info "Restoring full backup: $(basename "$full_backup")"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would restore: $full_backup"
    else
        local mysql_restore_cmd
        mysql_restore_cmd=$(build_mysql_command "$DATABASE_NAME")
        
        if gunzip -c "$full_backup" | eval "$mysql_restore_cmd"; then
            log_success "Full backup restored successfully"
        else
            log_error "Failed to restore full backup: $full_backup"
            return 1
        fi
    fi
    
    # Apply incremental backups
    if [[ ${#incremental_backups[@]} -gt 0 ]]; then
        log_info "Applying ${#incremental_backups[@]} incremental backup(s)"
        
        local counter=1
        for incremental in "${incremental_backups[@]}"; do
            log_info "Applying incremental backup $counter/${#incremental_backups[@]}: $(basename "$incremental")"
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would apply: $incremental"
            else
                local mysql_restore_cmd
                mysql_restore_cmd=$(build_mysql_command "$DATABASE_NAME")
                
                if gunzip -c "$incremental" | eval "$mysql_restore_cmd"; then
                    log_success "Incremental backup $counter applied successfully"
                else
                    log_error "Failed to apply incremental backup: $incremental"
                    return 1
                fi
            fi
            
            ((counter++))
        done
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "[DRY RUN] Restore plan completed successfully"
    else
        log_success "Database restore completed successfully!"
        log_info "Database '$DATABASE_NAME' has been restored to $TARGET_HOST:$TARGET_PORT"
    fi
    
    return 0
}

# Main function
main() {
    log_session_start "restore.sh" "Restore: $*"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Validate target date if provided
    if [[ -n "$TARGET_DATE" ]]; then
        if ! validate_date "$TARGET_DATE"; then
            log_session_end 1
            exit 1
        fi
    fi
    
    # Load server configuration
    if ! load_server_config "$SERVER_NAME"; then
        log_session_end 1
        exit 1
    fi
    
    # Test database connection
    if ! test_connection; then
        log_session_end 1
        exit 1
    fi
    
    # Find backup directory
    local backup_dir
    if ! backup_dir=$(find_backup_directory "$SERVER_NAME" "$DATABASE_NAME"); then
        log_session_end 1
        exit 1
    fi
    
    # Analyze available backups
    local backup_analysis
    if ! backup_analysis=$(find_backups "$backup_dir" "$TARGET_DATE"); then
        log_session_end 1
        exit 1
    fi
    
    # Parse backup analysis results
    local full_backup=""
    local full_timestamp=""
    local full_date=""
    local incremental_backups=()
    
    while IFS= read -r line; do
        case "$line" in
            FULL_BACKUP:*)
                full_backup="${line#FULL_BACKUP:}"
                ;;
            FULL_TIMESTAMP:*)
                full_timestamp="${line#FULL_TIMESTAMP:}"
                ;;
            FULL_DATE:*)
                full_date="${line#FULL_DATE:}"
                ;;
            INCREMENTAL:*)
                incremental_backups+=("${line#INCREMENTAL:}")
                ;;
        esac
    done <<< "$backup_analysis"
    
    if [[ -z "$full_backup" ]]; then
        log_error "No suitable backup found for restore"
        log_session_end 1
        exit 1
    fi
    
    # Display restore plan
    show_restore_plan "$full_backup" "${incremental_backups[@]}"
    
    # Execute restore
    if execute_restore "$full_backup" "${incremental_backups[@]}"; then
        log_session_end 0
        exit 0
    else
        log_session_end 1
        exit 1
    fi
}

# Execute main function with all arguments
main "$@"
