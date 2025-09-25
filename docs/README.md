# Geode Documentation - v0.17.0

## Start Here

### What's New in v0.17.0

**Feature Completeness Release** - Critical gaps closed with production-ready implementations:

- **Complete MATCH Engine**: Complex patterns, nested OPTIONAL, filtered variable-length paths
- **DML Operations**: INSERT/UPDATE/DELETE for nodes/edges with RLS enforcement
- **Cost-Based Optimizer v1**: Statistics, cardinality estimation, join reordering (GEODE_ENABLE_CBO=1)
- **CDC External Sinks**: Kafka and Webhook with at-least-once delivery, retry, DLQ
- **Raft Persistence**: Durable log, snapshots, compaction, dynamic membership
- **Graph Algorithms**: shortestPath() and pageRank() as GQL functions
- **WHERE Advanced**: Subqueries, IN/EXISTS/ANY/ALL predicates
- **QUIC-only**: TCP completely removed, port 8443 mandatory

### Reality Check (Required)

- [IMPLEMENTATION_REALITY.md](IMPLEMENTATION_REALITY.md) — Evidence-driven snapshot of what's actually implemented (v0.17.0 update)
- [GAP_ANALYSIS.md](GAP_ANALYSIS.md) — Machine-verified evidence ledger with 827 CANARY aspects
- [REQUIREMENTS.md](REQUIREMENTS.md) — v0.17.0 feature completeness scope (ISO/IEC 39075 GQL–first)

### Technical Documentation

- [BINARY_PROTOCOL.md](BINARY_PROTOCOL.md) — Wire frames, diagnostics, pagination semantics
- [USAGE.md](USAGE.md) — Build/run usage, client flags, demos, telemetry
- [TELEMETRY.md](TELEMETRY.md) — Optional paging telemetry (stderr JSON) and how to enable
- [GOVERNANCE.md](GOVERNANCE.md) — CANARY governance and CI reference
- [NEXT.md](NEXT.md) — Forward backlog (date‑guarded)
- [PROMPT.md](PROMPT.md) — CANARY-enabled unified prompt for development

## Quick Start

```bash
# Build
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

# Multi-process cluster test
scripts/cluster_spawn.sh
```

## Current Evidence Snapshot (2025-09-25)

- 607 tracked aspects (TOTAL)
- 365 TESTED (functional)
- 229 BENCHED (variance‑guarded performance)
- 13 IMPLEMENTED (integration complete, tests pending)
- 0 STUB (all features integrated)

Counts originate from the CANARY scanner (`status.csv` authoritative) and are cross-checked in governance.

## Implementation Status

### ✅ Fully Integrated (v0.16.0)

- **Wire protocol**: HELLO/RUN_GQL/PULL; SCHEMA/BINDINGS/EXPLAIN/PROFILE
- **QUIC+TLS transport**: Mandatory, with certificate auto-generation
- **Query engine**: RETURN, ORDER BY, LIMIT/OFFSET, set operations
- **Schema constraints**: Check/unique/pattern with cascade
- **CDC engine**: Streaming with guardrails and backpressure
- **Transactions**: MVCC SI with phantom‑prevention
- **Path operations**: Bounded expansion with cycle detection
- **Storage & WAL**: ARIES recovery, compaction, physiological redo
- **RLS/ABAC**: Policy-based row filtering and access control
- **Materialized views**: Complete and incremental refresh
- **Backup/Restore**: Full and incremental with CRC verification
- **Distributed**: Full Raft consensus with leader election and replication

### ⚠️ Partial Implementation

- **Recursive CTEs**: Core engine integrated, bounded expansions enabled
- **Cost-based optimizer**: Cost model with calibration, plan selection pending
- **GPU acceleration**: Capability detection only, no kernel execution yet
- **ML integration**: Interface defined, implementation pending

### ❌ Not Implemented

- **Advanced graph analytics**: PageRank, centralities, communities
- **Full-text search**: Index and query pipelines not implemented
- **Geospatial**: No spatial index or operations
- **Time-series windows**: Aggregation functions not implemented

## Transport Layer (v0.16.0)

**QUIC+TLS is mandatory** - no TCP fallback:

```json
{"component":"transport","transport":"quic","tls":"true","port":8443}
```

If certificates don't exist in `certs/`, they are auto-generated with secure permissions (0600).

## Clustering (v0.16.0)

Full multi-process Raft implementation:

