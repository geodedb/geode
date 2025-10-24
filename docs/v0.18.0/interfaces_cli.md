# Interfaces — CLI

Unified CLI `geode` (v0.17+), legacy `geoded`/`geodec` kept for compatibility.

- Start server:
  - Legacy: `geoded --data_dir ./data --listen 0.0.0.0:3141`
  - Unified: `geode serve --data-dir ./data --listen 0.0.0.0:3141`
- Run query:
  - Legacy: `geodec "MATCH (n) RETURN n LIMIT 10"`
  - Unified: `geode query "MATCH (n) RETURN n LIMIT 10" --server localhost:3141`
- Interactive shell: `geode shell --server localhost:3141`
- Backups: `geode backup --dest s3://bucket/path --mode full|incremental`
- Restore: `geode restore --source s3://bucket/path --target ./data`
- Migrations: `geode migrate ./migrations/`
- Auth: `geode auth login -U alice`, `geode auth logout`
- Users/Roles: `geode user create ...`, `geode role create ...`, `geode grant role ...`
- Diagnostics: `geode status`, `geode diag metrics`

Conventions:
- STDOUT for data, STDERR for usage/errors. Exit codes: 0=ok, 1=runtime, 2=usage, 3=auth.