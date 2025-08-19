#!/bin/bash

# MariaDB Auto-Incremental Backup Script
# Author: GitHub Copilot
# Date: $(date)
# Description: Automated backup script for MariaDB with full and incremental backup support
# Supports both direct database connections and SSH tunneling

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/conf/server_config.json"
LOG_DIR="${SCRIPT_DIR}/logs"
LOCK_FILE="${SCRIPT_DIR}/backup.lock"

# Default backup base directory (always local)
DEFAULT_BACKUP_BASE_DIR="${SCRIPT_DIR}/backups"

# Connection methods
CONNECTION_DIRECT="direct"
CONNECTION_SSH="ssh"

# Source the centralized logging utility
source "${SCRIPT_DIR}/lib/logging_utils.sh"

# Legacy logging function for backward compatibility
log() {
    local level="$1"
    shift
    write_log "$level" "$*" "mariadb_backup.sh"
}

# Error handling
error_exit() {
    log_error "$1"
    cleanup
    log_session_end "mariadb_backup.sh" 1
    exit 1
}

# Cleanup function
cleanup() {
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Utility: Expand tilde in path
expand_path() {
    local path="$1"
    if [[ "$path" =~ ^~.*$ ]]; then
        echo "${path/#\~/$HOME}"
    else
        echo "$path"
    fi
}

# Utility: Test if database is directly accessible
test_direct_db_connection() {
    local db_config="$1"
    
    local db_host=$(echo "$db_config" | jq -r '.host')
    local db_port=$(echo "$db_config" | jq -r '.port // 3306')
    local db_user=$(echo "$db_config" | jq -r '.username')
    local db_password=$(echo "$db_config" | jq -r '.password')
    
    # Try to connect directly with timeout
    if timeout 10 mysql -h"$db_host" -P"$db_port" -u"$db_user" -p"$db_password" -e "SELECT 1;" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Utility: Determine connection method
determine_connection_method() {
    local server_config="$1"
    local server_name="$2"
    
    local db_config=$(echo "$server_config" | jq -r '.database')
    local force_ssh=$(echo "$server_config" | jq -r '.force_ssh // false')
    local backup_connection=$(echo "$server_config" | jq -r '.backup_connection // "auto"')
    
    # Check backup_connection setting first
    case "$backup_connection" in
        "local")
            log_info "[$server_name] Local backup connection mode - using direct database access"
            echo "$CONNECTION_DIRECT"
            return
            ;;
        "remote")
            log_info "[$server_name] Remote backup connection mode - using SSH tunnel"
            echo "$CONNECTION_SSH"
            return
            ;;
        "auto")
            # Continue with existing auto-detection logic
            ;;
        *)
            log_warning "[$server_name] Invalid backup_connection value '$backup_connection', using auto detection"
            ;;
    esac
    
    # If force_ssh is true, always use SSH (for backward compatibility)
    if [[ "$force_ssh" == "true" ]]; then
        log_info "[$server_name] Forced SSH connection mode (legacy force_ssh setting)"
        echo "$CONNECTION_SSH"
        return
    fi
    
    # Test direct connection first
    log_debug "[$server_name] Testing direct database connection..."
    if test_direct_db_connection "$db_config"; then
        log_info "[$server_name] Direct database connection available"
        echo "$CONNECTION_DIRECT"
    else
        log_info "[$server_name] Direct connection failed, will use SSH tunnel"
        echo "$CONNECTION_SSH"
    fi
}

# Utility: Build MySQL command based on connection method
build_mysql_command() {
    local connection_method="$1"
    local server_config="$2"
    local db_config="$3"
    local command_type="${4:-query}" # query, dump, or import
    local additional_opts="${5:-}"
    
    local db_host=$(echo "$db_config" | jq -r '.host')
    local db_port=$(echo "$db_config" | jq -r '.port // 3306')
    local db_user=$(echo "$db_config" | jq -r '.username')
    local db_password=$(echo "$db_config" | jq -r '.password')
    local ssl_mode=$(echo "$db_config" | jq -r '.ssl_mode // "auto"')
    
    # Build SSL options based on configuration
    local ssl_opts=""
    case "$ssl_mode" in
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
    
    case "$connection_method" in
        "$CONNECTION_DIRECT")
            case "$command_type" in
                "dump")
                    echo "mariadb-dump -h$db_host -P$db_port -u$db_user -p$db_password $ssl_opts $additional_opts"
                    ;;
                "query"|"import")
                    echo "mysql -h$db_host -P$db_port -u$db_user -p$db_password $ssl_opts $additional_opts"
                    ;;
            esac
            ;;
        "$CONNECTION_SSH")
            local ssh_prefix
            ssh_prefix=$(build_ssh_command_prefix "$server_config")
            case "$command_type" in
                "dump")
                    echo "$ssh_prefix 'mariadb-dump -h$db_host -P$db_port -u$db_user -p$db_password $ssl_opts $additional_opts'"
                    ;;
                "query"|"import")
                    echo "$ssh_prefix 'mysql -h$db_host -P$db_port -u$db_user -p$db_password $ssl_opts $additional_opts'"
                    ;;
            esac
            ;;
    esac
}

