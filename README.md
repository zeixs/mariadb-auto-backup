# 🗄️ MariaDB Auto-Backup System

A comprehensive, production-ready MariaDB/MySQL backup solution with smart connection handling, flexible database selection, and automated scheduling.

## ✨ Features

- **🔄 Full & Incremental Backups** - Monthly full, daily incremental backups
- **🎯 Selective Database Backup** - Choose specific databases per server
- **🔌 Smart Connection Detection** - Automatic fallback between direct and SSH connections
- **🔑 Multiple Authentication** - SSH key and password authentication support
- **📦 Local Storage** - All backups stored locally with organized structure
- **⚡ Intelligent Restore** - Auto-detection of backup chains with point-in-time recovery
- **⏰ Automated Scheduling** - Cron-based daily execution
- **🛡️ Production Ready** - Comprehensive error handling and logging
- **🔧 Easy Configuration** - JSON-based configuration with validation tools

## 🚀 Quick Start

### 1. Setup
```bash
# Clone and setup the environment
./setup.sh

# Edit configuration with your server details
nano server_config.json
```

### 2. Configuration
```json
{
  "local_server": {
    "backup_connection": "local",
    "database": {
      "host": "192.168.1.100",
      "username": "db_user",
      "password": "secure_password",
      "ssl_mode": "auto"
    },
    "backup_config": {
      "mode": "specific",
      "databases": ["app_db", "user_data", "analytics"]
    }
  },
  "remote_server": {
    "backup_connection": "remote",
    "host": "192.168.1.101",
    "username": "backup_user",
    "auth_type": "key",
    "private_key": "~/.ssh/id_rsa",
    "database": {
      "host": "localhost",
      "username": "db_user",
      "password": "secure_password",
      "ssl_mode": "auto"
    },
    "backup_config": {
      "mode": "all",
      "exclude_databases": ["test", "temp"]
    }
  }
}
```

### 3. Run
```bash
# Test configuration
./backup.sh test

# Run backup
./backup.sh

# Check status
./backup.sh status
```

## 📋 Configuration Guide

### Server Configuration

Each server in `server_config.json` supports:

#### Basic Settings
- `backup_connection` - Connection type: "local", "remote", or "auto" (default: "auto")
- `host` - Server hostname/IP (required for remote connections)
- `port` - SSH port (default: 22, for remote connections)
- `username` - SSH username (for remote connections)
- `auth_type` - "key" or "password" (for remote connections)
- `private_key` - Path to SSH private key (for key auth)
- `password` - SSH password (for password auth)
- `backup_path` - Local backup directory (default: "backups")
- `force_ssh` - Legacy option, use `backup_connection` instead

#### Connection Types
- **`local`** - Direct database connection from local server (no SSH required)
- **`remote`** - SSH tunnel to remote server, then database connection (SSH config required)
- **`auto`** - Automatic detection based on configuration and connectivity (default)

#### Database Settings
- `database.host` - Database host
- `database.port` - Database port (default: 3306)
- `database.username` - Database username
- `database.password` - Database password
- `database.ssl_mode` - SSL connection mode (see SSL Configuration below)

#### SSL Configuration

The `ssl_mode` option controls how SSL/TLS connections are handled:

- **`auto`** (default) - Let MySQL/MariaDB auto-negotiate SSL
- **`disable`** - Disable SSL connections (`--skip-ssl`)
- **`require`** - Require SSL connections (`--ssl-mode=REQUIRED`)
- **`verify_ca`** - Require SSL with CA verification (`--ssl-mode=VERIFY_CA`)
- **`verify_identity`** - Require SSL with full certificate verification (`--ssl-mode=VERIFY_IDENTITY`)

**Example:**
```json
"database": {
  "host": "192.168.1.100",
  "port": 3306,
  "username": "backup_user",
  "password": "secure_password",
  "ssl_mode": "disable"
}
```

**When to use each mode:**
- Use `disable` for local networks or when server SSL is misconfigured
- Use `auto` for most standard configurations (default)
- Use `require` for secure remote connections
- Use `verify_ca` or `verify_identity` for high-security environments

