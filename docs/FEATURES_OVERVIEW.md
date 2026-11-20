# Geode Features Overview

## 🏆 Enterprise Graph Database Platform

Geode is a feature-complete **single-tenant** graph database with enterprise-grade features, passing 106/106 cases of its ISO/IEC 39075:2024 GQL conformance suite (parse-only scope) (`tests/gql_iso_conformance.zig` — scoped to that suite; see [GQL_COMPLIANCE.md](GQL_COMPLIANCE.md) for residual limits). **DEVELOPMENT READY (single-tenant);** multi-tenant, distributed, and backup deployments require additional operator review — see Known Limitations in [CLAUDE.md](../CLAUDE.md) before production deployment.

### ✅ **All Planned Features Complete** (October 16, 2025)

All 7 development phases from the TODO list have been successfully implemented:

- ✅ **Phase 2**: Parser Extensions (Map literals, deep nesting)
- ✅ **Phase 3**: Set Operations (UNION/INTERSECT/EXCEPT)
- ❌ **Phase 4**: Transaction Isolation — not implemented in the server (no isolation levels, SSI or phantom-read prevention; the code was never compiled and was removed 2026-11-11, SONNY-6298). See [ENHANCED_TRANSACTION_ISOLATION.md](ENHANCED_TRANSACTION_ISOLATION.md)
- ✅ **Phase 5**: Distributed Coordination — Raft consensus and cluster management, replicating the documented write slice; no two-phase commit and no replicated DDL (nothing proposes a `txn_prepare`/`txn_decide` or `schema_change` entry; DDL is refused in cluster mode, SONNY-6547) (`src/distributed/`: 14,052 lines in 13 `.zig` files after SONNY-6563 deleted the modules the server never reached). Federated / scatter-gather query coordination is not implemented (that code was never compiled and was removed 2026-11-11, SONNY-6279)
- ✅ **Phase 6**: Materialized Views (3 refresh strategies; query rewrite is exact-match only, API level — GAP-0876)
- ✅ **Phase 7**: Graph Algorithms — the `CALL algo.*` procedures (`src/execution/centrality_algorithms.zig`). The "20-90% performance gains" came from `src/graph/centrality_optimized.zig` and its sibling `src/graph/` modules, which no build compiled or ran; they were removed 2026-11-13 (SONNY-6511) and no gain was ever measured on the server path

**Total**: ~13,554+ lines of production code | See [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md) for current test status
**Details**: See [completion_reports/](./completion_reports/) for comprehensive phase documentation

## 🎯 Core Features

### **Graph Query Language (GQL)**

- **ISO Conformance Suite**: 106/106 cases pass in the named conformance suite (`zig build test-iso-conformance`; parse-only scope) (scoped to that suite — see [GQL_COMPLIANCE.md](GQL_COMPLIANCE.md))
- **Advanced Pattern Matching**: Complex graph traversal patterns
- **Aggregation & Analytics**: Built-in statistical functions
- **Transaction Support**: ACID compliance with MVCC

### **Vector & Machine Learning**

- **Vector Types**: VectorF32/VectorI32 with SIMD acceleration
- **HNSW Indexing**: Hierarchical navigable small world for K-NN search
- **6 Distance Metrics**: L2, cosine, dot product, Manhattan, Hamming, Jaccard
- **ML Graph Embeddings**: Node2Vec, GraphSAGE, DeepWalk algorithms (experimental — simplified implementations, see [ML_GRAPH_EMBEDDINGS.md](ML_GRAPH_EMBEDDINGS.md))
- **Real-time Analytics**: Streaming pattern detection and anomaly analysis

### **Advanced Data Types**

- **50+ Specialized Types**: Network, geographic, cryptographic, temporal
- **Vector Operations**: High-dimensional similarity search
- **JSONB & XML**: Semi-structured data with indexing
- **Arrays & Ranges**: Multi-dimensional and interval operations

### **Time-Series** (timeseries-storage-backed)

Native Geode GQL extension (ISO GQL `CALL`-procedure form, the analog of
`CALL geode.fts.search`) backed by the external `timeseries-storage` LSM
library. A series is identified by a `(device_id, metric)` pair. `ts` and
`value` are **integers (`i64`) only** this release — float/decimal values are
rejected.