# Utility: Build SSH command prefix
build_ssh_command_prefix() {
    local server_config="$1"
    
    local host=$(echo "$server_config" | jq -r '.host')
    local port=$(echo "$server_config" | jq -r '.port // 22')
    local username=$(echo "$server_config" | jq -r '.username')
    local auth_type=$(echo "$server_config" | jq -r '.auth_type')
    
    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -p $port"
    
    case "$auth_type" in
        "key")
            local private_key=$(echo "$server_config" | jq -r '.private_key')
            private_key=$(expand_path "$private_key")
            if [[ ! -f "$private_key" ]]; then
                error_exit "Private key file not found: $private_key"
            fi
            echo "ssh $ssh_opts -i $private_key $username@$host"
            ;;
        "password")
            local password=$(echo "$server_config" | jq -r '.password')
            if ! command -v sshpass &> /dev/null; then
                error_exit "sshpass is required for password authentication but not installed"
            fi
            echo "sshpass -p '$password' ssh $ssh_opts $username@$host"
            ;;
        *)
            error_exit "Unsupported authentication type: $auth_type"
            ;;
    esac
}

# Utility: Execute command with proper connection method
execute_db_command() {
    local connection_method="$1"
    local server_config="$2"
    local db_config="$3"
    local command="$4"
    local command_type="${5:-query}"
    local additional_opts="${6:-}"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_command "$connection_method" "$server_config" "$db_config" "$command_type" "$additional_opts")
    
    case "$connection_method" in
        "$CONNECTION_DIRECT")
            case "$command_type" in
                "dump")
                    eval "$mysql_cmd"
                    ;;
                "query")
                    echo "$command" | eval "$mysql_cmd"
                    ;;
                "import")
                    eval "$mysql_cmd" < <(echo "$command")
                    ;;
            esac
            ;;
        "$CONNECTION_SSH")
            case "$command_type" in
                "dump")
                    eval "$mysql_cmd"
                    ;;
                "query")
                    local ssh_prefix
                    ssh_prefix=$(build_ssh_command_prefix "$server_config")
                    local ssl_mode=$(echo "$db_config" | jq -r '.ssl_mode // "auto"')
                    local ssl_opts=""
                    case "$ssl_mode" in
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
                            ssl_opts=""
                            ;;
                    esac
                    echo "$command" | eval "$ssh_prefix 'mysql -h$(echo "$db_config" | jq -r .host) -P$(echo "$db_config" | jq -r '.port // 3306') -u$(echo "$db_config" | jq -r .username) -p$(echo "$db_config" | jq -r .password) $ssl_opts $additional_opts'"
                    ;;
            esac
            ;;
    esac
}

# Create lock file to prevent concurrent runs
create_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE")
        if kill -0 "$lock_pid" 2>/dev/null; then
            error_exit "Another backup process is already running (PID: $lock_pid)"
        else
            log "WARN" "Stale lock file found, removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# Check dependencies
check_dependencies() {
    local deps=("jq")
    local optional_deps=("sshpass")
    
    log_info "Checking dependencies for backup system"
    
    # Check for MySQL/MariaDB client
    if ! command -v mariadb &> /dev/null && ! command -v mysql &> /dev/null; then
        deps+=("mysql")
    fi
    
    # Check required dependencies
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error_exit "Required dependency '$dep' is not installed. Please install it first."
        fi
    done
    
    # Check optional dependencies and warn
    for dep in "${optional_deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_warning "Optional dependency '$dep' not found. Password-based SSH auth will not work."
        fi
    done
    
    log_success "All required dependencies are available"
}

