#!/bin/bash

# MariaDB Auto-Backup Setup Script
# This script prepares the environment and sets up cron jobs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/server_config.json"

# Source the centralized logging utility
source "${SCRIPT_DIR}/logging_utils.sh"

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
    
    # Set proper permissions
    chmod 755 "${SCRIPT_DIR}/logs"
    chmod 755 "${SCRIPT_DIR}/backups"
    chmod 700 "${SCRIPT_DIR}/keys"
    
    log "INFO" "Directory structure created successfully"
}

# Set up configuration
setup_configuration() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "INFO" "Creating sample configuration..."
        ./validate_config.sh sample
        log "WARN" "Please edit server_config.json with your actual server details"
        return 1
    else
        log "INFO" "Configuration file exists, validating..."
        if ./validate_config.sh validate; then
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
    
    local backup_script="${SCRIPT_DIR}/backup.sh"
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "mariadb.*backup"; then
        log "WARN" "MariaDB backup cron job already exists"
        log "INFO" "Current cron jobs:"
        crontab -l 2>/dev/null | grep -i "backup\|mariadb" || true
        
        read -p "Do you want to update the cron job? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Keeping existing cron job"
            return 0
        fi
        
        # Remove existing backup cron jobs
        (crontab -l 2>/dev/null | grep -v "mariadb.*backup") | crontab -
    fi
    
    # Add new cron job
    local cron_entry="0 0 * * * $backup_script >/dev/null 2>&1"
    (crontab -l 2>/dev/null; echo "$cron_entry") | crontab -
    
    log "INFO" "Cron job added successfully:"
    log "INFO" "  Daily backup at midnight: $cron_entry"
    log "INFO" "  Full backup: 1st of each month"
    log "INFO" "  Incremental backup: All other days"
}

# Set permissions
set_permissions() {
    log "INFO" "Setting file permissions..."
    
    # Make scripts executable
    chmod +x "${SCRIPT_DIR}/mariadb_backup.sh"
    chmod +x "${SCRIPT_DIR}/validate_config.sh"
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
    if ! ./validate_config.sh test; then
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
    echo "  ├── validate_config.sh      # Configuration validation"
    echo "  ├── discover_databases.sh   # Database discovery tool"
    echo "  ├── server_config.json      # Your server configuration"
    echo "  ├── logs/                   # Backup logs"
    echo "  ├── backups/                # Local backup storage"
    echo "  └── keys/                   # SSH private keys"
    echo ""
    echo "🚀 Quick Start:"
    echo "  1. Edit configuration:      nano server_config.json"
    echo "  2. Validate setup:          ./validate_config.sh test"
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
    echo "  • ./validate_config.sh sample                   # Generate sample config"
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
        log_warning "Please configure server_config.json and run setup again"
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