#### Backup Configuration
- `backup_config.mode` - Backup mode: "all", "specific", or "exclude"
- `backup_config.databases` - Array of database names (for "specific" mode)
- `backup_config.exclude_databases` - Array of databases to exclude
- `backup_config.include_system_databases` - Include system DBs (default: false)

### Backup Modes

#### 1. All Databases (with exclusions)
```json
"backup_config": {
  "mode": "all",
  "exclude_databases": ["test", "temp_db"],
  "include_system_databases": false
}
```

#### 2. Specific Databases Only
```json
"backup_config": {
  "mode": "specific", 
  "databases": ["production_app", "user_data", "analytics"],
  "include_system_databases": false
}
```

#### 3. All Except Specified
```json
"backup_config": {
  "mode": "exclude",
  "exclude_databases": ["temp", "cache", "test_data"],
  "include_system_databases": false
}
```

## 🛠️ Tools & Scripts

### Main Scripts

| Script | Purpose |
|--------|---------|
| `setup.sh` | Environment setup and cron configuration |
| `backup.sh` | Main execution script with validation |
| `restore.sh` | Intelligent backup restoration with auto-detection |
| `validate_config.sh` | Configuration validation and testing |
| `discover_databases.sh` | Database discovery and config generation |

### Discovery Tool

```bash
# List configured servers
./discover_databases.sh list-servers

# Discover databases on a server
./discover_databases.sh discover server1

# Generate configuration snippets
./discover_databases.sh generate server1 specific "app_db,user_db"
```

### Validation Tool

```bash
# Validate configuration
./validate_config.sh validate

# Test connections
./validate_config.sh test

# Generate sample config
./validate_config.sh sample
```

## 📁 Directory Structure

```
mariadb-backup/
├── backup.sh              # Main execution script
├── restore.sh              # Intelligent backup restoration
├── setup.sh               # Setup and installation
├── mariadb_backup.sh       # Core backup logic
├── validate_config.sh      # Configuration validation
├── discover_databases.sh   # Database discovery
├── server_config.json      # Your configuration
├── logs/                   # Backup and restore logs
│   └── *.log
├── backups/                # Local backup storage
│   ├── server1/
│   │   ├── database1/
│   │   │   ├── full_backup_database1_20240101_000000.sql.gz
│   │   │   └── incremental_backup_database1_20240102_000000.sql.gz
│   │   └── database2/
│   └── server2/
└── keys/                   # SSH private keys
    └── server_key.pem
```

## ⏰ Backup Schedule

- **Daily Execution**: 00:00 (midnight)
- **Full Backup**: 1st of every month
- **Incremental Backup**: All other days
- **Retention**: 30 days
- **Cleanup**: Automatic removal of old backups

## 🔧 Usage Examples

### Manual Backups
```bash
# Automatic mode (respects schedule)
./backup.sh

# Force full backup
./backup.sh run full

# Force incremental backup
./backup.sh run incremental

# Test mode (no actual backup)
./backup.sh --test
```

### Configuration Management
```bash
# Validate configuration
./validate_config.sh validate

# Test all connections
./validate_config.sh test

# Discover databases
./discover_databases.sh discover production_server

# Generate config for specific databases
./discover_databases.sh generate production_server specific "app,users,orders"
```

### System Status
```bash
# Show comprehensive status
./backup.sh status

# View recent logs
tail -f logs/backup_$(date +%Y%m%d).log

# Check backup sizes
du -sh backups/*/
```

## 🔒 Security Best Practices

### SSH Key Authentication
1. Generate dedicated backup key:
   ```bash
   ssh-keygen -t rsa -b 4096 -f ./keys/backup_key -N ""
   ```

2. Copy to servers:
   ```bash
   ssh-copy-id -i ./keys/backup_key.pub user@server
   ```

3. Configure in `server_config.json`:
   ```json
   "auth_type": "key",
   "private_key": "./keys/backup_key"
   ```