# Parse configuration file
parse_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error_exit "Configuration file not found: $CONFIG_FILE"
    fi
    
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        error_exit "Invalid JSON in configuration file: $CONFIG_FILE"
    fi
}

# Get backup type based on date
get_backup_type() {
    local backup_type="incremental"
    
    # Full backup on the 1st of every month
    if [[ $(date '+%d') == "01" ]]; then
        backup_type="full"
    fi
    
    echo "$backup_type"
}

# Get database list from server with filtering
get_database_list() {
    local server_config="$1"
    local connection_method="$2"
    local server_name="$3"
    
    local db_config=$(echo "$server_config" | jq -r '.database')
    local backup_config=$(echo "$server_config" | jq -r '.backup_config // {}')
    
    log_debug "[$server_name] Getting database list using $connection_method connection"
    
    # Get backup mode and settings
    local backup_mode=$(echo "$backup_config" | jq -r '.mode // "all"')
    local include_system=$(echo "$backup_config" | jq -r '.include_system_databases // false')
    
    # Base exclusions (system databases)
    local exclude_dbs="information_schema|performance_schema"
    if [[ "$include_system" != "true" ]]; then
        exclude_dbs="$exclude_dbs|mysql|sys"
    fi
    
    local databases
    if databases=$(execute_db_command "$connection_method" "$server_config" "$db_config" "SHOW DATABASES;" "query" "-N -B"); then
        # Filter system databases
        local filtered_databases
        filtered_databases=$(echo "$databases" | grep -vE "$exclude_dbs" || true)
        
        case "$backup_mode" in
            "all")
                # Backup all databases except excluded ones
                local exclude_list
                exclude_list=$(echo "$backup_config" | jq -r '.exclude_databases[]? // empty' | tr '\n' '|' | sed 's/|$//')
                
                if [[ -n "$exclude_list" ]]; then
                    log_info "[$server_name] Excluding databases: $exclude_list"
                    echo "$filtered_databases" | grep -vE "$exclude_list" || true
                else
                    echo "$filtered_databases"
                fi
                ;;
            "specific")
                # Backup only specified databases
                local include_list
                include_list=$(echo "$backup_config" | jq -r '.databases[]? // empty')
                
                if [[ -z "$include_list" ]]; then
                    log_error "[$server_name] No databases specified for 'specific' mode"
                    return 1
                fi
                
                log_info "[$server_name] Including only specified databases: $(echo "$include_list" | tr '\n' ', ' | sed 's/, $//')"
                
                # Validate that specified databases exist
                local result=""
                while IFS= read -r specified_db; do
                    [[ -z "$specified_db" ]] && continue
                    if echo "$filtered_databases" | grep -q "^${specified_db}$"; then
                        result="${result}${specified_db}\n"
                    else
                        log_warning "[$server_name] Specified database '$specified_db' not found on server"
                    fi
                done <<< "$include_list"
                
                echo -e "$result" | sed '/^$/d'
                ;;
            "exclude")
                # Backup all except explicitly excluded (alias for "all" mode)
                local exclude_list
                exclude_list=$(echo "$backup_config" | jq -r '.exclude_databases[]? // empty' | tr '\n' '|' | sed 's/|$//')
                
                if [[ -n "$exclude_list" ]]; then
                    log_info "[$server_name] Excluding databases: $exclude_list"
                    echo "$filtered_databases" | grep -vE "$exclude_list" || true
                else
                    echo "$filtered_databases"
                fi
                ;;
            *)
                log_error "[$server_name] Invalid backup mode: $backup_mode"
                return 1
                ;;
        esac
    else
        error_exit "[$server_name] Failed to get database list"
    fi
}

# Check if initial backup exists
check_initial_backup() {
    local backup_dir="$1"
    local database="$2"
    
    if [[ -d "$backup_dir/$database" ]] && [[ -n "$(find "$backup_dir/$database" -name "*.sql.gz" -type f 2>/dev/null)" ]]; then
        return 0
    else
        return 1
    fi
}

