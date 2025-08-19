#!/bin/bash

# Enhanced Configuration Validation Script for MariaDB Backup
# This script validates the server configuration and tests connections with new features

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/server_config.json"

# Source the centralized logging utility
source "${SCRIPT_DIR}/logging_utils.sh"

# Legacy log function for backward compatibility
log() {
    local level="$1"
    shift
    write_log "$level" "$*" "validate_config.sh"
}

# Expand tilde in path
expand_path() {
    local path="$1"
    if [[ "$path" =~ ^~.*$ ]]; then
        echo "${path/#\~/$HOME}"
    else
        echo "$path"
    fi
}

# Check dependencies
check_dependencies() {
    local deps=("jq")
    local missing_deps=()
    
    log_info "Checking system dependencies"
    
    # Check for MySQL/MariaDB client
    if ! command -v mariadb &> /dev/null && ! command -v mysql &> /dev/null; then
        missing_deps+=("mysql")
    fi
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    # Check optional dependencies
    if ! command -v sshpass &> /dev/null; then
        log_warning "sshpass not found - password SSH authentication will not work"
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install missing dependencies:"
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                "jq")
                    echo "  - macOS: brew install jq"
                    echo "  - Ubuntu/Debian: apt-get install jq"
                    echo "  - CentOS/RHEL: yum install jq"
                    ;;
                "mysql")
                    echo "  - macOS: brew install mariadb"
                    echo "  - Ubuntu/Debian: apt-get install mariadb-client"
                    echo "  - CentOS/RHEL: yum install mariadb"
                    ;;
            esac
        done
        return 1
    else
        log_success "All required dependencies are installed"
        return 0
    fi
}

# Validate JSON configuration
validate_json() {
    log "INFO" "Validating configuration file..."
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR" "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log "ERROR" "Invalid JSON in configuration file"
        return 1
    fi
    
    log "INFO" "Configuration file JSON is valid"
    return 0
}