### File Permissions
- Configuration file: `600` (owner read/write only)
- SSH keys: `600` (owner read/write only)
- Keys directory: `700` (owner access only)
- Scripts: `755` (owner read/write/execute, others read/execute)

### Database Credentials
- Use dedicated backup user with minimal permissions
- Grant only necessary privileges:
  ```sql
  CREATE USER 'backup_user'@'%' IDENTIFIED BY 'secure_password';
  GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON *.* TO 'backup_user'@'%';
  FLUSH PRIVILEGES;
  ```

## 🚨 Troubleshooting

### Common Issues

#### Connection Failures
```bash
# Test connections manually
./validate_config.sh test

# Check SSH connectivity
ssh -i ./keys/your_key user@server

# Test database access
mysql -h server -u user -p -e "SHOW DATABASES;"
```

#### Permission Errors
```bash
# Fix script permissions
chmod +x *.sh

# Fix key permissions
chmod 600 keys/*
chmod 700 keys/

# Fix config permissions
chmod 600 server_config.json
```

#### Disk Space Issues
```bash
# Check available space
df -h backups/

# Clean old backups manually
find backups/ -name "*.sql.gz" -mtime +30 -delete

# Check backup sizes
du -sh backups/*/
```

### Log Analysis
```bash
# View today's log
tail -f logs/backup_$(date +%Y%m%d).log

# Search for errors
grep "ERROR" logs/backup_*.log

# View connection methods used
grep "connection method" logs/backup_*.log
```

## 🔄 Backup Types

### Full Backup
- Complete database dump
- Run on 1st of each month
- Creates baseline for incremental backups
- Includes all data, structure, and metadata

### Incremental Backup
- Contains changes since last backup
- Run daily (except 1st of month)
- Smaller size, faster execution
- Requires full backup as baseline

### Smart Connection Detection
The system automatically chooses the best connection method:

1. **Direct Connection**: If database is directly accessible
2. **SSH Tunnel**: If direct connection fails or `force_ssh: true`
3. **Automatic Fallback**: Seamless switching between methods

## 📊 Monitoring

### Backup Status
```bash
# System overview
./backup.sh status

# Detailed server status
./validate_config.sh test

# Recent backup activity
tail -20 logs/backup_$(date +%Y%m%d).log
```

### Cron Job Monitoring
```bash
# View cron jobs
crontab -l

# Check cron logs (varies by system)
tail -f /var/log/cron.log          # Ubuntu/Debian
tail -f /var/log/cron              # CentOS/RHEL
log show --predicate 'eventMessage contains "cron"' --last 1h  # macOS
```

## ⏰ Automated Scheduling & Cleanup

### Schedule Configuration

Add scheduling and cleanup settings to your `server_config.json`:

```json
{
  "production_server": {
    "database": { ... },
    "backup_config": { ... },
    "schedule": {
      "full_backup_interval": "7d",
      "comment": "Options: 1d (daily), 7d (weekly), 30d (monthly), or 'manual'"
    },
    "cleanup": {
      "enabled": true,
      "min_full_backups": 2,
      "max_age_days": 60,
      "comment": "Keep at least 2 full backups and delete those older than 60 days"
    }
  }
}
```

### Backup Scheduler

The backup scheduler handles automated backups and cleanup:

```bash
# Check schedules and run backups if needed
./backup_scheduler.sh check

# Force full backup for all servers
./backup_scheduler.sh force-full

# Run cleanup only (no backups)
./backup_scheduler.sh cleanup
```

### Interval Formats

| Format | Description | Example |
|--------|-------------|---------|
| `1d` | Daily | Every day |
| `7d` | Weekly | Every 7 days |
| `30d` | Monthly | Every 30 days |
| `12h` | Every 12 hours | Twice daily |
| `manual` | Manual only | No automatic scheduling |

### Cron Job Setup

You have two options for automated scheduling:

#### Option 1: Intelligent Scheduler (Recommended)
Use this if you have `schedule` configuration in your JSON:

