#!/bin/bash

# Cron Job Setup Helper for MariaDB Backup Scheduler
# Usage: ./setup_cron.sh [hourly|daily|weekly|custom "cron_expression"]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEDULER_SCRIPT="$SCRIPT_DIR/backup_scheduler.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 [hourly|daily|weekly|custom \"cron_expression\"]"
    echo ""
    echo "Examples:"
    echo "  $0 daily                    # Run daily at 2 AM"
    echo "  $0 weekly                   # Run weekly on Sunday at 2 AM"
    echo "  $0 hourly                   # Run every hour"
    echo "  $0 custom \"0 */6 * * *\"     # Run every 6 hours"
    echo "  $0 custom \"30 1 * * 0\"      # Run every Sunday at 1:30 AM"
    echo ""
    echo "To remove the cron job: $0 remove"
    echo "To view current cron job: $0 status"
}

get_cron_expression() {
    local schedule_type="$1"
    
    case "$schedule_type" in
        "hourly")
            echo "0 * * * *"
            ;;
        "daily")
            echo "0 2 * * *"
            ;;
        "weekly")
            echo "0 2 * * 0"
            ;;
        "custom")
            echo "$2"
            ;;
        *)
            echo ""
            ;;
    esac
}

add_cron_job() {
    local cron_expression="$1"
    local cron_command="$SCHEDULER_SCRIPT check >/dev/null 2>&1"
    local cron_line="$cron_expression $cron_command"
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "$SCHEDULER_SCRIPT"; then
        echo -e "${YELLOW}Warning: Cron job for backup scheduler already exists${NC}"
        echo "Current cron job:"
        crontab -l 2>/dev/null | grep "$SCHEDULER_SCRIPT"
        echo ""
        read -p "Do you want to replace it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Operation cancelled."
            exit 0
        fi
        remove_cron_job
    fi
    
    # Add new cron job
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    
    echo -e "${GREEN}✓ Cron job added successfully${NC}"
    echo "Schedule: $cron_expression"
    echo "Command: $cron_command"
}

remove_cron_job() {
    if crontab -l 2>/dev/null | grep -q "$SCHEDULER_SCRIPT"; then
        crontab -l 2>/dev/null | grep -v "$SCHEDULER_SCRIPT" | crontab -
        echo -e "${GREEN}✓ Cron job removed successfully${NC}"
    else
        echo -e "${YELLOW}No cron job found for backup scheduler${NC}"
    fi
}

show_status() {
    echo -e "${BLUE}Current backup scheduler cron job status:${NC}"
    
    if crontab -l 2>/dev/null | grep -q "$SCHEDULER_SCRIPT"; then
        echo -e "${GREEN}✓ Cron job is configured${NC}"
        echo "Current schedule:"
        crontab -l 2>/dev/null | grep "$SCHEDULER_SCRIPT"
        
        # Show next run time if possible
        if command -v crontab >/dev/null 2>&1; then
            echo ""
            echo "To view detailed cron schedule, use: crontab -l"
        fi
    else
        echo -e "${YELLOW}⚠ No cron job configured${NC}"
        echo "Use '$0 daily' or similar to set up automated backups"
    fi
    
    echo ""
    echo -e "${BLUE}Recent backup scheduler logs:${NC}"
    if [[ -f "$SCRIPT_DIR/logs/info.log" ]]; then
        echo "Last 5 scheduler entries:"
        grep "backup_scheduler" "$SCRIPT_DIR/logs/info.log" | tail -5 || echo "No recent scheduler activity"
    else
        echo "No log files found"
    fi
}

validate_cron_expression() {
    local cron_expr="$1"
    
    # Basic validation - should have 5 fields
    local field_count
    field_count=$(echo "$cron_expr" | wc -w)
    
    if [[ "$field_count" -ne 5 ]]; then
        echo -e "${RED}Error: Cron expression must have exactly 5 fields (minute hour day month weekday)${NC}"
        echo "Example: \"0 2 * * *\" for daily at 2 AM"
        return 1
    fi
    
    return 0
}

# Main execution
case "${1:-}" in
    "hourly"|"daily"|"weekly")
        schedule_type="$1"
        cron_expr=$(get_cron_expression "$schedule_type")
        
        echo -e "${BLUE}Setting up $schedule_type backup schedule${NC}"
        echo "Cron expression: $cron_expr"
        echo "This will run: $SCHEDULER_SCRIPT check"
        echo ""
        
        add_cron_job "$cron_expr"
        ;;
    "custom")
        if [[ $# -lt 2 ]]; then
            echo -e "${RED}Error: Custom schedule requires a cron expression${NC}"
            print_usage
            exit 1
        fi
        
        cron_expr="$2"
        
        if ! validate_cron_expression "$cron_expr"; then
            exit 1
        fi
        
        echo -e "${BLUE}Setting up custom backup schedule${NC}"
        echo "Cron expression: $cron_expr"
        echo "This will run: $SCHEDULER_SCRIPT check"
        echo ""
        
        add_cron_job "$cron_expr"
        ;;
    "remove")
        echo -e "${BLUE}Removing backup scheduler cron job${NC}"
        remove_cron_job
        ;;
    "status")
        show_status
        ;;
    "")
        echo -e "${RED}Error: No schedule type specified${NC}"
        print_usage
        exit 1
        ;;
    *)
        echo -e "${RED}Error: Invalid schedule type: $1${NC}"
        print_usage
        exit 1
        ;;
esac

echo ""
echo -e "${BLUE}Tip:${NC} You can manually run the scheduler with: $SCHEDULER_SCRIPT check"
echo -e "${BLUE}Tip:${NC} View logs in: $SCRIPT_DIR/logs/"