# Validate server configuration structure
validate_server_config() {
    local server_name="$1"
    local server_config="$2"
    local errors=0
    
    log "DEBUG" "Validating server: $server_name"
    
    # Required fields for database access
    local required_fields=("database")
    for field in "${required_fields[@]}"; do
        if [[ $(echo "$server_config" | jq -r ".$field // empty") == "" ]]; then
            log "ERROR" "[$server_name] Missing required field: $field"
            ((errors++))
        fi
    done
    
    # Validate backup configuration if present
    local backup_config=$(echo "$server_config" | jq -r '.backup_config // {}')
    if [[ "$backup_config" != "{}" ]]; then
        if ! validate_backup_config "$server_name" "$backup_config"; then
            ((errors++))
        fi
    fi
    
    # Validate schedule configuration if present
    local schedule_config=$(echo "$server_config" | jq -r '.schedule // {}')
    if [[ "$schedule_config" != "{}" ]]; then
        if ! validate_schedule_config "$server_name" "$schedule_config"; then
            ((errors++))
        fi
    fi
    
    # Validate cleanup configuration if present
    local cleanup_config=$(echo "$server_config" | jq -r '.cleanup // {}')
    if [[ "$cleanup_config" != "{}" ]]; then
        if ! validate_cleanup_config "$server_name" "$cleanup_config"; then
            ((errors++))
        fi
    fi
    
    # Validate backup_connection setting
    local backup_connection=$(echo "$server_config" | jq -r '.backup_connection // "auto"')
    case "$backup_connection" in
        "local"|"remote"|"auto")
            # Valid values
            ;;
        *)
            log "ERROR" "[$server_name] Invalid backup_connection value: $backup_connection (must be 'local', 'remote', or 'auto')"
            ((errors++))
            ;;
    esac
    
    # Check if SSH config is present when needed
    local force_ssh=$(echo "$server_config" | jq -r '.force_ssh // false')
    local has_ssh_config=true
    
    if [[ $(echo "$server_config" | jq -r '.host // empty') == "" ]] || 
       [[ $(echo "$server_config" | jq -r '.username // empty') == "" ]] ||
       [[ $(echo "$server_config" | jq -r '.auth_type // empty') == "" ]]; then
        has_ssh_config=false
    fi
    
    # Determine when SSH config is required
    local ssh_required=false
    
    # SSH is required if:
    # 1. backup_connection is explicitly set to "remote"
    # 2. force_ssh is true (legacy support)
    # 3. backup_connection is "auto" and database host suggests remote access
    local db_host=$(echo "$server_config" | jq -r '.database.host // empty')
    
    if [[ "$backup_connection" == "remote" ]]; then
        ssh_required=true
        log "DEBUG" "[$server_name] SSH required due to backup_connection=remote"
    elif [[ "$force_ssh" == "true" ]]; then
        ssh_required=true
        log "DEBUG" "[$server_name] SSH required due to force_ssh=true (legacy)"
    elif [[ "$backup_connection" == "auto" && "$db_host" =~ ^(localhost|127\.0\.0\.1)$ ]]; then
        ssh_required=true
        log "DEBUG" "[$server_name] SSH required due to localhost database host in auto mode"
    fi
    
    # Validate SSH config if required
    if [[ "$ssh_required" == "true" ]]; then
        if [[ "$has_ssh_config" == "false" ]]; then
            log "ERROR" "[$server_name] SSH configuration required but missing"
            log "INFO" "[$server_name] Required for backup_connection='$backup_connection'"
            ((errors++))
        fi
    fi
    
    # Validate auth_type if SSH config is present
    if [[ "$has_ssh_config" == "true" ]]; then
        local auth_type=$(echo "$server_config" | jq -r '.auth_type // empty')
        case "$auth_type" in
            "key")
                local private_key=$(echo "$server_config" | jq -r '.private_key // empty')
                if [[ -z "$private_key" ]]; then
                    log "ERROR" "[$server_name] private_key is required for auth_type 'key'"
                    ((errors++))
                else
                    private_key=$(expand_path "$private_key")
                    if [[ ! -f "$private_key" ]]; then
                        log "ERROR" "[$server_name] Private key file not found: $private_key"
                        ((errors++))
                    fi
                fi
                ;;
            "password")
                local password=$(echo "$server_config" | jq -r '.password // empty')
                if [[ -z "$password" ]]; then
                    log "ERROR" "[$server_name] password is required for auth_type 'password'"
                    ((errors++))
                fi
                ;;
            *)
                if [[ -n "$auth_type" ]]; then
                    log "ERROR" "[$server_name] Invalid auth_type: $auth_type (must be 'key' or 'password')"
                    ((errors++))
                fi
                ;;
        esac
    fi
    
    # Validate database configuration
    local db_config=$(echo "$server_config" | jq -r '.database // empty')
    if [[ "$db_config" != "null" ]] && [[ -n "$db_config" ]]; then
        local db_required=("host" "username" "password")
        for field in "${db_required[@]}"; do
            if [[ $(echo "$db_config" | jq -r ".$field // empty") == "" ]]; then
                log "ERROR" "[$server_name] Missing database field: $field"
                ((errors++))
            fi
        done
    else
        log "ERROR" "[$server_name] Database configuration is missing"
        ((errors++))
    fi
    
    return $errors
}

# Validate backup configuration
validate_backup_config() {
    local server_name="$1"
    local backup_config="$2"
    local errors=0
    
    local backup_mode=$(echo "$backup_config" | jq -r '.mode // "all"')
    
    case "$backup_mode" in
        "all"|"exclude")
            # For "all" and "exclude" modes, validate exclude_databases if present
            local exclude_list
            exclude_list=$(echo "$backup_config" | jq -r '.exclude_databases // empty')
            if [[ "$exclude_list" != "null" && "$exclude_list" != "empty" ]]; then
                if ! echo "$backup_config" | jq -e '.exclude_databases | type == "array"' >/dev/null 2>&1; then
                    log "ERROR" "[$server_name] exclude_databases must be an array"
                    ((errors++))
                fi
            fi
            ;;
        "specific")
            # For "specific" mode, databases array is required
            if ! echo "$backup_config" | jq -e '.databases | type == "array"' >/dev/null 2>&1; then
                log "ERROR" "[$server_name] 'databases' array is required for mode 'specific'"
                ((errors++))
            else
                local db_count
                db_count=$(echo "$backup_config" | jq -r '.databases | length')
                if [[ "$db_count" -eq 0 ]]; then
                    log "ERROR" "[$server_name] 'databases' array cannot be empty for mode 'specific'"
                    ((errors++))
                fi
            fi
            ;;
        *)
            log "ERROR" "[$server_name] Invalid backup mode: $backup_mode (must be 'all', 'specific', or 'exclude')"
            ((errors++))
            ;;
    esac
    
    # Validate include_system_databases if present
    local include_system=$(echo "$backup_config" | jq -r '.include_system_databases // empty')
    if [[ "$include_system" != "empty" && "$include_system" != "null" ]]; then
        if ! echo "$backup_config" | jq -e '.include_system_databases | type == "boolean"' >/dev/null 2>&1; then
            log "ERROR" "[$server_name] include_system_databases must be true or false (boolean)"
            ((errors++))
        fi
    fi
    
    return $errors
}

