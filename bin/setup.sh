#!/bin/bash

# MariaDB Auto-Backup Setup Script
# This script prepares the environment and sets up cron jobs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/conf/server_config.json"

# Source the centralized logging utility
source "${SCRIPT_DIR}/lib/logging_utils.sh"

# Legacy log function for backward compatibility
log() {
    local level="$1"
    shift
    write_log "$level" "$*" "setup.sh"
}

# Check and install dependencies
install_dependencies() {
    log_info "Checking and installing system dependencies"
    
    local missing_deps=()
    
    # Check for jq
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    # Check for MySQL/MariaDB client
    if ! command -v mariadb &> /dev/null && ! command -v mysql &> /dev/null; then
        missing_deps+=("mariadb")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_warning "Missing dependencies: ${missing_deps[*]}"
        
        # Detect package manager and install
        if command -v brew &> /dev/null; then
            log_info "Installing dependencies using Homebrew"
            for dep in "${missing_deps[@]}"; do
                case "$dep" in
                    "mariadb")
                        log_command "brew install mariadb"
                        ;;
                    *)
                        log_command "brew install $dep"
                        ;;
                esac
            done
        elif command -v apt-get &> /dev/null; then
            log_info "Installing dependencies using apt-get"
            log_command "sudo apt-get update"
            for dep in "${missing_deps[@]}"; do
                case "$dep" in
                    "mariadb")
                        log_command "sudo apt-get install -y mariadb-client"
                        ;;
                    *)
                        log_command "sudo apt-get install -y $dep"
                        ;;
                esac
            done
        elif command -v yum &> /dev/null; then
            log_info "Installing dependencies using yum"
            for dep in "${missing_deps[@]}"; do
                case "$dep" in
                    "mariadb")
                        log_command "sudo yum install -y mariadb"
                        ;;
                    *)
                        log_command "sudo yum install -y $dep"
                        ;;
                esac
            done
        else
            log_error "Cannot detect package manager. Please install manually: ${missing_deps[*]}"
            return 1
        fi
    fi
    
    # Check for optional dependencies
    if ! command -v sshpass &> /dev/null; then
        log_warning "sshpass not found - install it if you need password SSH authentication"
        if command -v brew &> /dev/null; then
            log_info "To install: brew install sshpass"
        elif command -v apt-get &> /dev/null; then
            log_info "To install: sudo apt-get install sshpass"
        elif command -v yum &> /dev/null; then
            log_info "To install: sudo yum install sshpass"
        fi
    fi
    
    log_success "Dependencies installation completed"
}

# Create directory structure
create_directories() {
    log "INFO" "Creating directory structure..."
    
    # Create essential directories
    mkdir -p "${SCRIPT_DIR}/logs"
    mkdir -p "${SCRIPT_DIR}/backups"
    mkdir -p "${SCRIPT_DIR}/keys"
    mkdir -p "${SCRIPT_DIR}/conf"
    
    # Set proper permissions
    chmod 755 "${SCRIPT_DIR}/logs"
    chmod 755 "${SCRIPT_DIR}/backups"
    chmod 700 "${SCRIPT_DIR}/keys"
    chmod 755 "${SCRIPT_DIR}/conf"
    
    log "INFO" "Directory structure created successfully"
}

# Set up configuration
setup_configuration() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "INFO" "Creating sample configuration..."
        ./lib/validate_config.sh sample
        
        # Copy sample to actual config file
        local sample_file="${SCRIPT_DIR}/conf/server_config.sample.json"
        if [[ -f "$sample_file" ]]; then
            cp "$sample_file" "$CONFIG_FILE"
            log "INFO" "Configuration file created: $CONFIG_FILE"
        else
            log "ERROR" "Sample configuration file not found: $sample_file"
            return 1
        fi
        
        log "WARN" "Please edit conf/server_config.json with your actual server details"
        return 1
    else
        log "INFO" "Configuration file exists, validating..."
        if ./lib/validate_config.sh validate; then
            log "INFO" "Configuration is valid"
            return 0
        else
            log "ERROR" "Configuration validation failed"
            return 1
        fi
    fi
}