```bash
# Set up daily backups at 2 AM
./setup_cron.sh daily

# Set up weekly backups on Sunday at 2 AM
./setup_cron.sh weekly

# Set up hourly backups
./setup_cron.sh hourly

# Custom schedule (every 6 hours)
./setup_cron.sh custom "0 */6 * * *"

# View current cron job status
./setup_cron.sh status

# Remove cron job
./setup_cron.sh remove
```

#### Option 2: Traditional Schedule
Use the original setup if you prefer the simple monthly full + daily incremental pattern:

```bash
# This sets up: Daily at midnight, full backup on 1st of month
./setup.sh
```

#### Automatic Detection
When you run `./setup.sh`, it will automatically:
- Detect if you have `schedule` configuration
- Offer to set up the appropriate scheduler
- Guide you through the setup process

**Important**: Don't use both systems simultaneously to avoid conflicts.

### Cleanup Policies

The automatic cleanup system provides intelligent backup management:

#### Cleanup Rules
- **Minimum Retention**: Always keep at least `min_full_backups` full backups
- **Age-Based Cleanup**: Delete backups older than `max_age_days`
- **Orphan Removal**: Remove incremental backups without corresponding full backups
- **Chain Integrity**: Preserve backup chains for valid restore points

#### Cleanup Examples
```json
{
  "cleanup": {
    "enabled": true,
    "min_full_backups": 3,     // Always keep 3 full backups
    "max_age_days": 90         // Delete backups older than 90 days
  }
}
```

### Scheduling Best Practices

1. **Production Systems**: Use daily or weekly full backups
2. **Development**: Use manual or less frequent scheduling
3. **High-Change Databases**: Consider shorter intervals
4. **Storage Management**: Adjust cleanup policies based on available space

### Two Scheduling Approaches

#### 🧠 Intelligent Scheduler
- **Configurable intervals**: Set `full_backup_interval` per server
- **Smart scheduling**: Only runs when backups are actually needed
- **Automatic cleanup**: Manages retention policies automatically
- **Flexible**: Different schedules for different servers

#### 📅 Traditional Scheduler  
- **Fixed schedule**: Daily at midnight, full backup on 1st of month
- **Simple**: One schedule for all servers
- **Predictable**: Always runs at the same time
- **Legacy**: Compatible with older configurations

**Recommendation**: Use the intelligent scheduler for new setups, especially if you need different backup frequencies for different servers.

## 🔄 Restore & Recovery

The restore script provides intelligent backup restoration with automatic detection of full and incremental backups, ensuring no data loss through proper chronological ordering.

### Quick Restore Examples

```bash
# Restore latest backup
./restore.sh production_server app_database

# Restore to specific date
./restore.sh -d 2025-08-15 production_server app_database

# Restore to different target server
./restore.sh -t 192.168.1.200 -u restore_user -p password production_server app_database

# Dry run to preview restore plan
./restore.sh --dry-run production_server app_database

# Force restore without prompts
./restore.sh --force production_server app_database
```

### Restore Process

The restore script automatically:

1. **Analyzes Available Backups** - Scans backup directory for full and incremental backups
2. **Identifies Baseline** - Finds the appropriate full backup for the target date
3. **Chronological Ordering** - Sorts incremental backups in proper sequence
4. **Validates Chain** - Ensures backup chain integrity before starting
5. **Sequential Restoration** - Applies full backup first, then incrementals in order
6. **Integrity Checks** - Validates each step to prevent data corruption

### Restore Options

| Option | Description |
|--------|-------------|
| `-d, --date DATE` | Restore to specific date (YYYY-MM-DD) |
| `-t, --target HOST` | Target database host (default: from config) |
| `-u, --username USER` | Target database username |
| `-p, --password PASS` | Target database password |
| `-P, --port PORT` | Target database port (default: 3306) |
| `--ssl-mode MODE` | SSL mode: auto, disable, require, verify_ca, verify_identity |
| `--dry-run` | Preview restore plan without executing |
| `--force` | Skip confirmation prompts |
| `-h, --help` | Show detailed help |

### Backup Detection Logic