# Validate schedule configuration
validate_schedule_config() {
    local server_name="$1"
    local schedule_config="$2"
    local errors=0
    
    # Validate full_backup_interval if present
    local interval=$(echo "$schedule_config" | jq -r '.full_backup_interval // empty')
    if [[ "$interval" != "empty" && "$interval" != "null" ]]; then
        case "$interval" in
            "manual"|"")
                # Valid manual setting
                ;;
            *d|*h|*m)
                # Validate numeric part
                local number=${interval%[dhm]}
                if ! [[ "$number" =~ ^[0-9]+$ ]] || [[ "$number" -eq 0 ]]; then
                    log "ERROR" "[$server_name] Invalid full_backup_interval: $interval (use format like '7d', '24h', '60m', or 'manual')"
                    ((errors++))
                fi
                ;;
            *)
                log "ERROR" "[$server_name] Invalid full_backup_interval: $interval (use format like '7d', '24h', '60m', or 'manual')"
                ((errors++))
                ;;
        esac
    fi
    
    return $errors
}

# Validate cleanup configuration
validate_cleanup_config() {
    local server_name="$1"
    local cleanup_config="$2"
    local errors=0
    
    # Validate enabled field if present
    local enabled=$(echo "$cleanup_config" | jq -r '.enabled // empty')
    if [[ "$enabled" != "empty" && "$enabled" != "null" ]]; then
        if ! echo "$cleanup_config" | jq -e '.enabled | type == "boolean"' >/dev/null 2>&1; then
            log "ERROR" "[$server_name] cleanup.enabled must be true or false (boolean)"
            ((errors++))
        fi
    fi
    
    # Only validate numeric fields if cleanup is enabled
    if [[ "$enabled" == "true" ]]; then
        # Validate min_full_backups if present
        local min_backups=$(echo "$cleanup_config" | jq -r '.min_full_backups // empty')
        if [[ "$min_backups" != "empty" && "$min_backups" != "null" ]]; then
            if ! [[ "$min_backups" =~ ^[0-9]+$ ]] || [[ "$min_backups" -lt 1 ]]; then
                log "ERROR" "[$server_name] cleanup.min_full_backups must be a positive integer"
                ((errors++))
            fi
        fi
        
        # Validate max_age_days if present
        local max_age=$(echo "$cleanup_config" | jq -r '.max_age_days // empty')
        if [[ "$max_age" != "empty" && "$max_age" != "null" ]]; then
            if ! [[ "$max_age" =~ ^[0-9]+$ ]] || [[ "$max_age" -lt 1 ]]; then
                log "ERROR" "[$server_name] cleanup.max_age_days must be a positive integer"
                ((errors++))
            fi
        fi
    fi
    
    return $errors
}

# Test direct database connection
test_direct_db_connection() {
    local server_name="$1"
    local db_config="$2"
    
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
    
    log "DEBUG" "[$server_name] Testing direct database connection to $db_host:$db_port"
    
    if timeout 10 mysql -h"$db_host" -P"$db_port" -u"$db_user" -p"$db_password" $ssl_opts -e "SELECT 1;" &>/dev/null; then
        log "INFO" "[$server_name] Direct database connection successful"
        return 0
    else
        log "WARN" "[$server_name] Direct database connection failed"
        return 1
    fi
}

