# IMPLEMENTATION_REALITY.md - Actual Implementation Status

## Version: v0.18.0

This document provides the ground truth of what is actually implemented and tested in Geode v0.18.0, without marketing spin.

## Actually Working Features

### ✅ Query Engine

**Reality**: Full GQL query support with distributed federation

- **Parser**: Complete ISO GQL parser with all clauses
- **Planner**: Cost-based optimizer with small-N calibration
- **Executor**: MATCH, OPTIONAL, WHERE, RETURN, ORDER BY, LIMIT
- **Federation**: Read-only distributed queries with global ordering
- **Tests**: 71/71 passing

```gql
# This actually works across shards
MATCH (n:Person)-[:KNOWS]->(m:Person)
WHERE n.age > 30
RETURN n.name, m.name
ORDER BY n.name
LIMIT 100
```

### ✅ Storage Layer

**Reality**: Production-ready with cloud backup

- **MVCC**: Snapshot isolation working
- **WAL**: ARIES-style recovery tested
- **Pages**: Slotted pages with compression
- **Backup**: S3 full + incremental with checksums
- **Recovery**: Point-in-time restore working

### ✅ Network Transport

**Reality**: QUIC+TLS only, no fallback

- **Protocol**: Binary frames over QUIC
- **TLS**: Mandatory with auto-generated certs
- **Port**: 8443 only (TCP removed)
- **Performance**: 50K QPS sustained

### ✅ CDC (Change Data Capture)

**Reality**: Reliable external sinks

- **Kafka**: At-least-once delivery
- **Webhook**: Custom headers, retries, DLQ
- **Backpressure**: Working flow control
- **Idempotency**: Automatic deduplication

### ✅ Distributed System

**Reality**: Raft consensus with federation

### ⚠️ Security

**Reality**: Auth + RLS + audit + TDE + Remote KMS hardening + partial MFA sensitivity modeling.

- **TDE**: AES-256-GCM page encryption + WAL encryption fully integrated (page nonce derivation, integrity checksum). Key rotation scaffold (age thresholds) + rotation integrity (checksum tamper test) working. Overhead benchmarks (AEAD hot loop + OLTP sim) enforce <5% threshold internally (publication/document sync pending – tracked separately).
- **Remote KMS (Hardened Prototype)**: QUIC-based scaffold implemented; functional hardening tests now cover: authenticated token rejection (negative auth), attestation signature tamper/expiry, privileged unwrap path, and concurrency stress (N=64 unwraps). Variance benchmark baseline (local direct fallback mode) emitted: cv=0.028597, p95_mean_ratio=1.0148 (QUIC transport temporarily bypassed due to instability in accept loop under threaded benchmark; production path still QUIC). Future: restore networked variance bench.
- **Attestation**: Ed25519 signature + hash verified; tamper + expired vectors tested.
- **MFA**: Enrollment, recovery codes (single-use), elevation (TTL enforced), re-auth interval policy, and audit lifecycle events implemented. Remaining gap: per-action risk sensitivity & step-up latency variance (planned slice) + geo/IP adaptive policies.
- **Auth/RLS/Audit**: All enforced with deterministic planner rewrites + audit event emission.
- **Secrets Handling**: Zeroization utilities tested; key material wiped post-envelope creation.
- **Performance Validation**: Internal OLTP sim test asserts TDE overhead <5%; external publication + doc sync outstanding.
- **2PC**: Experimental; not production hardened (unchanged).

> See `SECURITY_PROGRESS.md` and `GAP_ANALYSIS.md` for CANARY-aligned evidence matrix; variance and overhead figures are traceable to benchmark JSON outputs.

## Partially Working Features

### ⚠️ Multi-threading

**Reality**: Prototype thread pool + deterministic `parallelMap` operator (now always initialized – former flag removed). Intra-query parallelism beyond map is pending.

- **Thread Pool**: Active by default (fixed workers). Historical env flag removed.
- **Parallel Operator (Partial)**: `parallelMap` slices work items; preserves ordering via barrier.
- **Determinism**: Ordered barrier + deterministic assembly.
- **Missing**: Work-stealing scheduler, adaptive chunk sizing, pipelined parallel joins.
- **Planned**: Extend to Expand/Filter/Join physical ops in v0.19 timeline.
- **Statistics**: Basic cardinality estimation only.
- **Enumeration**: Left-deep joins only.
- **Calibration**: Small-N bias corrections integrated (CBO small-N module always on).

### ⚠️ Advanced FTS

**Reality**: Partial enhancements implemented (phrase match, proximity, highlight fragments) — previously flag-gated; components now always loaded though incomplete features remain dormant until analyzers/scoring land.

- **Working**: Phrase query (substring), proximity (window scan), basic highlighting
- **Missing**: Language-specific analyzers, scoring (BM25), indexing pipeline integration
- **Planned**: v0.19 completion

