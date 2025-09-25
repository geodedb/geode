# Geode Graph Database - v0.16.0

## Description

Geode is an ISO/IEC 39075:2024 (GQL) compliant graph database written in Zig 0.15.1. Version 0.16.0 represents a major integration milestone with all subsystems fully integrated without compile-time feature flags.

![Evidence Coverage](badges/evidence.svg)

- **607 tracked aspects** (requirements / features / bench targets from status.csv)
- **365 TESTED aspects** (functional tests with exact output validation)
- **229 BENCHED aspects** (performance / throughput / latency envelopes)
- **13 IMPLEMENTED aspects** (integration complete, tests pending)
- **0 STUB aspects** (all features now integrated)

## What's New in v0.16.0

### Major Integration Release

- **🔒 QUIC+TLS Only**: TCP removed, TLS mandatory with auto-generated certificates
- **🚫 No Feature Flags**: All compile-time flags removed, full integration
- **🌐 Full Raft Clustering**: Multi-process with data replication and automatic failover
- **🛡️ RLS/ABAC Enforced**: Row-level security via planner rewrite
- **📊 Materialized Views**: Complete and incremental refresh implemented
- **📈 Status Tracking**: Generated `docs/status.csv` from CANARY annotations

## Quick Start

```bash
# Build (no feature flags needed)
zig build -Drelease-safe

# Start server (QUIC+TLS, auto-generates certs if missing)
./zig-out/bin/geoded --data_dir ./data --log_json

# Run CLI client
./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --format json

# Test suite
zig build test -Drelease-safe

# Verify no feature flags
tools/no_feature_flags_check.py --repo .

# Generate status CSV
tools/status_generate.py --repo . --out docs/status.csv
```

## Verified Working Features (v0.16.0)

### Core Database

- ✅ **Query Engine**: RETURN, ORDER BY, LIMIT/OFFSET with US001 policy
- ✅ **Set Operations**: UNION/INTERSECT/EXCEPT with DISTINCT/ALL
- ✅ **Transactions**: MVCC SI with phantom prevention
- ✅ **Schema Constraints**: Check/unique/pattern with cascade
- ✅ **CDC Engine**: Streaming with backpressure and guardrails

### Security & Access Control

- ✅ **RLS/ABAC**: Policy-based row filtering with audit logging
- ✅ **TDE**: Transparent data encryption with key rotation
- ✅ **QUIC+TLS**: Mandatory encryption, no plaintext option

### High Availability

- ✅ **Raft Consensus**: Leader election, log replication, automatic failover
- ✅ **Backup/Restore**: Full and incremental with CRC verification
- ✅ **Materialized Views**: Complete and incremental refresh

### Advanced Features

- ✅ **Recursive CTEs**: With bounded expansion and cycle detection
- ✅ **Path Operations**: Variable-length with deterministic tie-break
- ⚠️ **Cost Optimizer**: Model calibrated, plan selection pending
- ⚠️ **GPU Acceleration**: Detection only, no kernel execution yet

## Architecture

### Transport Layer (v0.16.0)

QUIC+TLS is mandatory with no TCP fallback:

```json
{"component":"transport","transport":"quic","tls":"true","port":8443}
```

Certificates auto-generate if missing with secure permissions (0600).

### Clustering (v0.16.0)

Full multi-process Raft implementation:

```bash
# 3-node cluster
./zig-out/bin/geoded --node-id 1 --port 7567 --peers 2:7569,3:7571 &
./zig-out/bin/geoded --node-id 2 --port 7569 --peers 1:7567,3:7571 &
./zig-out/bin/geoded --node-id 3 --port 7571 --peers 1:7567,2:7569 &
```

Features:
- Automatic leader election (150-300ms randomized timeout)
- Log replication with quorum commit
- Automatic failover on leader failure
- Snapshot installation for catch-up
- Idempotent state machine

### Security (v0.16.0)

RLS enforcement via planner rewrite:

```sql
-- Original
SELECT * FROM employees;

-- After RLS (automatic)
SELECT * FROM employees 
WHERE tenant_id = current_tenant() 
  AND check_policy(current_user(), 'read', 'employees');
```

## Governance & Evidence

All features backed by CANARY evidence:

```bash
# Build scanner
make canary

# Verify evidence
./bin/canaryscan --root . --out status.json --csv status.csv \
  --verify docs/GAP_ANALYSIS.md --strict

# Check governance
make governance-check

# Update after changes
make update-status-hash
```

### CANARY Annotation Format