# Test SSH connection
test_ssh_connection() {
    local server_name="$1"
    local server_config="$2"
    
    log "DEBUG" "Testing SSH connection to: $server_name"
    
    local host=$(echo "$server_config" | jq -r '.host // empty')
    local port=$(echo "$server_config" | jq -r '.port // 22')
    local username=$(echo "$server_config" | jq -r '.username // empty')
    local auth_type=$(echo "$server_config" | jq -r '.auth_type // empty')
    
    if [[ -z "$host" || -z "$username" || -z "$auth_type" ]]; then
        log "WARN" "[$server_name] SSH configuration incomplete, skipping SSH test"
        return 0
    fi
    
    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -p $port"
    local ssh_cmd
    
    case "$auth_type" in
        "key")
            local private_key=$(echo "$server_config" | jq -r '.private_key')
            private_key=$(expand_path "$private_key")
            ssh_cmd="ssh $ssh_opts -i $private_key $username@$host 'echo \"SSH connection successful\"'"
            ;;
        "password")
            log "WARN" "[$server_name] Cannot test password authentication in batch mode"
            return 0
            ;;
    esac
    
    if eval "$ssh_cmd" &>/dev/null; then
        log "INFO" "[$server_name] SSH connection successful"
        return 0
    else
        log "ERROR" "[$server_name] SSH connection failed"
        return 1
    fi
}

# Test database connection through SSH
test_ssh_db_connection() {
    local server_name="$1"
    local server_config="$2"
    
    log "DEBUG" "Testing database connection through SSH for: $server_name"
    
    local db_config=$(echo "$server_config" | jq -r '.database')
    local db_host=$(echo "$db_config" | jq -r '.host')
    local db_port=$(echo "$db_config" | jq -r '.port // 3306')
    local db_user=$(echo "$db_config" | jq -r '.username')
    local db_password=$(echo "$db_config" | jq -r '.password')
    
    # SSH configuration
    local host=$(echo "$server_config" | jq -r '.host // empty')
    local port=$(echo "$server_config" | jq -r '.port // 22')
    local username=$(echo "$server_config" | jq -r '.username // empty')
    local auth_type=$(echo "$server_config" | jq -r '.auth_type // empty')
    
    if [[ -z "$host" || -z "$username" || -z "$auth_type" ]]; then
        log "WARN" "[$server_name] SSH configuration incomplete, skipping SSH database test"
        return 0
    fi
    
    # Build SSL options based on configuration
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
    
    local ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -p $port"
    local mysql_test_cmd="mysql -h$db_host -P$db_port -u$db_user -p$db_password $ssl_opts -e 'SELECT 1;' &>/dev/null"
    local ssh_cmd
    
    case "$auth_type" in
        "key")
            local private_key=$(echo "$server_config" | jq -r '.private_key')
            private_key=$(expand_path "$private_key")
            ssh_cmd="ssh $ssh_opts -i $private_key $username@$host '$mysql_test_cmd'"
            ;;
        "password")
            log "WARN" "[$server_name] Cannot test database connection through password SSH in batch mode"
            return 0
            ;;
    esac
    
    if eval "$ssh_cmd"; then
        log "INFO" "[$server_name] Database connection through SSH successful"
        return 0
    else
        log "ERROR" "[$server_name] Database connection through SSH failed"
        return 1
    fi
}

# Test backup directory permissions
test_backup_directory() {
    local server_name="$1"
    local server_config="$2"
    
    local backup_path=$(echo "$server_config" | jq -r '.backup_path // "backups"')
    
    # Make backup path absolute if relative
    if [[ ! "$backup_path" =~ ^/.* ]]; then
        backup_path="${SCRIPT_DIR}/${backup_path}"
    fi
    
    local local_backup_dir="$backup_path/$server_name"
    
    log "DEBUG" "Testing backup directory for: $server_name at $local_backup_dir"
    
    if mkdir -p "$local_backup_dir" 2>/dev/null; then
        if [[ -w "$local_backup_dir" ]]; then
            log "INFO" "[$server_name] Local backup directory is writable: $local_backup_dir"
        else
            log "ERROR" "[$server_name] Local backup directory is not writable: $local_backup_dir"
            return 1
        fi
    else
        log "ERROR" "[$server_name] Cannot create local backup directory: $local_backup_dir"
        return 1
    fi
    
    return 0
}

