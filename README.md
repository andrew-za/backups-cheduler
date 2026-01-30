# Database Backup System

A comprehensive, production-ready database backup solution with integrity verification, incremental backups, and automated FTP upload.

## Features

- ✅ **Automatic Database Discovery** - Automatically finds and backs up all user databases
- ✅ **Full Backups** - Complete database dumps with integrity verification
- ✅ **Incremental Backups** - Two methods for efficient frequent backups
- ✅ **Integrity Verification** - SHA256 checksums and SQL validation
- ✅ **FTP Upload** - Reliable upload with retry logic and verification
- ✅ **Scheduled Backups** - Easy cron job setup
- ✅ **Comprehensive Logging** - Detailed logs for monitoring and troubleshooting
- ✅ **Automatic Cleanup** - Removes old backups based on retention policies
- ✅ **Error Handling** - Graceful error handling with detailed error logs

## Directory Structure

```
database_backups/
├── scripts/
│   ├── database_backup.sh          # Main full backup script
│   ├── incremental_backup.sh        # Table-level incremental backups
│   ├── backup_binary_logs.sh        # Binary log incremental backups
│   ├── verify_backup.sh             # Backup verification tool
│   ├── setup_backup_cron.sh        # Full backup cron setup
│   ├── setup_incremental_backups.sh # Incremental backup cron setup
│   └── enable_binary_logging.sh     # Enable MySQL binary logging
├── config/
│   ├── backup_config.example       # Configuration template
│   ├── .backup_config              # Your configuration (create this)
│   ├── .backup_state               # Incremental backup state (auto-generated)
│   └── .binlog_state               # Binary log state (auto-generated)
├── backups/
│   ├── *.sql.gz                    # Full backup files
│   ├── incremental/                 # Incremental backup files
│   └── binlogs/                    # Binary log backup files
├── logs/
│   ├── backup_*.log                # Full backup logs
│   ├── incremental_backup_*.log    # Incremental backup logs
│   ├── binlog_backup_*.log         # Binary log backup logs
│   └── backup_errors.log           # Error log
└── README.md                       # This file
```

## Quick Start

### 1. Configuration

Copy the example config file and fill in your credentials:

```bash
cd /root/database_backups
cp config/backup_config.example config/.backup_config
nano config/.backup_config
```

Required configuration:
- MySQL/MariaDB credentials (`MYSQL_USER`, `MYSQL_PASS`)
- FTP server details (`FTP_HOST`, `FTP_USER`, `FTP_PASS`, `FTP_DIR`)

### 2. Test Full Backup

Run a test backup to verify everything works:

```bash
./scripts/database_backup.sh
```

Check the logs:
```bash
tail -f logs/backup_*.log
```

### 3. Set Up Scheduled Backups

**Full Backups (Daily):**
```bash
./scripts/setup_backup_cron.sh
# Default: Daily at 2 AM
# Custom: ./scripts/setup_backup_cron.sh "0 3 * * *"
```

**Incremental Backups (Hourly):**
```bash
./scripts/setup_incremental_backups.sh
# Follow the interactive prompts to choose your method
```

## Backup Methods

### Full Backups

Complete database dumps with all data, structure, routines, triggers, and events.

**Usage:**
```bash
./scripts/database_backup.sh
```

**Features:**
- Single-transaction for consistency
- Compressed with gzip
- SHA256 checksums
- SQL validation
- FTP upload with retry logic

**Recommended Schedule:** Daily (e.g., 2 AM)

### Incremental Backups

Two methods available for efficient frequent backups:

#### Method 1: Table-Level Incremental

Backs up only tables that have been modified since the last backup.

**Usage:**
```bash
./scripts/incremental_backup.sh
```

**How it works:**
- Checks table modification timestamps
- Only backs up changed tables
- Tracks state in `.backup_state` file
- Minimal resource usage

**Best for:** Immediate use, moderate change volumes

**Recommended Schedule:** Hourly

#### Method 2: Binary Log Backups

Backs up MySQL binary logs containing all database changes.

**Prerequisites:**
```bash
# Enable binary logging first
./scripts/enable_binary_logging.sh
```

**Usage:**
```bash
./scripts/backup_binary_logs.sh
```

**How it works:**
- Copies MySQL binary log files
- Contains all changes since last full backup
- Most efficient method
- Enables point-in-time recovery

**Best for:** High-frequency changes, production environments

**Recommended Schedule:** Every 15 minutes

## Backup Verification

Verify backup integrity:

```bash
./scripts/verify_backup.sh
```

This script:
- Verifies SHA256 checksums
- Tests SQL dump syntax
- Checks file completeness
- Validates backup headers

## Monitoring

### View Recent Backups
```bash
ls -lth backups/ | head -20
ls -lth backups/incremental/ | head -20
ls -lth backups/binlogs/ | head -20
```

### View Logs
```bash
# Latest full backup log
tail -f logs/backup_*.log

# Latest incremental backup log
tail -f logs/incremental_backup_*.log

# Latest binary log backup
tail -f logs/binlog_backup_*.log

# All errors
tail -f logs/backup_errors.log

# Cron logs
tail -f logs/cron_backup.log
tail -f logs/cron_incremental.log
```

