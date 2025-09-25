# Geode v0.16.0 - Full Integration Release

## Overview
Geode v0.16.0 is a major integration release that removes all compile-time feature flags and fully integrates all previously experimental features into a unified build.

## Breaking Changes from v0.15.0

### 1. Transport Layer
- **TCP removed entirely** - QUIC+TLS is now mandatory
- Default port changed from 7567 to **8443**
- Self-signed certificates auto-generated if missing
- No `--no-quic` or `--allow-insecure` options

### 2. Feature Defaults
- **Recursion**: Enabled by default (WITH RECURSIVE)
- **Bounded expansions**: Enabled by default with max depth 10
- **Phantom prevention**: Enabled by default via RangeTracker
- **ORDER BY enforcement**: Required when using LIMIT/OFFSET

### 3. Build System
- All `-Dfeature-*` flags removed
- Single unified build: `zig build -Drelease-safe`
- No conditional compilation based on features

## New Features

### Security & Compliance
- **RLS/ABAC enforcement** via planner rewrite
- **Audit logging** with PII redaction
- **Tenant isolation** and hierarchy support
- **Clearance-based access control**

### Storage & Views
- **Materialized view refresh** (complete and incremental)
- **CDC-based incremental updates**
- **Backup/restore with CRC-32 verification**
- **WAL compaction after successful backup**

### Clustering
- **Full Raft consensus** with leader election
- **QUIC-based replication** between nodes
- **Automatic failover** and follower catch-up
- **InstallSnapshot RPC** for lagging nodes

### Monitoring & Observability
- **Metrics always enabled** (no compile flag)
- RLS denial metrics
- MV refresh metrics
- Raft leadership/lag metrics
- QUIC handshake metrics

## Migration Guide

### From v0.15.0

1. **Update client connections**:
   ```bash
   # Old (TCP)
   geodec --host localhost --port 7567
   
   # New (QUIC+TLS)
   geodec --host localhost --port 8443
   ```

2. **Remove feature flags from build**:
   ```bash
   # Old
   zig build -Drelease-safe -Dfeature-rls=true -Dfeature-mv=true
   
   # New
   zig build -Drelease-safe
   ```

3. **Update queries for ORDER BY enforcement**:
   ```sql
   -- Old (allowed but non-deterministic)
   RETURN x LIMIT 10
   
   -- New (ORDER BY required)
   RETURN x ORDER BY x LIMIT 10
   ```

4. **Certificate handling**:
   - Place certificates in `certs/server.crt` and `certs/server.key`
   - Or let the system auto-generate self-signed certificates

## Building & Running

### Prerequisites
- Zig 0.15.1
- Python 3.11+ (for tooling)
- OpenSSL (for certificate generation)

### Build
```bash
zig build -Drelease-safe
```

### Run Server
```bash
# Single node
./zig-out/bin/geoded --data-dir ./data

# Cluster mode (3 nodes)
./scripts/cluster_spawn.sh
```

### Run Client
```bash
./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x"
```

## Testing

### Run All Tests
```bash
zig build test -Drelease-safe
```

### Verify No Feature Flags
```bash
python3 tools/no_feature_flags_check.py --repo .
```

### Generate Status Report
```bash
python3 tools/status_generate.py --repo . --out docs/status.csv
```

### Acceptance Tests
```bash
# Test 1: ORDER BY enforcement
zig test tests/e2e_planner_order_enforcement.zig

# Test 2: Recursion defaults
zig test tests/e2e_recursive_bounded_default.zig

# Test 3: RLS integration
zig test tests/e2e_rls_integration.zig

# Test 4: MV refresh
zig test tests/e2e_materialized_views_refresh.zig

# Test 5: Backup/restore
zig test tests/e2e_backup_restore_roundtrip.zig

# Test 6: Phantom prevention
zig test tests/e2e_txn_phantom_prevention.zig

# Test 7: QUIC startup
./zig-out/bin/geoded --once

# Test 8: Cluster replication
./scripts/cluster_spawn.sh
```

## Expected Test Outputs

### Test 1: ORDER BY Required
```
PLANNER_ERROR ORDER_BY_REQUIRED
ORDER_BY_ENFORCED_OK
```

### Test 2: Defaults ON
```
RECURSIVE_DEFAULT_ON frontier_iter_ok
BOUNDED_EXPANSION_DEFAULT_ON maxlen=3 deterministic=true
```

### Test 3: RLS Enforcement
```
RLS_ALLOW tenant=5 table=employees
RLS_DENY tenant=5 table=employees reason=USING
RLS_HIERARCHY_ALLOW parent=1 child=3
ABAC_DENY rule=clearance_below resource=CONFIDENTIAL
AUDIT_LOGGED type=deny policy_id=*
```

### Test 4: MV Refresh
```
MV_REFRESH_OK view_id=1 rows=42 method=complete
MV_REFRESH_OK view_id=1 rows=7 method=incremental
```

### Test 5: Backup/Restore
```
BACKUP_OK type=full crc=true
BACKUP_OK type=incremental crc=true
RESTORE_OK lsn=*
```

### Test 6: Phantom Prevention
```
PHANTOM_BLOCKED isolation=SERIALIZABLE range=[A,Z]
```

### Test 7: QUIC Startup
```json
{"component":"transport","transport":"quic","tls":"true","port":8443}
```

### Test 8: Cluster Replication
```
CLUSTER_LEADER_ELECTED node=1 term=1
RAFT_REPLICATION_OK leader=1 follower=2 index=1
CLUSTER_FAILOVER_PRIMARY old=1 new=2 term=2
RAFT_REPLICATION_OK_AFTER_FAILOVER leader=2 follower=3 index=2
```

### Test 9: Status CSV Generation
```
STATUS_CSV_WRITTEN path=docs/status.csv items=451
```

### Test 10: No Feature Flags
```
NO_FEATURE_FLAGS_OK
```

## Performance Targets

- **Raft commit latency**: p50 ≤ 50ms, p95 ≤ 150ms
- **MV refresh**: Single-flight with retry backoff
- **Memory usage**: ≤ 512 MiB RSS for tests
- **QUIC handshake**: Sub-second with TLS 1.3

## Security Notes

- TLS certificates are mandatory (no plaintext)
- Private keys have 0600 permissions
- Audit logs redact PII by default
- RLS policies enforced at planner level

## Known Issues

- Go client import path needs updating for v0.16.0
- Some test files reference old TCP port 7567

## Support

For issues or questions about v0.16.0, please file an issue on GitHub with the `v0.16.0` tag.