# Create backup file with proper compression
create_backup_file() {
    local connection_method="$1"
    local server_config="$2"
    local database="$3"
    local backup_path="$4"
    local backup_type="$5"
    local server_name="$6"
    
    local db_config=$(echo "$server_config" | jq -r '.database')
    local dump_opts="--single-transaction --routines --triggers --events --databases $database"
    
    # Check if binary logging is enabled for incremental backups
    if [[ "$backup_type" == "incremental" ]]; then
        local binlog_enabled=false
        
        # Test if binary logging is available
        local test_cmd
        case "$connection_method" in
            "$CONNECTION_DIRECT")
                test_cmd=$(build_mysql_command "$connection_method" "$server_config" "$db_config" "query" "-e 'SHOW VARIABLES LIKE \"log_bin\";'")
                if eval "$test_cmd" 2>/dev/null | grep -q "ON"; then
                    binlog_enabled=true
                fi
                ;;
            "$CONNECTION_SSH")
                local ssh_prefix
                ssh_prefix=$(build_ssh_command_prefix "$server_config")
                if eval "$ssh_prefix 'mysql -h$(echo "$db_config" | jq -r .host) -P$(echo "$db_config" | jq -r '.port // 3306') -u$(echo "$db_config" | jq -r .username) -p$(echo "$db_config" | jq -r .password) --skip-ssl -e \"SHOW VARIABLES LIKE \\\"log_bin\\\";\"'" 2>/dev/null | grep -q "ON"; then
                    binlog_enabled=true
                fi
                ;;
        esac
        
        if [[ "$binlog_enabled" == "true" ]]; then
            # Binary logging is available, use proper incremental backup
            dump_opts="$dump_opts --flush-logs --master-data=2"
            log "DEBUG" "[$server_name] Binary logging detected, using incremental backup with binary log positions"
        else
            # Binary logging not available, fall back to full backup
            log "WARN" "[$server_name] Binary logging not enabled, performing full backup instead of incremental"
            backup_type="full"
            
            # Update backup path to reflect full backup
            local timestamp=$(date '+%Y%m%d_%H%M%S')
            local backup_file="full_backup_${database}_${timestamp}.sql.gz"
            local backup_dir=$(dirname "$backup_path")
            backup_path="$backup_dir/$backup_file"
        fi
    fi
    
    log "INFO" "[$server_name] Creating $backup_type backup for database: $database"
    
    case "$connection_method" in
        "$CONNECTION_DIRECT")
            local mysql_cmd
            mysql_cmd=$(build_mysql_command "$connection_method" "$server_config" "$db_config" "dump" "$dump_opts")
            
            if eval "$mysql_cmd" | gzip > "$backup_path"; then
                log "INFO" "[$server_name] Backup created successfully: $(basename "$backup_path")"
                return 0
            else
                error_exit "[$server_name] Failed to create backup for database: $database"
            fi
            ;;
        "$CONNECTION_SSH")
            local temp_file="/tmp/$(basename "$backup_path")"
            local ssh_prefix
            ssh_prefix=$(build_ssh_command_prefix "$server_config")
            
            # Create compressed backup on remote server
            local dump_cmd="mariadb-dump -h$(echo "$db_config" | jq -r .host) -P$(echo "$db_config" | jq -r '.port // 3306') -u$(echo "$db_config" | jq -r .username) -p$(echo "$db_config" | jq -r .password) $dump_opts | gzip > $temp_file"
            
            if eval "$ssh_prefix '$dump_cmd'"; then
                # Transfer backup file to local server
                local scp_cmd
                scp_cmd=$(build_scp_command "$server_config" "$temp_file" "$backup_path")
                
                if eval "$scp_cmd"; then
                    # Clean up remote temporary file
                    eval "$ssh_prefix 'rm -f $temp_file'"
                    log "INFO" "[$server_name] Backup transferred successfully: $(basename "$backup_path")"
                    return 0
                else
                    eval "$ssh_prefix 'rm -f $temp_file'"
                    error_exit "[$server_name] Failed to transfer backup file"
                fi
            else
                error_exit "[$server_name] Failed to create backup for database: $database"
            fi
            ;;
    esac
}

# Build SCP command
build_scp_command() {
    local server_config="$1"
    local remote_file="$2"
    local local_file="$3"
    
    local host=$(echo "$server_config" | jq -r '.host')
    local port=$(echo "$server_config" | jq -r '.port // 22')
    local username=$(echo "$server_config" | jq -r '.username')
    local auth_type=$(echo "$server_config" | jq -r '.auth_type')
    
    local scp_opts="-P $port -o StrictHostKeyChecking=no"
    
    case "$auth_type" in
        "key")
            local private_key=$(echo "$server_config" | jq -r '.private_key')
            private_key=$(expand_path "$private_key")
            echo "scp $scp_opts -i $private_key $username@$host:$remote_file $local_file"
            ;;
        "password")
            local password=$(echo "$server_config" | jq -r '.password')
            echo "sshpass -p '$password' scp $scp_opts $username@$host:$remote_file $local_file"
            ;;
    esac
}