# Generate sample configuration with new features
generate_sample_config() {
    local sample_file="${SCRIPT_DIR}/server_config.sample.json"
    
    log "INFO" "Generating sample configuration file: $sample_file"
    
    cat > "$sample_file" << 'EOF'
{
  "local_database_server": {
    "backup_connection": "local",
    "backup_path": "backups",
    "database": {
      "host": "192.168.1.100",
      "port": 3306,
      "username": "backup_user",
      "password": "secure_db_password",
      "ssl_mode": "auto"
    },
    "backup_config": {
      "mode": "all",
      "exclude_databases": ["test", "temp_db"],
      "include_system_databases": false
    },
    "schedule": {
      "full_backup_interval": "7d",
      "comment": "Options: 1d (daily), 7d (weekly), 30d (monthly), 12h (every 12 hours), or 'manual'"
    },
    "cleanup": {
      "enabled": true,
      "min_full_backups": 2,
      "max_age_days": 30,
      "comment": "Keep at least 2 full backups and delete those older than 30 days"
    }
  },
  "remote_ssh_key_server": {
    "backup_connection": "remote",
    "host": "192.168.1.101",
    "port": 22,
    "username": "backup_user",
    "auth_type": "key",
    "private_key": "~/.ssh/id_rsa",
    "backup_path": "backups",
    "database": {
      "host": "localhost",
      "port": 3306,
      "username": "db_backup_user",
      "password": "secure_db_password",
      "ssl_mode": "auto"
    },
    "backup_config": {
      "mode": "specific",
      "databases": ["production_app", "user_data", "analytics"],
      "include_system_databases": false
    },
    "schedule": {
      "full_backup_interval": "1d",
      "comment": "Daily backups for production systems"
    },
    "cleanup": {
      "enabled": true,
      "min_full_backups": 3,
      "max_age_days": 90,
      "comment": "Keep at least 3 full backups and delete those older than 90 days"
    }
  },
  "auto_detect_server": {
    "backup_connection": "auto",
    "host": "192.168.1.102",
    "port": 22,
    "username": "backup_user",
    "auth_type": "password",
    "password": "secure_ssh_password",
    "backup_path": "backups",
    "database": {
      "host": "localhost",
      "port": 3306,
      "username": "db_backup_user",
      "password": "secure_db_password",
      "ssl_mode": "auto"
    },
    "backup_config": {
      "mode": "exclude",
      "exclude_databases": ["temp", "cache", "session_data"],
      "include_system_databases": false
    },
    "schedule": {
      "full_backup_interval": "manual",
      "comment": "Manual backups only - no automatic scheduling"
    },
    "cleanup": {
      "enabled": false,
      "comment": "Cleanup disabled - manual maintenance required"
    }
  }
}
EOF
    
    log "INFO" "Sample configuration generated. Copy and modify it as needed."
    echo ""
    log "INFO" "Backup Connection Types:"
    echo "  • local: Direct database connection from local server (no SSH)"
    echo "  • remote: SSH tunnel to remote server then database connection"
    echo "  • auto: Automatic detection based on configuration and connectivity"
    echo ""
    log "INFO" "Configuration modes:"
    echo "  • backup_connection: 'local', 'remote', or 'auto'"
    echo "  • force_ssh: Legacy option (use backup_connection instead)"
    echo ""
    log "INFO" "Backup modes:"
    echo "  • all: Backup all databases (optionally exclude some)"
    echo "  • specific: Backup only specified databases"
    echo "  • exclude: Backup all except specified databases"
    echo ""
    log "INFO" "Schedule configuration:"
    echo "  • full_backup_interval: '1d', '7d', '30d', '12h', or 'manual'"
    echo "  • manual: No automatic scheduling (default if not specified)"
    echo "  • Time formats: d=days, h=hours, m=minutes"
    echo ""
    log "INFO" "Cleanup configuration:"
    echo "  • enabled: true/false - Enable automatic cleanup"
    echo "  • min_full_backups: Minimum number of full backups to keep"
    echo "  • max_age_days: Delete backups older than this many days"
    echo "  • Cleanup preserves backup chain integrity"
    echo ""
    log "INFO" "SSL modes:"
    echo "  • auto: Let MySQL/MariaDB auto-negotiate SSL (default)"
    echo "  • disable: Disable SSL connections"
    echo "  • require: Require SSL connections"
    echo "  • verify_ca: Require SSL with CA verification"
    echo "  • verify_identity: Require SSL with full certificate verification"
    echo ""
    log "INFO" "Backup options:"
    echo "  • exclude_databases: Array of database names to exclude"
    echo "  • databases: Array of database names to include (specific mode)"
    echo "  • include_system_databases: Include mysql, sys databases (default: false)"
}