The restore script intelligently detects and processes backups:

- **Full Backups**: `full_backup_<database>_<timestamp>.sql.gz`
- **Incremental Backups**: `incremental_backup_<database>_<timestamp>.sql.gz`
- **Automatic Ordering**: Sorts by timestamp to ensure proper sequence
- **Chain Resolution**: Links incremental backups to their base full backup
- **Date Filtering**: Includes only backups before/on the target date

### Safety Features

- **Dry Run Mode** - Preview restore operations without executing
- **Database Overwrite Protection** - Warns before overwriting existing databases
- **Connection Validation** - Tests database connectivity before starting
- **Step-by-Step Validation** - Checks each restore operation for success
- **Force Mode** - Bypass prompts for automated operations

### Point-in-Time Recovery Examples

```bash
# Restore to specific date (includes all applicable backups)
./restore.sh -d 2025-08-15 production_server app_database

# Restore to yesterday
./restore.sh -d $(date -v-1d +%Y-%m-%d) production_server app_database

# Preview restore plan for last week
./restore.sh --dry-run -d $(date -v-7d +%Y-%m-%d) production_server app_database
```

### Cross-Server Restore

```bash
# Restore to different server
./restore.sh -t 192.168.1.200 -u restore_user -p password production_server app_database

# Restore with different SSL settings
./restore.sh --ssl-mode require -t secure.db.server production_server app_database

# Restore to local development environment
./restore.sh -t localhost -u dev_user -p dev_password production_server app_database
```

### Manual Restore Process (Alternative)

If you need to restore manually without the script:

```bash
# 1. Find the appropriate full backup
ls -la backups/server1/database1/full_backup_*.sql.gz

# 2. Restore full backup
gunzip < backups/server1/database1/full_backup_database1_20250101_000000.sql.gz | \
  mysql -h server -u user -p --ssl-mode=disable database1

# 3. Apply incremental backups in chronological order
gunzip < backups/server1/database1/incremental_backup_database1_20250102_000000.sql.gz | \
  mysql -h server -u user -p --ssl-mode=disable database1
gunzip < backups/server1/database1/incremental_backup_database1_20250103_000000.sql.gz | \
  mysql -h server -u user -p --ssl-mode=disable database1
```

⚠️ **Important**: When restoring manually, ensure:
- Incremental backups are applied in exact chronological order
- The correct SSL mode is used for your server configuration
- Database permissions allow the restore user to drop/create tables

## ⚙️ Advanced Configuration

### Multiple Server Types
```json
{
  "direct_server": {
    "force_ssh": false,
    "database": {
      "host": "192.168.1.100",
      "username": "backup_user",
      "password": "password"
    },
    "backup_config": {
      "mode": "all"
    }
  },
  "ssh_server": {
    "host": "remote.server.com",
    "username": "backup_user", 
    "auth_type": "key",
    "private_key": "./keys/remote_key",
    "force_ssh": true,
    "database": {
      "host": "localhost",
      "username": "db_user",
      "password": "db_password"
    },
    "backup_config": {
      "mode": "specific",
      "databases": ["production", "analytics"]
    }
  }
}
```

### Custom Backup Paths
```json
{
  "server1": {
    "backup_path": "/custom/backup/location",
    "database": { ... },
    "backup_config": { ... }
  }
}
```

### System Database Inclusion
```json
{
  "backup_config": {
    "mode": "all",
    "include_system_databases": true
  }
}
```

## 🤝 Support

### Getting Help
1. Check logs: `tail -f logs/backup_$(date +%Y%m%d).log`
2. Validate config: `./validate_config.sh test`
3. Test connections: `./backup.sh test`
4. Review this documentation

### Configuration Assistance
```bash
# Generate sample configuration
./validate_config.sh sample

# Discover available databases
./discover_databases.sh discover server_name

# Generate config snippets
./discover_databases.sh generate server_name specific "db1,db2"
```

---

**🎯 This backup system provides enterprise-level database backup capabilities while maintaining simplicity and reliability for automated operations.**