- **`CALL geode.ts.insert(device_id, metric, ts, value)`** — ingest one point (mutating)
- **`CALL geode.ts.insert_many(device_id, metric, [[ts, value], …])`** — batch ingest (mutating)
- **`CALL geode.ts.range(device_id, metric, start_ts, end_ts)`** — rows of `(ts, value)`, inclusive `[start_ts, end_ts]` (read-only)
- **`CALL geode.ts.last` / `bucket_avg` / `sample_by`** — newest point / fixed-width averages / interval downsampling (read-only)
- **Durable** (points survive restart); rides the generic GQL rows wire path over QUIC (no client/proto change)

```gql
CALL geode.ts.insert(1, 'cpu.load', 1000, 72);
CALL geode.ts.range(1, 'cpu.load', 0, 2000);   -- rows of (ts, value)
```

See [TIMESERIES.md](TIMESERIES.md) for the full reference.

## 🔐 Enterprise Security

### **Authentication & Authorization**

- **RBAC/ABAC**: Role and attribute-based access control
- **Row-level security**: policy evaluation and bytecode-compiled expression policies (`src/security/rls_core.zig`)
- **MFA**: TOTP enrollment and on-request verification procedures; not enforced at login yet (SONNY-6604)
- **Session Management**: Secure session handling

### **Data Protection**