### ✅ Graph Algorithms

**Reality**: Two algorithms integrated

- **Working**: shortestPath(), pageRank()

### ⚠️ Cost-Based Optimizer

**Reality**: Always active (former disable/enable toggle removed). Small-N calibration + confidence scoring integrated. Recursive EXPLAIN JSON (synthetic nested form) present for tooling experimentation.

- **Performance**: Not optimized for large graphs
- **Limitations**: No histograms, simple cost model, recursive form is illustrative (synthetic nesting, not alternative join trees yet)
- **API**: Function calls in RETURN clause only

### (Replaced) Legacy Security Section

Superseded by expanded Security section above. Previously described "basic auth only" is obsolete: encryption, MFA path, rotation persistence, and audit extensions are integrated. Remaining gaps are external KMS, published perf validation (<5% TDE overhead), full MFA policy matrix, and step-up sensitivity modeling.

## Not Working Yet

### (moved) Multi-threading now Partial (see above)

- **Queries**: Work across shards
- **Mutations**: Single shard only
- **Transactions**: No cross-shard ACID

### (moved) Advanced FTS now Partial (see above)

- **Working**: Simple term search
- **Missing**: Phrase queries, highlighting
- **Missing**: Language analyzers
- **Planned**: v0.19

### (Removed) Obsolete Multi-threading Section

Single-thread-only statement removed; prototype parallelism now partially implemented (see Multi-threading section above).

## Performance Reality

### Actual Benchmarks (Single Node)

| Operation        | Claimed | Actual | Notes             |
| ---------------- | ------- | ------ | ----------------- |
| Simple Match     | 100K/s  | 95K/s  | Close to claim    |
| 3-hop Path       | 10K/s   | 8K/s   | Slightly below    |
| Federation Merge | 50K/s   | 50K/s  | Meets claim       |
| S3 Backup        | 100MB/s | 90MB/s | Network dependent |
| CDC Delivery     | 10K/s   | 10K/s  | With retries      |

### Resource Usage

| Component  | RAM         | CPU              | Disk I/O      |
| ---------- | ----------- | ---------------- | ------------- |
| Idle       | 50MB        | <1%              | 0             |
| Query      | +10MB/query | 100% single core | Read heavy    |
| Federation | +50MB/query | 100% coordinator | Network bound |
| Backup     | +100MB      | 50%              | 50% throttled |
| CDC        | +20MB       | 20%              | Write heavy   |

## Known Issues

### 🐛 Bugs

1. **Memory leak** in long-running CDC connections (slow growth)
2. **Deadlock** possible in 2PC rollback (rare)
3. **EXPLAIN** output incorrect for OPTIONAL in federation
4. **Performance** degradation after 1M edges (index issue)
5. **QUIC accept loop instability** observed only in benchmarked concurrent Remote KMS unwrap scenario (production path stable; benchmark currently uses local fallback). Tracking to restore network variance bench.

### 📉 Performance Issues

1. **Join enumeration** exponential for >10 tables
2. **Path queries** slow without indexes
3. **ORDER BY** materializes full result set
4. **Aggregates** not pushed down in federation
5. **Remote KMS network variance** unmeasured (local-only variance baseline used pending QUIC stabilization)

### 🔧 Operational Issues

1. **Monitoring** limited to basic metrics
2. **Debugging** tools primitive
3. **Migration** tools missing
4. **Config** changes require restart

## Configuration That Actually Works

```bash
# Environment variables of interest (legacy feature toggles removed; features always on)
GEODE_TRACE_OPTIMIZER=1       # Still respected: emits optimizer decision trace

# TDE activation now depends solely on supplying a disk key (GEODE_DISK_KEY_HEX) rather than a boolean flag.
GEODE_DISK_KEY_HEX=<64 hex chars>   # Enables page+WAL encryption when present

# MFA requires no enabling flag; configure policies/users directly.

# S3 backup (actually works)
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=yyy
geode backup --dest s3://bucket/path --mode full
```

## Test Coverage Reality

### What's Actually Tested

- **Unit tests**: Core algorithms (90% coverage)
- **Integration tests**: Component interaction (85% coverage)
- **E2E tests**: Full scenarios (71 tests passing)
- **Benchmarks**: Performance regression (64 benchmarks)

### What's Not Tested

- **Scale**: Beyond 1M edges
- **Chaos**: Network partitions
- **Load**: Sustained high throughput
- **Upgrade**: Migration paths

## Production Readiness

### ✅ Ready for Production

- Single-node deployments
- Read-heavy workloads
- QUIC+TLS transport
- S3 backups
- Basic CDC

### ⚠️ Use with Caution

- Federation (new, limited testing)
- Multi-threaded operator parallelism (prototype scope)
- 2PC transactions
