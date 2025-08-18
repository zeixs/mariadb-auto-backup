#!/bin/bash

# Database Discovery Tool for MariaDB Backup Configuration
# This tool helps you discover databases on your servers for backup configuration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/server_config.json"

# Source the centralized logging utility
source "${SCRIPT_DIR}/logging_utils.sh"

# Legacy log function for backward compatibility  
log() {
    local level="$1"
    shift
    write_log "$level" "$*" "discover_databases.sh"
}

# Source utility functions from main backup script
source_utility_functions() {
    # Extract utility functions from main script
    local temp_script="/tmp/backup_utils_$$.sh"
    
    # Extract functions we need
    grep -A 50 "^expand_path()" "$SCRIPT_DIR/mariadb_backup.sh" | sed '/^}/q' > "$temp_script"
    echo "" >> "$temp_script"
    grep -A 30 "^test_direct_db_connection()" "$SCRIPT_DIR/mariadb_backup.sh" | sed '/^}/q' >> "$temp_script"
    echo "" >> "$temp_script"
    grep -A 50 "^build_ssh_command_prefix()" "$SCRIPT_DIR/mariadb_backup.sh" | sed '/^}/q' >> "$temp_script"
    echo "" >> "$temp_script"
    grep -A 100 "^execute_db_command()" "$SCRIPT_DIR/mariadb_backup.sh" | sed '/^}/q' >> "$temp_script"
    
    source "$temp_script"
    rm -f "$temp_script"
}

# Get databases from server
get_server_databases() {
    local server_name="$1"
    local show_system="${2:-false}"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    local server_config
    server_config=$(jq -r ".\"$server_name\" // empty" "$CONFIG_FILE")
    
    if [[ -z "$server_config" || "$server_config" == "null" ]]; then
        log_error "Server '$server_name' not found in configuration"
        return 1
    fi
    
    local db_config=$(echo "$server_config" | jq -r '.database')
    local force_ssh=$(echo "$server_config" | jq -r '.force_ssh // false')
    
    log_info "Discovering databases on server: $server_name"
    
    # Determine connection method
    local connection_method="direct"
    if [[ "$force_ssh" == "true" ]] || ! test_direct_db_connection "$db_config"; then
        connection_method="ssh"
        log_info "Using SSH connection method for $server_name"
    else
        log_info "Using direct connection method for $server_name"
    fi
    
    # Get all databases
    local all_databases
    if all_databases=$(execute_db_command "$connection_method" "$server_config" "$db_config" "SHOW DATABASES;" "query" "-N -B"); then
        # Separate system and user databases
        local system_dbs="information_schema|performance_schema|mysql|sys"
        local user_databases
        local system_databases
        
        user_databases=$(echo "$all_databases" | grep -vE "$system_dbs" || true)
        system_databases=$(echo "$all_databases" | grep -E "$system_dbs" || true)
        
        echo "User Databases:"
        echo "==============="
        if [[ -n "$user_databases" ]]; then
            echo "$user_databases" | while read -r db; do
                [[ -n "$db" ]] && echo "  • $db"
            done
        else
            echo "  (none found)"
        fi
        
        if [[ "$show_system" == "true" ]]; then
            echo ""
            echo "System Databases:"
            echo "=================="
            if [[ -n "$system_databases" ]]; then
                echo "$system_databases" | while read -r db; do
                    [[ -n "$db" ]] && echo "  • $db"
                done
            else
                echo "  (none found)"
            fi
        fi
        
        # Generate configuration snippets
        echo ""
        echo "Configuration Examples:"
        echo "======================="
        
        if [[ -n "$user_databases" ]]; then
            # All databases mode
            echo "1. Backup all user databases:"
            echo '  "backup_config": {'
            echo '    "mode": "all",'
            echo '    "include_system_databases": false'
            echo '  }'
            echo ""
            
            # Specific databases mode
            echo "2. Backup specific databases:"
            echo '  "backup_config": {'
            echo '    "mode": "specific",'
            local db_list
            db_list=$(echo "$user_databases" | head -3 | sed 's/^/    "/' | sed 's/$/"/' | tr '\n' ',' | sed 's/,$//')
            echo "    \"databases\": [$db_list],"
            echo '    "include_system_databases": false'
            echo '  }'
            echo ""
            
            # Exclude mode
            echo "3. Backup all except specified:"
            echo '  "backup_config": {'
            echo '    "mode": "exclude",'
            local exclude_list
            exclude_list=$(echo "$user_databases" | tail -2 | sed 's/^/    "/' | sed 's/$/"/' | tr '\n' ',' | sed 's/,$//')
            echo "    \"exclude_databases\": [$exclude_list],"
            echo '    "include_system_databases": false'
            echo '  }'
        fi
        
        return 0
    else
        log_error "Failed to get database list from server: $server_name"
        return 1
    fi
}