### Check Cron Jobs
```bash
crontab -l
```

## Backup Retention

- **Full Backups:** 30 days (configurable via `RETENTION_DAYS`)
- **Incremental Backups:** 7 days (168 hours)
- **Binary Log Backups:** 7 days

Old backups are automatically cleaned up during backup runs.

## Restore Procedures

### Restore Full Backup

```bash
# Decompress and restore
gunzip < backups/dbname_YYYYMMDD_HHMMSS.sql.gz | mysql -u root -p dbname
```

### Restore with Point-in-Time Recovery (Binary Logs)

1. Restore latest full backup
2. Apply binary logs up to desired point:
```bash
mysqlbinlog backups/binlogs/mysql-bin.000001 | mysql -u root -p dbname
mysqlbinlog backups/binlogs/mysql-bin.000002 | mysql -u root -p dbname
# ... continue until desired point
```

### Restore Incremental Backup

Incremental backups contain only changed data. Restore full backup first, then apply incrementals:

```bash
# Restore full backup
gunzip < backups/dbname_YYYYMMDD_HHMMSS.sql.gz | mysql -u root -p dbname

# Apply incremental changes
gunzip < backups/incremental/dbname_tablename_YYYYMMDD_HHMMSS.sql.gz | mysql -u root -p dbname
```

## Troubleshooting

### Backup Fails

1. **Check MySQL credentials:**
   ```bash
   mysql -u $MYSQL_USER -p$MYSQL_PASS -e "SHOW DATABASES;"
   ```

2. **Verify MySQL service:**
   ```bash
   systemctl status mariadb
   ```

3. **Check disk space:**
   ```bash
   df -h
   ```

4. **Review error logs:**
   ```bash
   tail -50 logs/backup_errors.log
   ```

### FTP Upload Fails

1. **Test FTP connection manually:**
   ```bash
   lftp -u USERNAME,PASSWORD ftp.example.com
   ```

2. **Verify FTP credentials** in `config/.backup_config`

3. **Check network connectivity:**
   ```bash
   ping ftp.example.com
   ```

4. **Verify FTP directory exists and is writable**

### Binary Logging Not Working

1. **Check if binary logging is enabled:**
   ```bash
   mysql -e "SHOW VARIABLES LIKE 'log_bin';"
   ```

2. **Enable binary logging:**
   ```bash
   ./scripts/enable_binary_logging.sh
   ```

3. **Check MySQL error log:**
   ```bash
   journalctl -u mariadb -n 50
   ```

### Corrupted Backups

- Backups are automatically validated before upload
- If corruption is detected, backup is deleted and logged
- Run verification script to check existing backups:
  ```bash
  ./scripts/verify_backup.sh
  ```

## Security

### Protect Configuration Files

```bash
chmod 600 config/.backup_config
chmod 600 config/.backup_state
chmod 600 config/.binlog_state
```

### Backup File Permissions

Backup files contain sensitive database data. Ensure proper permissions:
```bash
chmod 600 backups/*.sql.gz
```

### FTP Security

- Use SFTP/FTPS if available (modify lftp commands)
- Consider encrypting backups before upload
- Store FTP credentials securely

## Advanced Configuration

### Custom Retention Periods

Edit the scripts to change retention:
- Full backups: `RETENTION_DAYS` variable
- Incremental: `RETENTION_HOURS` variable
- Binary logs: `RETENTION_DAYS` variable

### Custom Backup Schedules

Edit cron jobs:
```bash
crontab -e
```

Common schedules:
- `0 2 * * *` - Daily at 2 AM
- `0 */6 * * *` - Every 6 hours
- `*/15 * * * *` - Every 15 minutes
- `0 2 * * 0` - Weekly on Sunday at 2 AM

### Multiple Backup Destinations

Modify scripts to upload to multiple FTP servers or add S3/cloud storage support.

## Scripts Reference

| Script | Purpose | Usage |
|--------|---------|-------|
| `database_backup.sh` | Full database backups | Run manually or via cron |
| `incremental_backup.sh` | Table-level incremental backups | Run hourly via cron |
| `backup_binary_logs.sh` | Binary log backups | Run every 15 min via cron |
| `verify_backup.sh` | Verify backup integrity | Run manually for verification |
| `setup_backup_cron.sh` | Setup full backup cron job | Run once to configure |
| `setup_incremental_backups.sh` | Setup incremental backup cron | Run once to configure |
| `enable_binary_logging.sh` | Enable MySQL binary logging | Run once before binary log backups |

## Best Practices

1. **Test Backups Regularly** - Verify backups can be restored
2. **Monitor Logs** - Set up log monitoring/alerts
3. **Keep Multiple Copies** - Use FTP + local storage
4. **Document Restore Procedures** - Keep restore steps documented
5. **Test Disaster Recovery** - Periodically test full restore process
6. **Monitor Disk Space** - Ensure sufficient space for backups
7. **Review Retention Policies** - Adjust based on business needs
8. **Secure Credentials** - Protect configuration files

## Support

For issues or questions:
1. Check logs in `logs/` directory
2. Review error messages in `logs/backup_errors.log`
3. Verify configuration in `config/.backup_config`
4. Test individual components manually

## License

This backup system is provided as-is for production use.
