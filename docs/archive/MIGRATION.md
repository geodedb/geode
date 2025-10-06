# CLI Migration Guide

Geode v0.17.0 introduces a unified CLI interface. The legacy binaries are still available but deprecated.

## Command Mapping

### Server
```bash
# Old
geoded --data_dir ./data --listen 0.0.0.0:3141

# New  
geode serve --data-dir ./data --listen 0.0.0.0:3141
```

### Query Client
```bash
# Old
geodec "MATCH (n) RETURN n LIMIT 10" --server localhost:3141

# New
geode query "MATCH (n) RETURN n LIMIT 10" --server localhost:3141
```

### User Management
```bash
# Old
geode-auth user create alice alice@example.com password123
geode-auth role create editor "Can edit content"
geode-auth grant role editor to alice

# New
geode user create alice alice@example.com password123
geode role create editor "Can edit content"  
geode grant role editor to alice
```

## New Commands

### Interactive Shell
```bash
geode shell --server localhost:3141
```

### Authentication
```bash
geode auth login -U alice
geode auth logout
```

### Database Operations
```bash
geode backup --dest s3://bucket/backup.gql
geode restore --source ./backup.gql
geode migrate ./migrations/
```

## Global Options

All subcommands support these global options:
- `-h, --help` - Show help
- `-v, --verbose` - Verbose output  
- `--config <path>` - Configuration file path
- `--json` - Force JSON output

## Output Changes

- **Data outputs** (query results, lists) → stdout
- **Usage/help/errors** → stderr
- **Consistent exit codes**: 0=success, 1=error, 2=usage, 3=auth

## Development Status

This is a development system. Legacy binaries (`geoded`, `geodec`, `geode-auth`) remain available as separate tools, but the new unified `geode` CLI is the recommended interface going forward.

## Security Improvements

- Passwords use echo-off prompts when TTY detected
- Credentials stored securely at `~/.config/geode/credentials.json` (mode 0600)
- Shell history at `~/.local/share/geode/history` (mode 0600)
- Support for `--password-file` and stdin password input

## Flag Normalization

Standardized flag names across all commands:
- `--server` (server address)
- `-U, --user` (username)
- `--format json|table|csv` (output format)
- `--yes` (skip confirmations)
- `--no-prompt` (don't prompt for missing values)