# Main validation function
validate_all() {
    local total_errors=0
    local connection_test="${1:-false}"
    
    log "INFO" "Starting configuration validation..."
    
    # Check dependencies
    if ! check_dependencies; then
        return 1
    fi
    
    # Validate JSON
    if ! validate_json; then
        return 1
    fi
    
    # Read and validate each server configuration
    local servers
    servers=$(jq -r '. | to_entries[] | @base64' "$CONFIG_FILE")
    
    if [[ -z "$servers" ]]; then
        log "ERROR" "No servers found in configuration file"
        return 1
    fi
    
    while IFS= read -r server_data; do
        [[ -z "$server_data" ]] && continue
        
        local server_info
        server_info=$(echo "$server_data" | base64 --decode)
        local server_name=$(echo "$server_info" | jq -r '.key')
        local server_config=$(echo "$server_info" | jq -r '.value')
        
        log "INFO" "Validating server: $server_name"
        
        # Validate configuration structure
        if ! validate_server_config "$server_name" "$server_config"; then
            ((total_errors++))
            continue
        fi
        
        # Test backup directory
        if ! test_backup_directory "$server_name" "$server_config"; then
            ((total_errors++))
        fi
        
        # Test connections if requested
        if [[ "$connection_test" == "true" ]]; then
            local db_config=$(echo "$server_config" | jq -r '.database')
            local force_ssh=$(echo "$server_config" | jq -r '.force_ssh // false')
            
            # Test direct database connection
            if [[ "$force_ssh" != "true" ]]; then
                if test_direct_db_connection "$server_name" "$db_config"; then
                    log "INFO" "[$server_name] Recommended connection method: DIRECT"
                else
                    log "INFO" "[$server_name] Direct connection failed, SSH tunnel required"
                    if ! test_ssh_connection "$server_name" "$server_config"; then
                        ((total_errors++))
                    elif ! test_ssh_db_connection "$server_name" "$server_config"; then
                        ((total_errors++))
                    fi
                fi
            else
                log "INFO" "[$server_name] Force SSH mode enabled"
                if ! test_ssh_connection "$server_name" "$server_config"; then
                    ((total_errors++))
                elif ! test_ssh_db_connection "$server_name" "$server_config"; then
                    ((total_errors++))
                fi
            fi
        fi
        
    done <<< "$servers"
    
    if [[ $total_errors -eq 0 ]]; then
        log "INFO" "All validations passed successfully!"
        return 0
    else
        log "ERROR" "Validation completed with $total_errors error(s)"
        return 1
    fi
}

# Usage function
usage() {
    echo "Usage: $0 [option]"
    echo "Options:"
    echo "  validate          - Validate configuration (default)"
    echo "  test              - Validate and test connections"
    echo "  sample            - Generate sample configuration"
    echo "  dependencies      - Check dependencies only"
    echo "  help              - Show this help"
    echo ""
    echo "New Configuration Features:"
    echo "  force_ssh: true/false - Force SSH tunnel usage"
    echo "  backup_path: 'path'   - Local backup storage path"
    echo "  SSH config optional   - Only needed for tunneling"
}

# Main execution
main() {
    local action="${1:-validate}"
    
    # Start logging session
    log_session_start "validate_config.sh" "Action: $action"
    
    local exit_code=0
    
    case "$action" in
        "validate")
            if ! validate_all false; then
                exit_code=1
            fi
            ;;
        "test")
            if ! validate_all true; then
                exit_code=1
            fi
            ;;
        "sample")
            generate_sample_config
            ;;
        "dependencies")
            if ! check_dependencies; then
                exit_code=1
            fi
            ;;
        "help"|"-h"|"--help")
            usage
            ;;
        *)
            log_error "Unknown option: $action"
            usage
            exit_code=1
            ;;
    esac
    
    log_session_end "validate_config.sh" $exit_code
    exit $exit_code
}

main "$@"