- **TDE**: Transparent data encryption (AES-256-GCM pages and WAL); measured overhead +1.0% with the default per-commit fsync, about +29% on the commit path without fsync, +57% to +62% on reads that miss the buffer pool ([TDE_FILE_LEVEL_ENCRYPTION.md](TDE_FILE_LEVEL_ENCRYPTION.md#measured-overhead))
- **KMS Integration**: KMS provider clients, including HashiCorp Vault; the TDE master key is not KMS-backed (see [KMS_PROVIDER_SYSTEM.md](KMS_PROVIDER_SYSTEM.md))
- **Audit Logging**: Comprehensive compliance tracking
- **Data Classification**: 5-level security classification

### **Field-Level Encryption (FLE)** ✅ January 2026

- **Searchable Encryption**: not available. Blind indexes are designed but
  no field can be made searchable and no query uses them (see
  `docs/FIELD_LEVEL_ENCRYPTION.md`, "Searchable fields today")
- **Predicate Rewriting**: not available (the planner rewrite was removed;
  it never compiled)
- **RBAC Integration**: Role-based decryption permissions
- **Implementation**: `src/fle_integration.zig`

## 📦 Data Integrity & Recovery

### **Constraint Enforcement** ✅ January 2026

- **UNIQUE Constraints**: Enforced at the end of every statement on CREATE,
  MERGE, SET and the server's write fast paths, per graph and tenant, with
  SQLSTATE 23505 (SONNY-2846; see docs/API_REFERENCE.md, Constraint
  Operations). CREATE CONSTRAINT over existing duplicates is refused.
- **NOT NULL / EXISTS Constraints**: Enforced at the end of every
  statement on CREATE, MERGE, SET and REMOVE, with SQLSTATE 23502
  (SONNY-6281). CREATE CONSTRAINT over nodes lacking the property is refused.
- **NODE KEY Constraints**: Both halves enforced (existence 23502,
  uniqueness 23505)
- **CREATE UNIQUE INDEX**: Refused (0A000); use CREATE CONSTRAINT ... IS
  UNIQUE
- **Catalog Persistence**: Constraints stored across restarts; `DROP
  CONSTRAINT [IF EXISTS]` removes one from the session graph's catalog,
  durably (SONNY-6270)
- **Implementation**: `src/schema/catalog.zig`, `src/execution/unique_constraints.zig`

### **Point-in-Time Recovery** ✅ January 2026

- **WAL Replay**: Apply transaction logs after base restore
- **Arbitrary Timestamps**: Recover to any point in WAL coverage
- **Segment Management**: Ordered WAL file processing
- **Implementation**: `src/cli/backup_cli.zig`

### **Multi-Tenancy Support** -- Partial (January 2026)

- **What works:**
  - **Graph Isolation**: Separate graph stores per tenant
  - **FLE Per-Tenant Keys**: Field-level encryption with tenant-scoped key management
  - **Session Tenant ID**: Tenant context via QUIC handshake
  - **Protocol Support**: tenant_id field in HELLO message
- **In progress:**
  - **tenant_id enforcement**: Not yet enforced at query execution layer
  - **RLS expression engine**: Unrecognized expressions now fail-closed (GAP-0294) but expression coverage is incomplete
  - **Per-tenant quotas**: Not yet implemented
  - **Audit tenant tracking**: Infrastructure supports tenant_id but not all call sites populate it (GAP-0282)
- **Implementation**: `src/protocol.zig`, `src/server/server_state.zig`, `src/graph_store.zig`

### **TDE Page Storage** ✅ January 2026

- **Encrypted Page Read/Write**: Full AES-256-GCM encryption cycle
- **Authentication Tags**: Integrity verification on read
- **Page Locking**: Concurrent access control
- **Implementation**: `src/security/tde.zig`

### **TDE File-Level Encryption** ✅ January 2026

- **Index Persistence**: R-tree, HNSW, Patricia, Domain, JSONB, Interval indexes
- **Schema Catalogs**: Main catalog and FLE catalog encrypted
- **Distributed State**: the Raft log's entry data and snapshots are encrypted (SONNY-6571, `src/distributed/raft_tde_storage.zig`); the hard state (term, vote) is not
- **Magic Header**: `GEOTDEFL` identifies encrypted files
- **Key Management**: 256-bit key via `GEODE_TDE_KEY` environment variable
- **Documentation**: [TDE_FILE_LEVEL_ENCRYPTION.md](TDE_FILE_LEVEL_ENCRYPTION.md)
- **Implementation**: `src/storage/tde_file_encryption.zig`, `src/index/*_persist.zig`

## 🚀 Performance & Scalability

### **Query Optimization**

- **Planner**: rule-based index use (UNIQUE-indexed literal-equality seek through the merge index, otherwise a label scan); EXPLAIN shows fixed per-operator costs. The cost-based IndexOptimizer was never compiled and was removed 2026-11-11 (SONNY-6298)
- **Distributed Queries**: not implemented; a query runs on the node that receives it (federation code removed 2026-11-11, SONNY-6279)
- **Materialized Views**: Auto-refresh strategies; exact-match query rewrite (API level — not yet consulted by the executor; cost-based partial rewrite future, GAP-0876)

### **Storage Engine**

- **MVCC**: Multi-version concurrency control
- **Memory-Mapped I/O**: the id map and hydration snapshot are memory-mapped (`src/storage/id_map.zig`, `hydration_snapshot.zig`); the "13.18x" figure came from `src/performance/memory_mapped_io.zig`, which no server path uses (despite its name it reads a file into a heap buffer; only a benchmark test runs it), and no measurement backs it for the server (SONNY-6511)
- **Backup files**: `geode backup create` / `geode restore` write and read local files (`none` or `gzip` payloads); there is no S3-compatible object-storage path: copy backup files with your own tool (SONNY-6290)
- **WAL Optimization**: Write-ahead logging

### **Distributed Architecture**

- **Raft Cluster Mode**: Raft consensus with leader election and failover; writes replicated within the documented slice, unreplicated write surfaces fail closed (`GEODE_CLUSTER_TOKEN`)
- **Query Coordination**: not implemented; no cross-shard or federated query execution (see [DISTRIBUTED_QUERY_COORDINATION.md](DISTRIBUTED_QUERY_COORDINATION.md))

## 🌐 Integration & Connectivity

### **Network Protocols**

- **QUIC Transport**: Modern, secure network protocol
- **TLS Encryption**: End-to-end security
- **Interactive Shell**: Real-time REPL with history

### **Cloud Integration**

- **Object storage**: no S3 / Digital Ocean Spaces integration in the binary (backups are local files; GQL `BACKUP`/`RESTORE` statements not implemented)
- **Compression**: backup payload currently stored uncompressed (`.none`; no encoder wired — see Known Limitations)
- **Point-in-Time Recovery**: Granular backup restoration

## 📊 Analytics & Machine Learning

### **Graph Analytics**

- **Centrality Algorithms**: PageRank, betweenness, closeness
- **Community Detection**: Leiden algorithm implementation
- **Path Analysis**: Shortest path and traversal algorithms
- **Flow Networks**: Edmonds-Karp, Dinic algorithms

### **Real-time Processing**

- **Stream Analytics**: Pattern detection in real-time
- **Anomaly Detection**: ML-powered outlier identification
- **CDC Integration**: not implemented — the CDC engine starts and reports its state, but no write is captured (SONNY-6570; capture is SONNY-6572)
- **Performance Monitoring**: Real-time metrics collection

## 🛠️ Development Tools

### **CLI & REPL**

- **Unified Binary**: Single executable for all operations
- **Interactive Shell**: Feature-rich REPL with completion
- **Backup/Restore**: Built-in data management tools
- **User Management**: Administrative command suite

### **Testing & Quality**
<!-- Rebaselined 2026-06-10 (GAP-0861) against the canonical local baseline -->
- **Local Test Baseline**: 166/175 named `zig build test-*` steps pass (6 FAIL / 3 TIMEOUT, each with file:line evidence — see [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md))
- **Integration Suite (geodetestlab)**: a fresh `../geode-test-harness` run is owed; prior ~97% / 1644-1688 is kept as a dated historical snapshot in [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md)
- **CANARY System**: ~4,900 governance markers (≈80% TESTED, ≈10% IMPL, ≈6% EXEMPT, ≈4% BENCHED; run `make status-generate` for current counts)
- **Performance Benchmarks**: Automated regression testing
- **Cross-Platform**: Linux, macOS, Windows compatibility

## 📝 Documentation & Standards

### **Comprehensive Documentation**

- **API Reference**: Complete function documentation
- **Type System**: Detailed type specifications
- **Performance Guides**: Optimization best practices
- **Security Manuals**: Compliance and configuration

### **Standards Compliance**

- **ISO/IEC 39075:2024**: Graph Query Language standard (106/106 named conformance-suite cases pass, parse-only scope; scoped to that suite — see [GQL_COMPLIANCE.md](GQL_COMPLIANCE.md))
- **GDPR**: Audit logging and encryption at rest support GDPR compliance workflows (customer-side controls required for full compliance)
- **SOX**: Tamper-protected audit trails and retention policies support SOX audit requirements (customer-side controls required for full compliance)
- **HIPAA**: Encryption at rest (TDE) and audit logging support HIPAA technical safeguards (customer-side BAA and access controls required)
- **PCI-DSS**: Encryption and access event logging support PCI-DSS requirements (customer-side network segmentation and additional controls required)
- **Enterprise Governance**: Comprehensive audit trails with configurable retention and tamper protection

## 🔧 Configuration & Management

### **Flexible Configuration**

- **YAML/JSON Config**: Structured configuration files
- **Environment Variables**: Runtime configuration
- **Security Policies**: Fine-grained access controls
- **Performance Tuning**: Adaptive parameter optimization

### **Monitoring & Observability**

- **Metrics Collection**: Real-time performance data
- **Audit Events**: Security and operational logging
- **Health Checks**: System status monitoring
- **Alerting**: Configurable threshold alerts

## 🏁 Getting Started

### **Quick Start**

```bash
# Install and start server
./zig-out/bin/geode serve --listen-quic 0.0.0.0:3141

# Interactive shell
./zig-out/bin/geode shell

# Execute queries
./zig-out/bin/geode query "RETURN 1 AS result"
```

### **Example Queries**

```gql
-- Create nodes and relationships
CREATE (alice:Person {name: 'Alice', age: 30});
CREATE (bob:Person {name: 'Bob', age: 25});
CREATE (alice)-[:KNOWS]->(bob);

-- Vector similarity search
MATCH (doc:Document)
WHERE vector_cosine(doc.embedding, vectorf32('[0.1, 0.2, 0.3]')) > 0.8
RETURN doc.title ORDER BY similarity DESC

-- Real-time analytics
MATCH (user:User)-[:PERFORMED]->(action:Action)
WHERE action.timestamp > current_timestamp() - duration('PT1H')
RETURN user.id, count(action) AS recent_actions
```

## 🎯 Use Cases

### **Primary Applications**

- **Social Networks**: Relationship analysis and recommendation systems
- **Knowledge Graphs**: Semantic data modeling and querying
- **Fraud Detection**: Pattern analysis and anomaly detection
- **Recommendation Engines**: Vector similarity and collaborative filtering
- **Network Analysis**: Infrastructure and dependency mapping

### **Industry Solutions**

- **Financial Services**: Risk analysis and compliance monitoring
- **Healthcare**: Patient data modeling and research analytics
- **E-commerce**: Product recommendations and customer analytics
- **Cybersecurity**: Threat detection and network analysis
- **Supply Chain**: Logistics optimization and tracking

---

**For detailed technical information, see the complete documentation in [`./docs/`](./)**