# List all servers in configuration
list_servers() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    log_info "Available servers in configuration:"
    jq -r 'keys[]' "$CONFIG_FILE" | while read -r server; do
        echo "  • $server"
    done
}

# Generate backup configuration
generate_backup_config() {
    local server_name="$1"
    local mode="$2"
    local databases="${3:-}"
    
    case "$mode" in
        "all")
            cat << EOF
  "backup_config": {
    "mode": "all",
    "include_system_databases": false
  }
EOF
            ;;
        "specific")
            if [[ -z "$databases" ]]; then
                log "ERROR" "Database list required for specific mode"
                return 1
            fi
            local db_array
            db_array=$(echo "$databases" | tr ',' '\n' | sed 's/^[ ]*//' | sed 's/[ ]*$//' | sed 's/^/"/' | sed 's/$/"/' | tr '\n' ',' | sed 's/,$//')
            cat << EOF
  "backup_config": {
    "mode": "specific",
    "databases": [$db_array],
    "include_system_databases": false
  }
EOF
            ;;
        "exclude")
            if [[ -z "$databases" ]]; then
                log "ERROR" "Database list required for exclude mode"
                return 1
            fi
            local db_array
            db_array=$(echo "$databases" | tr ',' '\n' | sed 's/^[ ]*//' | sed 's/[ ]*$//' | sed 's/^/"/' | sed 's/$/"/' | tr '\n' ',' | sed 's/,$//')
            cat << EOF
  "backup_config": {
    "mode": "exclude",
    "exclude_databases": [$db_array],
    "include_system_databases": false
  }
EOF
            ;;
        *)
            log "ERROR" "Invalid mode: $mode"
            return 1
            ;;
    esac
}

# Usage
usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  list-servers                    - List all servers in configuration"
    echo "  discover <server_name>          - Discover databases on a server"
    echo "  discover-all <server_name>      - Discover databases including system DBs"
    echo "  generate <server> <mode> [dbs]  - Generate backup config snippet"
    echo ""
    echo "Generate modes:"
    echo "  all                             - Backup all databases"
    echo "  specific \"db1,db2,db3\"          - Backup only specified databases"
    echo "  exclude \"db1,db2\"               - Backup all except specified"
    echo ""
    echo "Examples:"
    echo "  $0 list-servers"
    echo "  $0 discover server1"
    echo "  $0 discover-all server1"
    echo "  $0 generate server1 specific \"app_db,user_db\""
    echo "  $0 generate server1 exclude \"test_db,temp_db\""
}

# Main function
main() {
    local command="${1:-}"
    
    if [[ -z "$command" ]]; then
        usage
        exit 1
    fi
    
    # Start logging session
    log_session_start "discover_databases.sh" "Command: $command ${*:2}"
    
    # Source utility functions
    source_utility_functions
    
    local exit_code=0
    
    case "$command" in
        "list-servers")
            if ! list_servers; then
                exit_code=1
            fi
            ;;
        "discover")
            if [[ $# -lt 2 ]]; then
                log_error "Server name required"
                usage
                exit_code=1
            else
                if ! get_server_databases "$2" false; then
                    exit_code=1
                fi
            fi
            ;;
        "discover-all")
            if [[ $# -lt 2 ]]; then
                log_error "Server name required"
                usage
                exit_code=1
            else
                if ! get_server_databases "$2" true; then
                    exit_code=1
                fi
            fi
            ;;
        "generate")
            if [[ $# -lt 3 ]]; then
                log_error "Server name and mode required"
                usage
                exit_code=1
            else
                if ! generate_backup_config "$2" "$3" "${4:-}"; then
                    exit_code=1
                fi
            fi
            ;;
        "help"|"-h"|"--help")
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit_code=1
            ;;
    esac
    
    log_session_end "discover_databases.sh" $exit_code
    exit $exit_code
}

main "$@"