# Set up cron jobs
setup_cron() {
    local cron_setup="${1:-yes}"
    
    if [[ "$cron_setup" != "yes" ]]; then
        log "INFO" "Skipping cron setup as requested"
        return 0
    fi
    
    log "INFO" "Setting up cron jobs..."
    
    # Check if configuration uses new scheduler features
    local has_schedule_config=false
    if [[ -f "$CONFIG_FILE" ]]; then
        if jq -e '.[] | select(.schedule) | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then
            has_schedule_config=true
        fi
    fi
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "backup"; then
        log "WARN" "Backup cron job already exists"
        log "INFO" "Current backup cron jobs:"
        crontab -l 2>/dev/null | grep -i "backup" || true
        
        read -p "Do you want to update the cron job? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Keeping existing cron job"
            return 0
        fi
        
        # Remove existing backup cron jobs
        (crontab -l 2>/dev/null | grep -v "backup") | crontab -
    fi
    
    if [[ "$has_schedule_config" == "true" ]]; then
        # Use new scheduler system
        log "INFO" "Detected schedule configuration - setting up intelligent scheduler"
        echo
        echo "Your configuration includes schedule settings. Choose setup method:"
        echo "  1) Use intelligent scheduler (checks schedule and runs when needed)"
        echo "  2) Use traditional system (daily at midnight, full on 1st of month)"
        echo
        read -p "Choose option (1/2) [1]: " -n 1 -r
        echo
        
        if [[ "${REPLY:-1}" == "2" ]]; then
            # Traditional system
            local backup_script="${SCRIPT_DIR}/backup.sh"
            local cron_entry="0 0 * * * $backup_script >/dev/null 2>&1"
            (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
            
            log "INFO" "Traditional cron job added:"
            log "INFO" "  Daily backup at midnight: $cron_entry"
            log "INFO" "  Full backup: 1st of each month"
            log "INFO" "  Incremental backup: All other days"
        else
            # Intelligent scheduler
            echo "Choose scheduler frequency:"
            echo "  1) Daily (recommended for production)"
            echo "  2) Hourly (for high-change databases)"
            echo "  3) Weekly (for low-change systems)"
            echo "  4) Custom schedule"
            echo
            read -p "Choose option (1/2/3/4) [1]: " -n 1 -r
            echo
            
            case "${REPLY:-1}" in
                "2")
                    "${SCRIPT_DIR}/bin/setup_cron.sh" hourly
                    ;;
                "3")
                    "${SCRIPT_DIR}/bin/setup_cron.sh" weekly
                    ;;
                "4")
                    echo "Enter custom cron expression (e.g., '0 */6 * * *' for every 6 hours):"
                    read -r custom_schedule
                    "${SCRIPT_DIR}/bin/setup_cron.sh" custom "$custom_schedule"
                    ;;
                *)
                    "${SCRIPT_DIR}/bin/setup_cron.sh" daily
                    ;;
            esac
            
            log "INFO" "Intelligent scheduler configured successfully"
            log "INFO" "The scheduler will:"
            log "INFO" "  - Check your schedule configuration automatically"
            log "INFO" "  - Run full backups based on your interval settings"
            log "INFO" "  - Perform automatic cleanup based on your retention policies"
        fi
    else
        # Traditional system (no schedule config detected)
        local backup_script="${SCRIPT_DIR}/backup.sh"
        local cron_entry="0 0 * * * $backup_script >/dev/null 2>&1"
        (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
        
        log "INFO" "Traditional cron job added:"
        log "INFO" "  Daily backup at midnight: $cron_entry"
        log "INFO" "  Full backup: 1st of each month"
        log "INFO" "  Incremental backup: All other days"
        log "INFO" ""
        log "INFO" "💡 Tip: Add 'schedule' and 'cleanup' sections to your config"
        log "INFO" "   to use the intelligent scheduler with flexible intervals!"
    fi
}

# Set permissions
set_permissions() {
    log "INFO" "Setting file permissions..."
    
    # Make scripts executable
    chmod +x "${SCRIPT_DIR}/mariadb_backup.sh"
    chmod +x "${SCRIPT_DIR}/lib/validate_config.sh"
    chmod +x "${SCRIPT_DIR}/discover_databases.sh"
    chmod +x "${SCRIPT_DIR}/backup.sh"
    
    # Secure configuration file
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    
    # Secure keys directory
    if [[ -d "${SCRIPT_DIR}/keys" ]]; then
        chmod 700 "${SCRIPT_DIR}/keys"
        find "${SCRIPT_DIR}/keys" -type f -exec chmod 600 {} \; 2>/dev/null || true
    fi
    
    log "INFO" "File permissions set successfully"
}