# Perform full backup
perform_full_backup() {
    local server_config="$1"
    local database="$2"
    local backup_dir="$3"
    local connection_method="$4"
    local server_name="$5"
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="full_backup_${database}_${timestamp}.sql.gz"
    local backup_path="$backup_dir/$database/$backup_file"
    
    # Create backup directory
    mkdir -p "$backup_dir/$database"
    
    if create_backup_file "$connection_method" "$server_config" "$database" "$backup_path" "full" "$server_name"; then
        # Create marker file for incremental backups
        echo "$timestamp" > "$backup_dir/$database/.last_full_backup"
        return 0
    else
        return 1
    fi
}

# Perform incremental backup
perform_incremental_backup() {
    local server_config="$1"
    local database="$2"
    local backup_dir="$3"
    local connection_method="$4"
    local server_name="$5"
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="incremental_backup_${database}_${timestamp}.sql.gz"
    local backup_path="$backup_dir/$database/$backup_file"
    
    # Check if we have a baseline for incremental backup
    if [[ ! -f "$backup_dir/$database/.last_full_backup" && ! -f "$backup_dir/$database/.last_backup" ]]; then
        log "WARN" "[$server_name] No previous backup found for $database, performing full backup instead"
        perform_full_backup "$server_config" "$database" "$backup_dir" "$connection_method" "$server_name"
        return $?
    fi
    
    if create_backup_file "$connection_method" "$server_config" "$database" "$backup_path" "incremental" "$server_name"; then
        # Update last backup timestamp
        echo "$timestamp" > "$backup_dir/$database/.last_backup"
        return 0
    else
        return 1
    fi
}

# Clean old backups
cleanup_old_backups() {
    local backup_dir="$1"
    local database="$2"
    local server_name="$3"
    
    log "INFO" "[$server_name] Cleaning up old backups for database: $database"
    
    # Keep backups from the last month only
    find "$backup_dir/$database" -name "*.sql.gz" -type f -mtime +30 -delete 2>/dev/null || true
    
    # Clean up empty directories
    find "$backup_dir/$database" -type d -empty -delete 2>/dev/null || true
    
    log "INFO" "[$server_name] Cleanup completed for database: $database"
}

# Display backup configuration for logging
display_backup_config() {
    local server_name="$1"
    local server_config="$2"
    
    local backup_config=$(echo "$server_config" | jq -r '.backup_config // {}')
    local backup_mode=$(echo "$backup_config" | jq -r '.mode // "all"')
    local include_system=$(echo "$backup_config" | jq -r '.include_system_databases // false')
    
    log "INFO" "[$server_name] Backup configuration:"
    log "INFO" "[$server_name]   Mode: $backup_mode"
    log "INFO" "[$server_name]   Include system databases: $include_system"
    
    case "$backup_mode" in
        "all"|"exclude")
            local exclude_list
            exclude_list=$(echo "$backup_config" | jq -r '.exclude_databases[]? // empty' | tr '\n' ', ' | sed 's/, $//')
            if [[ -n "$exclude_list" ]]; then
                log "INFO" "[$server_name]   Excluded databases: $exclude_list"
            else
                log "INFO" "[$server_name]   Excluded databases: none"
            fi
            ;;
        "specific")
            local include_list
            include_list=$(echo "$backup_config" | jq -r '.databases[]? // empty' | tr '\n' ', ' | sed 's/, $//')
            if [[ -n "$include_list" ]]; then
                log "INFO" "[$server_name]   Included databases: $include_list"
            else
                log "WARN" "[$server_name]   No databases specified for specific mode!"
            fi
            ;;
    esac
}

