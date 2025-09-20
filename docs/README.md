# Geode Documentation

## Start Here

### Reality Check (REQUIRED READING)
- **[IMPLEMENTATION_REALITY.md](IMPLEMENTATION_REALITY.md)** - CANARY-derived truth about what's actually implemented (30-35% complete)
- **[ACTUAL_STATUS.md](ACTUAL_STATUS.md)** - Detailed breakdown of working vs non-existent features
- **[GAP_ANALYSIS.md](GAP_ANALYSIS.md)** - Machine-verified evidence table from CANARY tokens

### Technical Documentation
- **[BINARY_PROTOCOL.md](BINARY_PROTOCOL.md)** - Wire protocol frames, diagnostics (WORKING)
- **[GQL_CONFORMANCE_PROFILE.md](GQL_CONFORMANCE_PROFILE.md)** - ISO GQL conformance status
- **[CDC_DIAGNOSTICS.md](CDC_DIAGNOSTICS.md)** - CDC control protocol (WORKING)
- **[CONFORMANCE_MATRIX.md](CONFORMANCE_MATRIX.md)** - Parser/AST implementation status

### Build & Usage
- **[REQUIREMENTS.md](REQUIREMENTS.md)** - v0.15.0 scope and acceptance criteria
- **[USAGE.md](USAGE.md)** - How to build and run (basic queries only)

## Quick Status

Based on CANARY evidence analysis (2025-09-20):

### ✅ What Works (30-35%)
- Basic SQL-like queries (RETURN, ORDER BY, GROUP BY)
- Set operations (UNION/INTERSECT/EXCEPT)
- MVCC transactions (BEGIN/COMMIT)
- CDC core engine (no Kafka/Kinesis)
- Schema constraints (check, unique, pattern)
- Basic path operations
- Wire protocol

### ❌ What Doesn't Work (65-70%)
- **Distributed** - No Raft, no sharding (0% implemented)
- **GPU acceleration** - Complete fake (0% implemented)
- **ML algorithms** - Not implemented (0% implemented)
- **Query optimization** - No cost-based optimizer
- **Graph algorithms** - No PageRank, shortest path, etc.
- **Materialized views** - All TODOs
- **QUIC transport** - Returns NotImplemented
- **Full-text search** - Not implemented
- **Multi-graph** - Basic structures only

## Verification

All claims must be backed by CANARY evidence:

```bash
# Build the scanner
make canary

# Verify current state
./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict

# Check specific requirement
grep -r "CANARY: REQ=REQ-GQL-" src/ tests/
```

## Documentation Standards

1. **No undocumented claims** - Every feature claim needs a CANARY token
2. **Evidence-based** - STATUS must be TESTED or BENCHED, not STUB
3. **Archived aspirations** - Non-working features moved to `docs/archive/`
4. **Regular verification** - CI runs canary checks on every commit

## For Contributors

Before claiming a feature is implemented:
1. Add CANARY token to implementation
2. Write actual test (not stub test)
3. Ensure test passes
4. Update GAP_ANALYSIS.md
5. Run verification

Example CANARY token:
```zig
// CANARY: REQ=REQ-GQL-XXX; FEATURE="Feature Name"; ASPECT=Component; 
// STATUS=TESTED; TEST=TestCANARY_REQ_GQL_XXX_FeatureName; 
// OWNER=team; UPDATED=2025-09-20
```

## Historical Note

Previous documentation claimed 95% completion. CANARY analysis reveals actual implementation is 30-35%. All aspirational documentation has been archived to `docs/archive/`.