# Test setup
test_setup() {
    log "INFO" "Testing setup..."
    
    # Test configuration
    if ! ./lib/validate_config.sh test; then
        log "ERROR" "Setup test failed - please check configuration"
        return 1
    fi
    
    # Test backup execution (dry run)
    log "INFO" "Testing backup execution..."
    if ./backup.sh --test; then
        log "INFO" "Setup test completed successfully"
        return 0
    else
        log "ERROR" "Backup test failed"
        return 1
    fi
}

# Display setup summary
show_summary() {
    log "INFO" "Setup completed successfully!"
    echo ""
    echo "📁 Directory Structure:"
    echo "  ${SCRIPT_DIR}/"
    echo "  ├── backup.sh              # Main execution script"
    echo "  ├── mariadb_backup.sh       # Core backup logic"
    echo "  ├── lib/validate_config.sh      # Configuration validation"
    echo "  ├── discover_databases.sh   # Database discovery tool"
    echo "  ├── conf/                   # Configuration files"
    echo "  │   └── server_config.json  # Your server configuration"
    echo "  ├── logs/                   # Backup logs"
    echo "  ├── backups/                # Local backup storage"
    echo "  └── keys/                   # SSH private keys"
    echo ""
    echo "🚀 Quick Start:"
    echo "  1. Edit configuration:      nano conf/server_config.json"
    echo "  2. Validate setup:          ./lib/validate_config.sh test"
    echo "  3. Discover databases:      ./discover_databases.sh list-servers"
    echo "  4. Run manual backup:       ./backup.sh"
    echo "  5. View logs:              tail -f logs/backup_\$(date +%Y%m%d).log"
    echo ""
    echo "⏰ Automated Schedule:"
    echo "  • Daily backups at midnight (00:00)"
    echo "  • Full backup on 1st of each month"
    echo "  • Incremental backup on all other days"
    echo "  • 30-day retention policy"
    echo ""
    echo "🔧 Configuration Tools:"
    echo "  • ./discover_databases.sh discover <server>     # See available databases"
    echo "  • ./lib/validate_config.sh sample                   # Generate sample config"
    echo "  • ./backup.sh --test                           # Test backup without execution"
}

# Main setup function
main() {
    local skip_cron=false
    local skip_deps=false
    local skip_test=false
    
    # Start logging session
    log_session_start "setup.sh" "MariaDB Auto-Backup Setup (Arguments: $*)"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-cron)
                skip_cron=true
                shift
                ;;
            --no-deps)
                skip_deps=true
                shift
                ;;
            --no-test)
                skip_test=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --no-cron    Skip cron job setup"
                echo "  --no-deps    Skip dependency installation"
                echo "  --no-test    Skip setup testing"
                echo "  --help,-h    Show this help"
                log_session_end "setup.sh" 0
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                log_session_end "setup.sh" 1
                exit 1
                ;;
        esac
    done
    
    log_info "Starting MariaDB Auto-Backup setup..."
    
    # Install dependencies
    if [[ "$skip_deps" != "true" ]]; then
        if ! install_dependencies; then
            log_error "Dependency installation failed"
            log_session_end "setup.sh" 1
            exit 1
        fi
    fi
    
    # Create directories
    create_directories
    
    # Set permissions
    set_permissions
    
    # Setup configuration
    if ! setup_configuration; then
        log_warning "Please configure conf/server_config.json and run setup again"
        log_session_end "setup.sh" 1
        exit 1
    fi
    
    # Setup cron
    if [[ "$skip_cron" != "true" ]]; then
        setup_cron "yes"
    fi
    
    # Test setup
    if [[ "$skip_test" != "true" ]]; then
        if ! test_setup; then
            log_error "Setup test failed"
            log_session_end "setup.sh" 1
            exit 1
        fi
    fi
    
    # Show summary
    show_summary
    
    log_session_end "setup.sh" 0
}

main "$@"