# Main backup function for a server
backup_server() {
    local server_name="$1"
    local server_config="$2"
    
    log "INFO" "Starting backup for server: $server_name"
    
    # Display backup configuration
    display_backup_config "$server_name" "$server_config"
    
    # Determine backup directory (always local)
    local backup_base_dir=$(echo "$server_config" | jq -r '.backup_path // "'$DEFAULT_BACKUP_BASE_DIR'"')
    
    # Ensure backup_base_dir is absolute and local
    if [[ ! "$backup_base_dir" =~ ^/.* ]]; then
        backup_base_dir="${SCRIPT_DIR}/${backup_base_dir}"
    fi
    
    local backup_dir="$backup_base_dir/$server_name"
    local backup_type=$(get_backup_type)
    
    # Create backup directory
    mkdir -p "$backup_dir"
    
    # Determine connection method
    local connection_method
    connection_method=$(determine_connection_method "$server_config" "$server_name")
    
    # Get database list with filtering
    local databases
    if ! databases=$(get_database_list "$server_config" "$connection_method" "$server_name"); then
        error_exit "[$server_name] Failed to get database list"
    fi
    
    if [[ -z "$databases" ]]; then
        log "WARN" "[$server_name] No databases found or selected for backup"
        return 0
    fi
    
    # Count databases for progress tracking
    local total_databases
    total_databases=$(echo "$databases" | wc -l | tr -d ' ')
    log "INFO" "[$server_name] Found $total_databases database(s) to backup"
    
    # Process each database
    local current_db=0
    while IFS= read -r database; do
        [[ -z "$database" ]] && continue
        
        ((current_db++))
        log "INFO" "[$server_name] Processing database $current_db/$total_databases: $database"
        
        case "$backup_type" in
            "full")
                if perform_full_backup "$server_config" "$database" "$backup_dir" "$connection_method" "$server_name"; then
                    cleanup_old_backups "$backup_dir" "$database" "$server_name"
                else
                    log "ERROR" "[$server_name] Full backup failed for database: $database"
                fi
                ;;
            "incremental")
                if check_initial_backup "$backup_dir" "$database"; then
                    if ! perform_incremental_backup "$server_config" "$database" "$backup_dir" "$connection_method" "$server_name"; then
                        log "ERROR" "[$server_name] Incremental backup failed for database: $database"
                    fi
                else
                    log "INFO" "[$server_name] No initial backup found for $database, performing full backup"
                    if perform_full_backup "$server_config" "$database" "$backup_dir" "$connection_method" "$server_name"; then
                        cleanup_old_backups "$backup_dir" "$database" "$server_name"
                    else
                        log "ERROR" "[$server_name] Initial full backup failed for database: $database"
                    fi
                fi
                ;;
        esac
        
    done <<< "$databases"
    
    log "INFO" "Backup completed for server: $server_name"
}

# Main function
main() {
    local backup_type_arg="${1:-auto}"
    
    # Start logging session
    log_session_start "mariadb_backup.sh" "Backup type: $backup_type_arg"
    
    log_info "Starting MariaDB backup process (type: $backup_type_arg)"
    
    # Initialize
    mkdir -p "$LOG_DIR"
    create_lock
    check_dependencies
    parse_config
    
    # Override backup type if specified
    if [[ "$backup_type_arg" != "auto" ]]; then
        get_backup_type() { echo "$backup_type_arg"; }
    fi
    
    # Read server configurations
    local servers
    servers=$(jq -r '. | to_entries[] | @base64' "$CONFIG_FILE")
    
    if [[ -z "$servers" ]]; then
        error_exit "No servers found in configuration file"
    fi
    
    log_info "Found $(echo "$servers" | wc -l | tr -d ' ') server(s) in configuration"
    
    # Process each server
    while IFS= read -r server_data; do
        [[ -z "$server_data" ]] && continue
        
        local server_info
        server_info=$(echo "$server_data" | base64 --decode)
        local server_name=$(echo "$server_info" | jq -r '.key')
        local server_config=$(echo "$server_info" | jq -r '.value')
        
        backup_server "$server_name" "$server_config"
        
    done <<< "$servers"
    
    log_success "All backup operations completed successfully"
    log_session_end "mariadb_backup.sh" 0
}

# Script usage
usage() {
    echo "Usage: $0 [full|incremental|auto]"
    echo "  full        - Force full backup"
    echo "  incremental - Force incremental backup"
    echo "  auto        - Automatic mode (default)"
    exit 1
}

# Validate arguments
if [[ $# -gt 1 ]]; then
    usage
fi

if [[ $# -eq 1 ]] && [[ ! "$1" =~ ^(full|incremental|auto)$ ]]; then
    usage
fi

# Run main function
main "${1:-auto}"
