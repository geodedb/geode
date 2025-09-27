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

## Additional Data Types (constructor‑only; persisted indexes)

- Implemented: numeric (SmallInt/Int/BigInt, Real/Double, Decimal128), strings (Char/Varchar/Text), boolean, temporal (Date/Time/TimeTZ/Timestamp/TimestampTZ/Interval), bytea, json/jsonb (canonical), xml, url/domain, uuid, enum, array, bit/varbit, range.
- Constructors over function calls; grammar unchanged.
- Persisted indexes: Interval‑Tree (ranges), JSONB Inverted (paths), Domain Trie (reverse labels), plus existing Patricia, R‑tree, HNSW.
- Protocol JSON updated for canonical forms (GeoJSON, IDNA URL/Domain, Decimal128 string fallback).

See specs/advanced-types/type-extensions-2-pr.md for acceptance lines; evidence present in status.csv and tests/benches.

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
- **Remote KMS Hardening**: Auth negative matrix, attestation tamper/expiry, concurrency stress variance; OLTP overhead threshold test synced to docs.
- **Attestation**: Ed25519 signature + hash verified; tamper + expired vectors tested.
- **MFA**: Enrollment, recovery codes (single-use), elevation (TTL enforced), re-auth interval policy, and audit lifecycle events implemented. Remaining gap: per-action risk sensitivity & step-up latency variance (planned slice) + geo/IP adaptive policies.
- **Auth/RLS/Audit**: All enforced with deterministic planner rewrites + audit event emission.
- **Secrets Handling**: Zeroization utilities tested; key material wiped post-envelope creation.
- **Performance Validation**: Internal OLTP sim test asserts TDE overhead <5%; external publication + doc sync outstanding.
- **2PC**: Experimental; not production hardened (unchanged).

> See `SECURITY_PROGRESS.md` and `GAP_ANALYSIS.md` for CANARY-aligned evidence matrix; variance and overhead figures are traceable to benchmark JSON outputs.

## Partially Working Features

### ✅ Multi-threading

**Reality**: Full work-stealing thread pool with adaptive chunk sizing and pipelined parallel operators.

- **Thread Pool**: Active by default with work-stealing scheduler (auto-detects CPU count).
- **Work Stealing**: Each worker has local deque, steals from others when idle.
- **Adaptive Chunking**: Dynamic chunk size based on workload characteristics and performance history.
- **Parallel Operators**: `parallelMap` with ordering preservation, parallel pipeline execution.
- **Determinism**: Ordered barrier + deterministic assembly maintained.
- **Load Balancing**: Automatic work distribution across workers with priority support.
- **Pipeline Support**: Multi-stage parallel pipelines with per-stage parallelism control.
- **Performance**: Benchmarked at >100k ops/sec for parallel expand operations.

### ✅ Advanced FTS

**Reality**: Full-featured text search with BM25 scoring, language analyzers, and advanced features.

- **BM25 Scoring**: Complete implementation with BM25F multi-field variant
- **Language Analyzers**: Simple, whitespace, English (with stemming/stop words), standard Unicode
- **Stemming**: Porter2 algorithm implementation for English
- **Features**: Phrase queries, proximity search, highlighting, fuzzy matching (Levenshtein)
- **N-grams**: Support for n-gram generation and matching
- **Synonyms**: Query expansion with synonym dictionary
- **Phonetic**: Soundex algorithm for phonetic matching
- **Index Stats**: HyperLogLog for cardinality, document/term frequency tracking
- **Search Engine**: Integrated search with ranking and highlighting

### ✅ Storage Layer

**Reality**: Production-ready with cloud backup and comprehensive additional data types

- **MVCC**: Snapshot isolation working
- **WAL**: ARIES-style recovery tested
- **Pages**: Slotted pages with compression
- **Backup**: S3 full + incremental with checksums
- **Recovery**: Point-in-time restore working
- **Types**: Additional Data Types (constructor-only) as listed above
- **Indexes**: Patricia (CIDR), R-tree (spatial), Interval‑Tree (ranges), JSONB Inverted (paths), Domain Trie (suffix), HNSW (vector) — all persisted via snapshot+WAL

### ✅ Graph Algorithms

**Reality**: Comprehensive graph algorithm library with optimizations for large graphs.

- **Shortest Path**: BFS-based shortestPath(), allShortestPaths() with cycle detection
- **Centrality**: pageRank(), betweennessCentrality(), closenessCentrality(), eigenvectorCentrality()
- **Community Detection**: Louvain algorithm, label propagation
- **Degree Analysis**: In/out/total degree calculations with directional support
- **Optimizations**: Sampling for large graphs, caching, parallel execution support
- **Performance**: Wasserman-Faust improvements for disconnected graphs
- **API**: Full GQL function integration in RETURN clauses

### ✅ Cost-Based Optimizer

**Reality**: Advanced CBO with histograms, adaptive cost models, and machine learning integration.

- **Histograms**: Equi-width, equi-depth, frequency, height-balanced, compressed types
- **Statistics**: HyperLogLog for distinct estimation, correlation tracking, null statistics
- **Cost Model**: Comprehensive with I/O, CPU, memory, network, parallel costs
- **Adaptive Learning**: Confidence scoring, cost history, automatic factor adjustment
- **Cardinality Estimation**: Advanced with caching, predicate selectivity, join selectivity
- **Join Enumeration**: Left-deep tree generation with permutation exploration
- **Index Support**: Index scan costing, clustered vs non-clustered differentiation
- **Parallel Costing**: Setup costs, degree of parallelism optimization
- **EXPLAIN**: Detailed JSON with cost breakdown, confidence scores, factor details

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
