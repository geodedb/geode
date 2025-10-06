# Geode Graph Database - Ground Truth Documentation

**Version**: v0.18.0  
**Generated**: 2025-09-29  
**Status**: CONSOLIDATED FROM ALL SOURCES

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Core Architecture](#core-architecture)
3. [Data Model & Types](#data-model--types)
4. [Query Language (GQL)](#query-language-gql)
5. [Storage & Persistence](#storage--persistence)
6. [Distributed Systems](#distributed-systems)
7. [Security & Governance](#security--governance)
8. [Performance & Scalability](#performance--scalability)
9. [Client Interfaces](#client-interfaces)
10. [Development & Operations](#development--operations)
11. [Implementation Status](#implementation-status)
12. [Known Gaps & Roadmap](#known-gaps--roadmap)

---

## Executive Summary

Geode is an open-source, ACID-compliant graph database implementing the ISO/IEC 39075:2024 Graph Query Language (GQL) standard. Written in Zig 0.15.1+ for low-level efficiency, it emphasizes:

- **Standards Compliance**: Full ISO/IEC 39075:2024 GQL implementation
- **Security-First Design**: QUIC+TLS only, no plaintext TCP
- **Evidence-Based Governance**: CANARY system tracks 608+ features with test/benchmark evidence
- **Enterprise Features**: MVCC transactions, WAL recovery, distributed reads, audit logging
- **Advanced Type System**: 50+ data types including network, spatial, temporal, cryptographic

### Key Differentiators

1. **Transport**: QUIC+TLS exclusively (no TCP fallback)
2. **Determinism**: Bounded path expansions, US001 pagination guard
3. **Governance**: Automated evidence tracking via CANARY markers
4. **Type System**: First-class support for IP/CIDR, geographic, cryptographic types
5. **Security**: TDE, RLS/ABAC, tamper-evident audit logs

---

## Core Architecture

### System Components

```
┌─────────────────────┐
│   Client Layer      │
│  (CLI/REPL/SDK)     │
└──────────┬──────────┘
           │ QUIC+TLS
┌──────────▼──────────┐
│   Protocol Layer    │
│  (Binary Frames)    │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│   Query Engine      │
│  (Parser/Planner)   │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│  Execution Engine   │
│  (MATCH/WCOJ)       │
└──────────┬──────────┘
           │
┌──────────▼──────────┐
│   Storage Layer     │
│  (Pages/WAL/Index)  │
└─────────────────────┘
```

### Key Modules

- **Parser/Lexer** (`src/gql/`): Complete ISO GQL grammar implementation
- **Planner** (`src/planner/`): Cost-based optimization, WCOJ implementation
- **Storage** (`src/storage/`): Page management, WAL, MVCC
- **Index** (`src/index/`): B-tree, HNSW, R-tree, Patricia trie
- **Distributed** (`src/distributed/`): Raft consensus, 2PC coordination
- **Security** (`src/security/`): TDE, RLS, audit, MFA

---

## Data Model & Types

### Property Graph Model

Geode implements the ISO property graph model with:
- **Nodes**: Entities with labels and properties
- **Edges**: Directed relationships with types and properties
- **Properties**: Key-value pairs with strong typing

### Type System (50+ Types)

#### Core Types
- **Null** (tag: 0x00)
- **Boolean** (tag: 0x01)
- **Integer** types: SmallInt(i16), Int(i32), BigInt(i64)
- **Float** types: Real(f32), Double(f64) - NaN/Inf forbidden
- **Decimal128**: 38-digit precision with banker's rounding
- **String** types: Char(n), Varchar(n), Text

#### Temporal Types
- **Date**: ISO-8601 YYYY-MM-DD
- **Time/TimeTZ**: Microsecond precision
- **Timestamp/TimestampTZ**: UTC storage
- **Interval**: ISO-8601 duration

#### Network Types
- **IpAddr**: IPv4/IPv6 with RFC canonicalization
- **Cidr**: CIDR notation with prefix operations
- **MacAddr**: IEEE 802 MAC addresses

#### Geographic Types
- **Point2D/Point3D**: Cartesian coordinates
- **GeoPoint**: WGS84 lat/lon
- **LineString/Polygon**: OGC geometries
- **Box2D/Box3D**: Bounding boxes

#### Advanced Types
- **UUID**: RFC 4122 variants
- **Json/Jsonb**: Binary JSON with indexing
- **XML**: Well-formedness validation
- **Vector**: Fixed-dimension float arrays
- **Bytea**: Binary data
- **BitString**: Variable-length bit sequences
- **URL**: RFC 3986 validation
- **Hash types**: MD5, SHA1, SHA256, SHA512

#### Cryptographic Types
- **CryptoKey**: Public/private keys
- **CryptoSignature**: Ed25519/RSA signatures
- **CryptoCertificate**: X.509 certificates

### Index Support

- **B-tree**: Default for ordered data
- **HNSW**: Vector similarity search (KNN)
- **R-tree**: Spatial indexing
- **Patricia trie**: CIDR/prefix matching
- **GIN**: Inverted indexes for JSONB
- **Interval tree**: Range queries
- **Domain trie**: Hierarchical data

All indexes support:
- Transactional consistency
- WAL persistence
- Snapshot isolation
- Concurrent access

---

## Query Language (GQL)

### ISO/IEC 39075:2024 Compliance

Complete implementation of ISO GQL with:
- MATCH patterns for graph traversal
- CREATE/UPDATE/DELETE for mutations
- WHERE predicates with full expression support
- ORDER BY with deterministic ordering
- LIMIT/OFFSET with US001 guard
- Aggregations and grouping
- Subqueries and WITH clauses

### Example Queries

```gql
-- Find friends of friends
MATCH (person:Person {name: "Alice"})-[:KNOWS]->(friend)-[:KNOWS]->(fof)
WHERE person <> fof
RETURN DISTINCT fof.name
ORDER BY fof.name
LIMIT 10

-- Shortest path
MATCH path = shortestPath(
  (a:City {name: "Paris"})-[:ROAD*]-(b:City {name: "Berlin"})
)
RETURN path, length(path) AS distance

-- Pattern with variable-length paths (bounded)
MATCH (n:Node)-[r:REL*1..5]->(m:Node)
WHERE n.id = 100
RETURN m
```

### Query Safety Features

- **US001 Guard**: Prevents unordered LIMIT (configurable)
- **Bounded Expansions**: Max 10,000 frontier nodes
- **Result Limits**: Max 100,000 results per expansion
- **Deterministic Ordering**: Stable sort for pagination

---

## Storage & Persistence

### Page Management

- **Slotted pages**: 8KB default size
- **CSR adjacency**: Compressed sparse row format
- **Copy-on-write**: For MVCC isolation
- **Free space management**: First-fit allocation

### Write-Ahead Logging (WAL)

- **ARIES protocol**: Analysis, Redo, Undo
- **LSN tracking**: Log sequence numbers
- **Checkpoint**: Periodic consistency points
- **Compression**: LZ4 for log entries

### MVCC Implementation

- **Snapshot isolation**: Read from consistent snapshot
- **Optimistic concurrency**: Conflict detection at commit
- **Version chains**: Multi-version storage
- **Garbage collection**: Background cleanup

### Crash Recovery

1. **Analysis phase**: Rebuild transaction table
2. **Redo phase**: Replay committed changes
3. **Undo phase**: Rollback incomplete transactions

---

## Distributed Systems

### Federation Architecture

```
┌──────────────┐
│  Coordinator │
└──────┬───────┘
       │
   ┌───┴───┐
   │       │
┌──▼──┐ ┌──▼──┐
│Shard│ │Shard│
│  1  │ │  2  │
└─────┘ └─────┘
```

### Raft Consensus (specs/raft/zaft)

Custom "Zaft" implementation with:
- Leader election
- Log replication  
- Membership changes
- Snapshot transfer

### Two-Phase Commit (2PC)

- **Coordinator**: Transaction management
- **Participants**: Shard-level voting
- **Recovery**: Presumed abort protocol
- **Timeout**: Configurable deadlines

### Current Limitations

- ✅ Federated reads across shards
- ❌ Cross-shard writes (planned)
- ❌ Automatic resharding (planned)

---

## Security & Governance

### Transport Security

- **QUIC+TLS 1.3**: Mandatory encryption
- **mTLS**: Optional client certificates
- **No plaintext**: TCP explicitly forbidden

### Data Encryption (TDE)

- **AES-256-GCM**: Page-level encryption
- **Key management**: External KMS integration
- **Key rotation**: Online rotation support
- **Performance**: ~15% overhead

### Access Control

#### Row-Level Security (RLS)
```sql
CREATE POLICY user_data_policy
  ON users
  FOR SELECT
  USING (user_id = current_user_id());
```

#### Attribute-Based Access Control (ABAC)
- Dynamic policy evaluation
- Context-aware permissions
- Hierarchical roles

### Audit Logging

- **Hash chain**: Tamper-evident log
- **Ed25519 signatures**: Cryptographic proof
- **Immutable storage**: Append-only design
- **Query logging**: Full statement capture

### Evidence Governance (CANARY)

Unique system for tracking implementation evidence:

```zig
// CANARY: REQ=REQ-GQL-XXX; FEATURE="Name"; ASPECT=Aspect; STATUS=TESTED; TEST=TestName; OWNER=team; UPDATED=2025-09-29
```

**Status Levels**:
- MISSING: Not implemented
- STUB: Placeholder
- IMPL: Implemented, needs testing
- TESTED: Has test coverage
- BENCHED: Has performance benchmarks

**Current Statistics** (608 features):
- TESTED: 365 (59.9%)
- BENCHED: 229 (37.6%)
- IMPL: 7 (1.1%)
- STUB: 6 (1.0%)

---

## Performance & Scalability

### Benchmarks

#### Query Performance
- Simple match: <1ms p99
- 3-hop traversal: <10ms p99
- Aggregations: Linear with result size
- Index lookups: O(log n) B-tree, O(1) hash

#### Throughput
- Writes: 10K TPS (single node)
- Reads: 100K QPS (with caching)
- Mixed: 50K ops/sec

#### Scalability
- Nodes: Tested to 1B nodes
- Edges: Tested to 10B edges
- Properties: Unlimited
- Concurrent connections: 10K (QUIC limited)

### Optimization Features

- **Cost-based optimizer**: Statistics-driven planning
- **Join algorithms**: Hash join, merge join, WCOJ
- **Predicate pushdown**: Early filtering
- **Index selection**: Automatic index choice
- **Query caching**: Prepared statement cache

---

## Client Interfaces

### Command-Line Interface

#### Server (`geoded`)
```bash
geoded --listen-quic 0.0.0.0:3141 \
       --data-dir /var/geode/data \
       --tls-cert server.crt \
       --tls-key server.key
```

#### Client (`geodec`)
```bash
geodec "MATCH (n) RETURN n LIMIT 10" \
       --server localhost:3141 \
       --format json
```

#### REPL (`gql`)
Interactive shell with:
- Syntax highlighting
- Auto-completion
- Query history
- Vi/Emacs keybindings

### Client Libraries

#### Go Client
```go
import "github.com/spyderorg/geode/clients/go"

client := geode.NewClient("localhost:3141")
result := client.Query("MATCH (n) RETURN n")
```

#### Python Client (Planned)
#### JavaScript Client (Planned)

### Binary Protocol

Frame-based protocol over QUIC:

```
┌────────────┬──────────┬─────────┐
│ Frame Type │  Length  │ Payload │
│  (1 byte)  │ (4 bytes)│ (varies)│
└────────────┴──────────┴─────────┘
```

**Frame Types**:
- HELLO (0x01): Handshake
- BEGIN (0x10): Start transaction
- RUN_GQL (0x20): Execute query
- PULL (0x30): Fetch results
- SCHEMA (0x40): Result metadata
- BINDINGS (0x50): Result data
- COMMIT (0x60): Commit transaction
- ROLLBACK (0x70): Abort transaction

---

## Development & Operations

### Building from Source

#### Prerequisites
- Zig 0.15.1+
- Go (for client libraries)
- Git submodules initialized

#### Build Commands
```bash
# Debug build
make build

# Release build
make release

# Run tests
make test

# Run benchmarks
make bench

# Full verification
make verify-all
```

### Docker Deployment

```bash
# Build image
make docker-build

# Run singleton
make docker-up-singleton

# Run cluster
make docker-up-distributed
```

### Configuration

#### Environment Variables
- `GEODE_ORDER_KEYS_EXPR`: Allow expressions in ORDER BY
- `GEODE_TELEMETRY_PAGING`: Enable telemetry
- `GEODE_CDC_ENABLE`: Enable change data capture
- `GEODE_QUIC_PASSIVE_TEARDOWN`: Passive connection cleanup

#### Storage Configuration
- Page size: 8KB (configurable)
- Cache size: Auto-tuned
- WAL segment: 16MB
- Checkpoint interval: 5 minutes

### Monitoring

#### Metrics (Prometheus)
- Query latency histograms
- Transaction throughput
- Storage utilization
- Index efficiency

#### Logging
- Structured JSON logs
- Configurable levels
- Audit trail integration

### Backup & Recovery

#### S3 Backup
```bash
geode-backup --mode full \
             --s3-bucket backups \
             --encrypt
```

#### Point-in-Time Recovery
- WAL archive to S3
- Incremental backups
- Consistent snapshots

---

## Implementation Status

### Completed Features (TESTED/BENCHED)

✅ **Core Database**
- ISO GQL parser and planner
- MVCC transactions
- WAL/ARIES recovery
- B-tree indexes
- Query execution engine

✅ **Advanced Features**
- 50+ data types
- Multiple index types
- Graph algorithms (22+)
- Cost-based optimization
- Federation for reads

✅ **Security**
- QUIC+TLS transport
- TDE implementation
- RLS/ABAC
- Audit logging
- MFA support

### In Progress (IMPL)

🚧 **Active Development**
- Leiden community detection
- 2PC coordinator improvements
- CDC enhancements
- WAL compaction pipeline
- Schema constraint evaluation

### Planned Features

📋 **Roadmap Items**
- Cross-shard writes
- Automatic resharding  
- Python/JS clients
- GraphQL adapter
- Kubernetes operator
- Time-series integration

---

## Known Gaps & Roadmap

### Critical Gaps

1. **Evidence Staleness**: >95% of CANARY markers are >120 days old
2. **Cross-shard Writes**: Not yet implemented
3. **Client Libraries**: Only Go client available
4. **Production Hardening**: Needs more field testing

### Q1 2025 Priorities

1. **Evidence Refresh**: Re-validate all CANARY markers
2. **Cross-shard Transactions**: Complete 2PC implementation
3. **Python Client**: Official SDK release
4. **Performance**: Achieve 100K TPS goal

### Q2 2025 Goals

1. **Kubernetes**: Official operator
2. **Time-series**: Native support
3. **ML Integration**: Vector operations
4. **Cloud Native**: AWS/GCP/Azure marketplace

### Long-term Vision

- Become the reference implementation for ISO GQL
- Enterprise-grade graph database platform
- Cloud-native distributed architecture
- ML/AI-ready graph analytics

---

## Appendix A: CANARY Evidence System

The CANARY system provides automated evidence tracking:

### Marker Format
```zig
// CANARY: REQ=identifier; FEATURE="name"; ASPECT=component; STATUS=IMPL; TEST=test_name; BENCH=bench_name; OWNER=team; UPDATED=2025-09-29
```

### Governance Workflow
1. Developer adds CANARY marker
2. CI validates evidence exists
3. Scanner generates status.csv
4. Dashboard tracks compliance

### Tools
- `tools/canaryscan`: Evidence scanner
- `make status-generate`: Update status
- `make governance-check`: Validate

---

## Appendix B: Development Guidelines

### Code Style
- Zig fmt for formatting
- Minimal comments (code should be clear)
- CANARY markers for all features
- Tests follow naming convention

### Testing Requirements
- Unit tests for components
- Integration tests for features
- Canary tests for governance
- Benchmarks for performance

### Contributing
1. Fork repository
2. Create feature branch
3. Add CANARY markers
4. Write tests
5. Update documentation
6. Submit pull request

---

## Appendix C: Glossary

- **ABAC**: Attribute-Based Access Control
- **ARIES**: Algorithm for Recovery and Isolation Exploiting Semantics
- **CANARY**: Evidence-based governance system
- **CDC**: Change Data Capture
- **CSR**: Compressed Sparse Row
- **GQL**: Graph Query Language (ISO/IEC 39075:2024)
- **HNSW**: Hierarchical Navigable Small World
- **LSN**: Log Sequence Number
- **MVCC**: Multi-Version Concurrency Control
- **QUIC**: Quick UDP Internet Connections
- **RLS**: Row-Level Security
- **TDE**: Transparent Data Encryption
- **US001**: Unordered Limit guard policy
- **WAL**: Write-Ahead Log
- **WCOJ**: Worst-Case Optimal Join

---

## References

1. ISO/IEC 39075:2024 - Information technology — Database languages — GQL
2. ARIES: A Transaction Recovery Method (Mohan et al., 1992)
3. RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport
4. RFC 5952 - A Recommendation for IPv6 Address Text Representation
5. OGC Simple Features Specification

---

*This ground truth documentation represents the consolidated state of the Geode project as of 2025-09-29, merging information from 100+ documentation files, source code analysis, and CANARY evidence tracking.*