```bash
# Start 3-node cluster
./zig-out/bin/geoded --node-id 1 --port 7567 --peers 2:7569,3:7571 &
./zig-out/bin/geoded --node-id 2 --port 7569 --peers 1:7567,3:7571 &
./zig-out/bin/geoded --node-id 3 --port 7571 --peers 1:7567,2:7569 &
```

Features:
- Automatic leader election (randomized 150-300ms timeout)
- Log replication with quorum commit
- Automatic failover on leader failure
- Snapshot installation for follower catch-up
- Idempotent state machine application

## Security (v0.16.0)

### RLS/ABAC Enforcement

Row-level security is enforced via planner rewrite:

```sql
-- Original query
SELECT * FROM employees;

-- After RLS rewrite (automatic)
SELECT * FROM employees WHERE tenant_id = current_tenant() 
  AND department IN (SELECT dept FROM user_permissions WHERE user_id = current_user());
```

Audit logging in JSON Lines format with PII redaction.

### TDE (Transparent Data Encryption)

- Multi-level key hierarchy
- Automatic key rotation
- Hardware security module (HSM) support
- Per-table encryption policies

## Materialized Views (v0.16.0)

```sql
-- Create materialized view
CREATE MATERIALIZED VIEW sales_summary AS
  SELECT region, SUM(amount) as total
  FROM sales
  GROUP BY region
  WITH (refresh_method = 'incremental', refresh_interval = '1 hour');

-- Manual refresh
REFRESH MATERIALIZED VIEW sales_summary;
```

Features:
- Complete refresh (full recomputation)
- Incremental refresh (CDC-based delta application)
- Single-flight locking (prevents concurrent refreshes)
- Transactional consistency
- Automatic retry with exponential backoff

## Build System (v0.16.0)

**No compile-time feature flags** - all subsystems are integrated:

```bash
# Old (v0.15.0) - DO NOT USE
zig build -Dfeature-cluster=true -Dfeature-rls=true  # INVALID

# New (v0.16.0) - CORRECT
zig build -Drelease-safe  # Everything included
```

Runtime kill-switches (non-transport features only):
```bash
export GEODE_DISABLE_RLS=1          # Testing only
export GEODE_MV_REFRESH_INTERVAL=60 # Seconds
export GEODE_RAFT_ELECTION_TIMEOUT=5000  # Milliseconds
```

## Verification

All claims are backed by CANARY evidence:

```bash
# Build the scanner
make canary

# Strict verification of GAP_ANALYSIS vs evidence
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict

# Check for feature flags (must pass)
tools/no_feature_flags_check.py --repo .

# Validate CANARY annotations
tools/canary_check.py --repo . --csv docs/status.csv

# Inspect CANARY lines
grep -r "CANARY: REQ=REQ-GQL-" src/ tests/ | head
```

## Documentation Standards

1. **No undocumented claims** — every feature claim must have a CANARY token
2. **Evidence-based** — STATUS is TESTED or BENCHED (no STUB in v0.16.0)
3. **Freshness** — UPDATED dates within 60 days for active features
4. **Automated checks** — CI enforces via scanner + governance
5. **Generated artifacts** — `status.csv` is generated, never hand-edited

## For Contributors

Before claiming a feature is implemented:

1. Add CANARY annotation to implementation
2. Write test with `TestCANARY_REQ_GQL_###_` prefix
3. Write benchmark with `BenchmarkCANARY_REQ_GQL_###_` prefix (if performance-critical)
4. Update CANARY UPDATED date
5. Run `tools/status_generate.py` to regenerate CSV
6. Submit PR with evidence

## Migration from v0.15.0

### Breaking Changes

1. **TCP removed** - All clients must use QUIC
2. **Feature flags removed** - Remove all `-Dfeature-*` from build scripts
3. **Certificates required** - Ensure `certs/` directory exists (auto-generates if missing)
4. **RLS enforced by default** - Review and update security policies
5. **Generated files** - Never hand-edit `docs/status.csv`

### Migration Steps

```bash
# 1. Update build scripts
sed -i 's/-Dfeature-[^ ]*//g' build.sh

# 2. Update client connections
# Old: tcp://localhost:7567
# New: quic://localhost:8443

# 3. Review RLS policies
./zig-out/bin/geodec "SHOW POLICIES"

# 4. Regenerate status tracking
tools/status_generate.py --repo . --out docs/status.csv

# 5. Test cluster formation
scripts/cluster_spawn.sh
```

## Support

- GitHub Issues: Report bugs and feature requests
- Documentation: This directory contains all technical docs
- Tests: Comprehensive test suite in `tests/`
- Benchmarks: Performance tests in `benchmarks/`