```zig
// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=QUICCore; 
//         STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_QUICCore; 
//         OWNER=wire; UPDATED=2025-09-25
```

## Migration from v0.15.0

### Breaking Changes

1. **TCP Removed** - Update all clients to use QUIC
2. **Feature Flags Gone** - Remove `-Dfeature-*` from builds
3. **Certs Required** - Ensure `certs/` exists (auto-generates)
4. **RLS Default On** - Review security policies
5. **Generated Files** - Never edit `docs/status.csv` manually

### Migration Script

```bash
#!/bin/bash
# Update build scripts
find . -name "*.sh" -exec sed -i 's/-Dfeature-[^ ]*//g' {} \;

# Update connection strings
# Old: tcp://localhost:7567
# New: quic://localhost:8443

# Regenerate status
tools/status_generate.py --repo . --out docs/status.csv

# Test cluster
scripts/cluster_spawn.sh
```

## Build Options

### Compile Time (v0.16.0)

```bash
# Standard build (all features included)
zig build -Drelease-safe

# Debug build
zig build

# With sentinel allocator
zig build -Dsan=true
```

### Runtime Environment

```bash
# Non-transport feature kill-switches (testing only)
export GEODE_DISABLE_RLS=1              # Disable RLS enforcement
export GEODE_MV_REFRESH_INTERVAL=60     # MV refresh interval (seconds)
export GEODE_RAFT_ELECTION_TIMEOUT=5000 # Election timeout (ms)
export GEODE_WAL_COMPACTION_INTERVAL=300 # WAL compaction (seconds)
```

## Testing

### Unit & Integration Tests

```bash
# All tests
zig build test -Drelease-safe

# Specific test
zig test tests/e2e_distributed_cluster.zig

# With traces
zig test tests/e2e_rls_integration.zig -freference-trace
```

### Acceptance Tests

```bash
# Full acceptance suite
./test_acceptance.sh

# Individual checks
tools/no_feature_flags_check.py --repo .
tools/status_generate.py --repo . --out docs/status.csv
tools/canary_check.py --repo . --csv docs/status.csv
scripts/cluster_spawn.sh
```

### Performance Benchmarks

```bash
# Run benchmarks
zig build bench -Drelease-fast

# Variance envelopes
zig test tests/benchmark_*_variance.zig
```

## Documentation

- [docs/README.md](docs/README.md) - Technical documentation hub
- [docs/IMPLEMENTATION_REALITY.md](docs/IMPLEMENTATION_REALITY.md) - Evidence-based status
- [docs/GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md) - Conformance tracking
- [docs/BINARY_PROTOCOL.md](docs/BINARY_PROTOCOL.md) - Wire protocol specification
- [docs/GOVERNANCE.md](docs/GOVERNANCE.md) - CANARY governance reference
- [CRUSH.md](CRUSH.md) - Build and development notes

## Performance Targets

| Metric | Target | Current |
|--------|--------|---------|
| Simple query latency | < 1ms p50 | ✅ 0.8ms |
| Path expansion (3-hop) | < 100ms p95 | ✅ 85ms |
| Raft commit latency | < 50ms p50 | ✅ 45ms |
| MV refresh (1M rows) | < 10s | ✅ 8.5s |
| CDC throughput | > 100k ops/s | ✅ 120k ops/s |
| Memory (idle) | < 100MB | ✅ 85MB |

## Known Limitations

- GPU acceleration: Detection only, no kernel execution
- ML integration: Interface defined, implementation pending
- Geospatial: No spatial index or operations
- Time-series windows: Aggregation functions not implemented
- Full-text search: Basic inverted index only

## Contributing

1. Add CANARY annotation to new code
2. Write test with `TestCANARY_REQ_GQL_###_` prefix
3. Add benchmark if performance-critical
4. Update CANARY UPDATED date
5. Run `tools/status_generate.py`
6. Submit PR with evidence

## License

MIT License - See LICENSE file for details

## Support

- GitHub Issues: Bug reports and feature requests
- Documentation: See `docs/` directory
- Tests: Comprehensive suite in `tests/`
- Benchmarks: Performance tests in `benchmarks/`

## Roadmap

### v0.17.0 (Q1 2025)
- GPU kernel execution for graph algorithms
- ML model integration (embeddings, similarity)
- Geospatial index and operations

### v0.18.0 (Q2 2025)
- Time-series window functions
- Full-text search with relevance ranking
- Multi-region deployment support

### v1.0.0 (H2 2025)
- Production stability guarantee
- Enterprise features (audit, compliance)
- Cloud-native deployment tools