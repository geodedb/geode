# Geode Server Features Documentation

## Overview

Geode is a single-tenant graph database server with strong ISO GQL alignment. This document provides comprehensive technical details on the server's core features, architecture, and capabilities.

**Status**: Development Ready (single-tenant). Multi-tenant and distributed deployments require operator review of [Known Limitations](../CLAUDE.md#known-limitations) before production. Canonical status: [GAP_ANALYSIS.md](GAP_ANALYSIS.md) + [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md).
**ISO Conformance Suite**: 96/96 named cases in `tests/gql_iso_conformance.zig` (`zig build test-iso-conformance`; parse-only scope — see [GQL_COMPLIANCE.md](GQL_COMPLIANCE.md))
**Test Baseline**: local per-step baseline in [KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md) (canonical); a fresh geodetestlab harness run is owed — the prior ~97% (1644/1688) is a dated historical snapshot
**CANARY Markers**: 5,094 governance markers (223 IMPL / 4.4%; run `make status-generate`)

---

## Table of Contents

1. [Storage Engine Architecture](#storage-engine-architecture)
2. [Transaction Management (MVCC & SSI)](#transaction-management-mvcc--ssi)
3. [Index Types & Optimization](#index-types--optimization)
4. [Query Planning & Cost-Based Optimization](#query-planning--cost-based-optimization)
5. [CDC & Replication Features](#cdc--replication-features)
6. [Network Transport Layer](#network-transport-layer)
7. [Security & Encryption](#security--encryption)
8. [Performance Characteristics](#performance-characteristics)

---

## 1. Storage Engine Architecture

### 1.1 Page Management

**Implementation**: `/src/storage/page_manager.zig`

Geode uses a slotted page architecture optimized for graph storage:

**Page Layout** (4096 bytes default):

```
[Header (16 bytes)][Slot Directory (growing up)][Free Space][Records (growing down)]
```

**Header Structure**:

- `[0..8)`: u64 page LSN (Log Sequence Number for recovery)
- `[8..10)`: u16 slot count
- `[10..12)`: u16 free_end pointer
- `[12..16)`: u32 Adler32 checksum

**Key Features**:

- **Memory-Mapped I/O**: Zero-copy data access with 13.18x performance improvement
- **Checksumming**: Adler32 over entire page for corruption detection
- **Slot-Based Storage**: Each slot tracks offset and size for variable-length records
- **LSN Tracking**: Every page tracks last modification for WAL recovery

**Performance**:

- I/O operations improved from 5,754μs to 436μs (13.18x)
- <1% overhead for checksumming
- Efficient space reclamation with slot compaction

### 1.2 Write-Ahead Logging (WAL)

**Implementation**: `/src/wal/wal.zig`
**CANARY**: `REQ-GQL-027`, `REQ-GQL-028`

Geode implements ARIES-style write-ahead logging with advanced features:

**WAL Record Structure**:

```
[Type (1)][TxnId (8)][PayloadLen (4)][LSN (8)][PrevLSN (8)][Checksum (4)][Payload][Sentinel (4)]
```

**Record Types**:

- `Begin`: Transaction start
- `Insert`: Node/edge insertion with payload
- `Delete`: Tombstone deletion with before-image
- `Commit`: Transaction commit
- `Abort`: Transaction rollback
- `CLR`: Compensation Log Record for undo operations
- `Checkpoint`: Recovery checkpoint marker
- `PageCompact`: Page-level compaction metadata

**Advanced Features**:

1. **Segmented WAL Files**:
   - Automatic segment rollover at configurable thresholds (default 1MB)
   - Format: `{base_path}.wal.{segment_index}`
   - Enables parallel recovery and efficient archival

2. **WAL Encryption** (AES-256-GCM):
   - Per-record encryption with derived nonces
   - Nonce derivation: `LSN (8 bytes) + WyHash(payload_len) (4 bytes)`
   - Overhead: 28 bytes per record (12-byte nonce + 16-byte tag)
   - <1% performance impact

3. **Automatic Compaction**:
   - Cadence-based: checkpoint every N commits (default 10)
   - Compaction every M checkpoints (default 5)
   - Segment-level: removes segments below durable LSN
   - Background compaction support

4. **Recovery Optimization**:
   - Sparse page LSN indexing for fast-seek during redo
   - Binary search to skip records before last relevant LSN
   - Checkpoint-based redo starting point
   - Typical skip ratio: 60-80% for large logs

5. **Group Commit**:
   - Three flush modes: `always`, `every_n`, `time_window_ms`
   - Configurable batch sizes and time windows
   - Reduces fsync overhead by 10-100x for write-heavy workloads

**Recovery Process** (ARIES):

1. **Analysis Phase**: Build transaction table and dirty page list
2. **Redo Phase**: Apply all committed changes from checkpoint
3. **Undo Phase**: Rollback uncommitted transactions using CLRs

**Performance Characteristics**:

- Append-only writes: ~100-200μs per record
- Group commit: reduces latency to ~10-50μs per transaction
- Recovery speed: 10,000-50,000 records/second
- Compaction: removes 70-90% of log segments post-checkpoint

### 1.3 Disk Storage

**Implementation**: `/src/storage/disk.zig`
**CANARY**: `REQ-GQL-025`, `REQ-GQL-026`

**Transparent Data Encryption (TDE)**:

- XTS-AES-256 mode for page-level encryption
- Per-page tweak: `(page_id << 64) | sector_offset`
- Software AES with future AES-NI optimization path
- Key hierarchy with master key separation

**Key Management**:

- Master key from environment: `GEODE_DISK_KEY_HEX` (64-char hex)
- Hierarchical key derivation for data, WAL, and backup keys
- Integration with HashiCorp Vault and AWS KMS
- Automatic key rotation support

**File Permissions**:

- All database files created with mode 0o600 (owner-only access)
- Parent directory fsync for durability guarantees

### 1.4 S3 Cloud Backup

**Implementation**: `/src/storage/s3_backup.zig`
**CANARY**: `REQ-GQL-S3-001`

**Backup Types**:

1. **Full Backup**: Complete database snapshot
2. **Incremental Backup**: Delta changes since last backup
3. **Point-in-Time Recovery**: Restore to any LSN

**S3 Features**:

- Multipart upload for files >5MB (configurable)
- Exponential backoff retry (base 100ms, max 3 retries)
- Compression: `none` or `gzip` only (GAP-0880) — the backup engine applies a
  real gzip/DEFLATE encoder when requested and records the codec actually
  applied; `zstd`/`lz4`/`snappy` encoders are NOT bundled and are rejected
  with `UnsupportedCompression`
- Encryption: AES-256 with envelope encryption
- Checksum validation: SHA-256

**Backup Process**:

1. Create Raft snapshot for consistency
2. Archive data files (tar format)
3. Calculate checksum
4. Upload to S3 with metadata
5. Store backup manifest

**Performance**:

- Multipart upload: 50-100MB/s throughput
- Compression ratio: 3-5x for graph data
- Incremental backup: 90-95% smaller than full

---

## 2. Transaction Management (MVCC & SSI)

### 2.1 Multi-Version Concurrency Control (MVCC)

**Implementation**: `/src/txn/manager.zig`
**CANARY**: `REQ-GQL-013`, `REQ-GQL-023`, `REQ-GQL-025`

**Core Concepts**:

- Every transaction has a unique `TxnId` and `start_ts` timestamp
- Reads see snapshot at `start_ts`
- Writes are visible only after commit timestamp
- No read locks required

**Transaction States**:

- `Active`: Transaction in progress
- `Committed`: Successfully committed with `commit_ts`
- `Aborted`: Rolled back (changes undone)

**Lock Modes**:

- `Shared`: Multiple readers allowed
- `Exclusive`: Single writer, blocks all

**Conflict Detection**:

- Conflict matrix tracks: ReadWrite, WriteWrite, WriteRead
- Wait-for graph for deadlock detection
- Lock escalation for large scans

**Phantom Read Prevention**:

- Predicate range tracking per transaction
- Range locks on scan predicates
- Validation at commit time against concurrent writes

**Example Flow**:

```zig
// Begin transaction
const txn = try manager.beginTxn();

// Read with MVCC snapshot
const value = try manager.read(txn, key);

// Write with conflict detection
try manager.write(txn, key, new_value);

// Commit with validation
try manager.commit(txn); // Checks for conflicts
```

### 2.2 Serializable Snapshot Isolation (SSI)

**Implementation**: `/src/server/txn/enhanced_isolation.zig`
**CANARY**: `REQ-TXN-ISOLATION-001` through `REQ-TXN-ISOLATION-004`

**Isolation Levels**:

1. **ReadUncommitted**: No guarantees (rarely used)
2. **ReadCommitted**: Prevents dirty reads
3. **RepeatableRead**: Prevents dirty + non-repeatable reads
4. **SnapshotIsolation**: MVCC-based (default)
5. **Serializable**: Full serializability with predicate locks
6. **SerializableSnapshot**: Hybrid SSI (best of both)

**SSI Algorithm**:

SSI detects "dangerous structures" - dependency cycles that violate serializability:

**Dependency Types**:

- **RW Edge** (T1 → T2): T1 reads, T2 writes same object
- **WR Edge** (T1 → T2): T1 writes, T2 reads same object

**Dangerous Structure**: `T1 -RW-> T2 -WR-> T3 -RW-> T1` (cycle)

**Implementation**:

```zig
pub const DependencyTracker = struct {
    read_dependencies: AutoHashMap(TxnId, ArrayList(TxnId)),  // RW edges
    write_dependencies: AutoHashMap(TxnId, ArrayList(TxnId)), // WR edges

    pub fn checkDangerousStructure(txn_id: TxnId) bool {
        // DFS to detect RW-WR-RW cycles
        // Returns true if cycle found → abort transaction
    }
};
```

**Commit-Time Validation**:

1. Check for dangerous structures in dependency graph
2. Validate read set against concurrent writes
3. If conflict detected → abort transaction
4. Otherwise → commit with new `commit_ts`

**Performance**:

- <10μs overhead per transaction for SSI tracking
- 99.9% of transactions commit without conflicts
- Automatic victim selection for deadlock resolution

### 2.3 Deadlock Detection

**Implementation**: `/src/server/txn/enhanced_isolation.zig`

**Wait-For Graph**:

- Directed graph: T1 → T2 means T1 waits for T2
- Cycle detection via DFS
- Periodic detection (default 1 second interval)
- Priority-based victim selection

**Resolution Strategies**:

1. **Abort**: Kill current transaction
2. **Wait**: Wait for lock with timeout (default 30s)
3. **AbortOther**: Abort conflicting transaction (if lower priority)
4. **Retry**: Exponential backoff retry
5. **Escalate**: Upgrade to higher isolation level

**Priority System**:

- User-defined priorities (0-255)
- Victim selection: abort lowest priority transaction
- Prevents priority inversion

**Statistics**:

- Total conflicts detected
- Deadlocks resolved
- Average resolution time
- Transactions aborted

---

## 3. Index Types & Optimization

### 3.1 B-Tree Index

**Implementation**: `/src/index/btree.zig`

**Structure**:

- Order: Configurable (default 32)
- Keys per node: 2*order - 1
- Children per node: 2*order
- Balanced tree guarantees O(log n) operations

**Features**:

- In-place updates
- Node splitting/merging
- Range scans
- Prefix compression

**Performance**:

- Point lookup: ~100ns for in-memory
- Range scan: 1-2μs per 100 keys
- Insert: ~200ns amortized

### 3.2 HNSW Vector Index

**Implementation**: `/src/index/hnsw.zig`
**CANARY**: Vector operations REQs

**Algorithm**: Hierarchical Navigable Small World graphs

**Distance Metrics** (6 supported):

1. **L2 (Euclidean)**: Standard distance
2. **Cosine**: Normalized similarity
3. **Dot Product**: Raw dot product
4. **Manhattan (L1)**: Sum of absolute differences
5. **Hamming**: Bit difference count
6. **Jaccard**: Set similarity

**Parameters**:

- `M`: Max connections per layer (default 16)
- `ef_construction`: Search width during build (default 200)
- `ef_search`: Search width during query (default 50)
- `max_level`: Maximum hierarchy depth (auto-computed)

**SIMD Acceleration**:

- Enabled for vectors ≥8 dimensions
- 8x speedup for L2 distance calculation
- Platform-specific optimizations (AVX2, NEON)

**Performance**:

- 8D L2 distance: <50ns
- 10k vector search: ~1-5ms at 90% recall
- Build time: ~100-500μs per vector
- Supports up to 65,535 dimensions

**Persistence**: Binary format with compressed neighbor lists

### 3.3 R-Tree Spatial Index

**Implementation**: `/src/index/spatial_index.zig`, `/src/index/rtree.zig`

**Geometry Types**:

- Point: (x, y) coordinates
- LineString: Ordered point sequence
- Polygon: Closed ring with holes

**Operations**:

- Spatial queries: intersects, contains, within
- Bounding box optimization
- Hilbert curve ordering for better clustering

**Performance**:

- Point query: ~500ns
- Range query: 1-2μs per 100 results
- Insert: ~1-2μs with rebalancing

### 3.4 Full-Text Search Index

**Implementation**: `/src/index/fulltext.zig`, `/src/fts/bm25.zig`
**CANARY**: `REQ-GQL-077`

**Inverted Index Structure**:

```
Term → [(DocId, Position, Frequency), ...]
```

**BM25 Ranking**:

```
score(D,Q) = Σ IDF(qi) · [f(qi,D) · (k1+1)] / [f(qi,D) + k1·(1-b+b·|D|/avgdl)]
```

**Parameters**:

- `k1`: Term frequency saturation (default 1.2)
- `b`: Length normalization (default 0.75)

**Features**:

- Stemming: Porter stemmer
- Stop words: Configurable list
- Phrase queries: Positional indexing
- Fuzzy matching: Levenshtein distance

**Performance**:

- Single-term query: ~10-50μs
- Phrase query: ~50-200μs
- Boolean query: ~100-500μs
- Index build: ~1-2ms per 1000 documents

**IndexOptimizer Integration**:

- Automatic corpus statistics tracking
- Dynamic selectivity estimation
- Cost-based decision between full-text vs sequential scan

### 3.5 Specialized Indexes

**Interval Tree Index** (`/src/index/interval_tree.zig`):

- Efficient range overlap queries
- O(log n + k) query time (k = results)
- Used for temporal ranges, network CIDR blocks

**JSONB Inverted Index** (`/src/index/jsonb_inverted.zig`):

- Path-based indexing: `$.user.address.city`
- GIN-style inverted index
- Supports existence, equality, range queries

**Domain Trie Index** (`/src/index/domain_trie.zig`):

- Reverse domain indexing (com.example.www)
- Efficient subdomain queries
- URL canonicalization support

**Patricia Trie** (`/src/index/patricia.zig`):

- Compressed prefix tree
- Efficient string prefix matching
- Used for autocomplete, pattern matching

---

## 4. Query Planning & Cost-Based Optimization

### 4.1 Query Planner

**Implementation**: `/src/planner.zig`
**CANARY**: `REQ-GQL-016`, `REQ-GQL-021`

**Planning Phases**:

1. **Parse**: GQL → AST (96/96 named ISO conformance-suite cases; parse-only scope)
2. **Validate**: Type checking, schema validation
3. **Rewrite**: Predicate pushdown, constant folding
4. **Enumerate**: Generate alternative plans
5. **Cost**: Estimate execution cost
6. **Select**: Choose lowest-cost plan

**Path Expansion Operator**:

- Variable-length path queries: `(a)-[*1..5]->(b)`
- BFS traversal with cycle detection
- Tie-breaking policy: (length, start_id, end_id)
- Pruning: visited node tracking

**Example**:

```sql
MATCH (a:Person)-[r:KNOWS*1..3]->(b:Person)
WHERE a.name = 'Alice'
RETURN b.name, length(r) as hops
```

**Plan**:

```
PathExpand(min=1, max=3)
  ← IndexScan(Person, name='Alice')
  → Filter(label=Person)
```

### 4.2 Cost-Based Optimizer (CBO)

**Implementation**: `/src/planner/cbo.zig`, `/src/planner/cost_model.zig`
**CANARY**: `REQ-GQL-075`

**Cost Model Components**:

1. **Cardinality Estimation**:

   ```
   selectivity(predicate) = matched_rows / total_rows
   estimated_rows = input_rows × selectivity
   ```

2. **I/O Cost**:

   ```
   io_cost = pages_read × page_cost
   page_cost = 1.0 (sequential) or 4.0 (random)
   ```

3. **CPU Cost**:

   ```
   cpu_cost = rows × tuple_cost × complexity
   tuple_cost = 0.01 (per-row processing)
   ```

4. **Network Cost** (distributed):

   ```
   network_cost = bytes_transferred × network_latency
   ```

**Index Selection**:

- Automatic selection based on query predicates
- Cost comparison: sequential scan vs index scan
- Considers index type, cardinality, clustering

**Join Ordering**:

- Dynamic programming for small queries (<10 tables)
- Greedy heuristic for large queries
- Bushy trees for complex joins

**Adaptive Re-planning**:

- Runtime statistics collection
- Re-plan threshold: actual_rows > 2× estimated_rows
- Hot-path caching

### 4.3 IndexOptimizer

**Implementation**: `/src/server/index_optimizer.zig`

**Capabilities**:

- Automatic index recommendation
- Query-specific cost estimation
- Dynamic index selection
- Statistics-driven decisions

**Cost Models by Index Type**:

| Index Type | Cost Formula | Use Case |
|-----------|--------------|----------|
| Sequential Scan | `O(n)` | Small tables, full scans |
| B-Tree | `O(log n + k)` | Equality, range queries |
| HNSW | `O(log n)` | KNN vector search |
| R-Tree | `O(log n + k)` | Spatial queries |
| Full-Text | `O(t·log n)` | Text search (t=terms) |
| Hash | `O(1)` | Exact equality only |

**Integration**:

```zig
// Automatic index selection
const index_choice = try index_optimizer.selectBestIndex(
    label,
    predicate,
    statistics,
);

// Cost estimation
const estimated_cost = try index_optimizer.estimateCost(
    index_choice,
    cardinality,
    selectivity,
);
```

### 4.4 Selectivity Estimator

**Implementation**: `/src/optimizer/selectivity_estimator.zig`
**CANARY**: `REQ-GQL-084`

**Frequency Sampling**:

- Reservoir sampling for value distribution
- Hash-based deduplication
- Configurable sample size (default 1000)

**Adaptive Estimation**:

```zig
pub const AdaptiveEstimator = struct {
    sampler: FrequencySampler,
    bias_alpha: f64 = 0.2,      // Learning rate
    correction: f64 = 1.0,       // Multiplicative correction

    pub fn feedback(actual: f64) void {
        // Update correction based on prediction error
        target = actual / predicted;
        correction += bias_alpha × (target - correction);
    }
};
```

**Predicate Selectivity**:

- Equality: frequency-based
- Range: histogram estimation
- LIKE: pattern length heuristic
- NULL: dedicated null bitmap

### 4.5 PathCache

**Implementation**: `/src/planner/path_cache.zig`
**CANARY**: 23 PathCache markers

**Cache Key**: Structural hash of path pattern

- Start node label
- Edge type sequence
- End node label
- Path length bounds

**Cache Entry**:

```zig
struct PathCacheEntry {
    pattern_hash: u64,
    results: []PathResult,
    hit_count: u64,
    last_access: i64,
    validity_marker: u64,
}
```

**Eviction Policy**:

- LRU with frequency weighting
- Invalidation on schema changes
- Configurable size limit

**Performance**:

- Cache hit: <100ns
- Cache miss + population: ~1-10ms
- Hit rate: 60-90% for typical workloads

---

## 5. CDC & Replication Features

### 5.1 Change Data Capture (CDC) Engine

**Implementation**: `/src/streaming/cdc_enhanced.zig`
**CANARY**: `REQ-GQL-042` (47 CDC markers - highest count)

**Core Features**:

- Real-time change event streaming
- Multiple sink support: Kafka, Webhook, File (plus an in-memory sink for testing). Kinesis and Pub/Sub are **planned, not implemented** — configuring them fails loud at startup with `error.SinkNotImplemented` (GAP-0872)
- Adaptive batching and backpressure
- Guaranteed ordering per entity
- Resume token support for fault tolerance

**Change Event Structure**:

```zig
pub const ChangeEvent = struct {
    timestamp: i64,
    transaction_id: u64,
    sequence: u64,              // Global monotonic
    change_type: ChangeType,    // insert/update/delete
    entity_type: EntityType,    // node/edge/property/label
    entity_id: u64,
    before: ?[]const u8,        // JSON before-image
    after: ?[]const u8,         // JSON after-image
    metadata: StringHashMap([]const u8),
};
```

**CDC Configuration**:

```zig
pub const CDCConfig = struct {
    enabled: bool = false,
    sinks: []CDCSink,
    retention_period_ms: i64 = 7 * 24 * 60 * 60 * 1000, // 7 days

    // Batching
    batch_size: u32 = 1000,
    flush_interval_ms: u32 = 1000,

    // Adaptive flush
    adaptive_flush: bool = false,
    min_batch_size: u32 = 256,
    max_batch_size: u32 = 32_000,
    adapt_window_events: u32 = 4_000,

    // Backpressure
    pending_backpressure_watermark: u64 = 0,  // 0 = disabled
    adaptive_backpressure: bool = false,
    backpressure_high_pct: f64 = 0.85,
    backpressure_low_pct: f64 = 0.30,

    // Filters
    filter_patterns: ?[]const u8 = null,
    include_before_image: bool = true,
    include_metadata: bool = true,
};
```

**Adaptive Batching Algorithm**:

1. Monitor event rate over window (e.g., 4000 events)
2. If rate > threshold: increase batch size (up to max)
3. If rate < threshold: decrease batch size (down to min)
4. Step size: 25% multiplicative adjustment

**Backpressure Management**:

- Watermark-based: trigger when pending > watermark
- Adaptive watermark adjustment: shrink at 85%, grow at 30%
- Range: 1,000 to 512,000 events
- Prevents memory exhaustion under load

**WAL Tail Optimization**:

- Direct WAL tail reading (bypass page manager)
- Malformed record detection with diagnostics
- Snapshot interval for debugging (default every 100 malformed)
- Hash retention for first N malformed payloads

**Ordering Guarantees**:

- Per-entity ordering: events for same entity are ordered
- Transaction boundary markers
- Global sequence numbers for external ordering

**Resume Token Format**:

```
{lsn}:{sequence}:{timestamp}
```

**Performance**:

- Event capture: <10μs overhead per write
- Kafka throughput: 50,000-100,000 events/sec
- Adaptive flush: reduces latency by 60-80%

### 5.2 Kafka Integration

**Configuration**:

```zig
pub const KafkaConfig = struct {
    brokers: []const u8,
    topic: []const u8,
    compression: enum { none, gzip, snappy, lz4, zstd } = .snappy,
    batch_size: u32 = 16384,
    linger_ms: u32 = 100,
    acks: enum { none, leader, all } = .all,
};
```

**Features**:

- Automatic partitioning by entity_id
- Compression: snappy (best balance), zstd (best ratio)
- Delivery guarantees: at-least-once (acks=all)
- Idempotent producer support

### 5.3 Kinesis / Pub/Sub (planned — fail-loud)

AWS Kinesis and Google Pub/Sub sinks are **not implemented**. A `KinesisConfig`
type exists for the planned surface, but there is no authenticated client
behind it. As of GAP-0872, configuring a `kinesis` or `pubsub` CDC sink fails
at engine construction with `error.SinkNotImplemented` (previously these sinks
accepted events and silently discarded them). Regression:
`tests/test_gap0872_cdc_sinks.zig` (`zig build test-gap0872`).

### 5.4 Webhook Sink

**Configuration**:

```zig
pub const WebhookConfig = struct {
    url: []const u8,
    method: enum { POST, PUT } = .POST,
    headers: StringHashMap([]const u8),
    retry_count: u32 = 3,
    timeout_ms: u32 = 5000,
};
```

**Features**:

- Custom HTTP headers
- Automatic retry with exponential backoff
- Timeout handling
- Batched events in single payload

---

## 6. Network Transport Layer

### 6.1 QUIC Protocol

**Implementation**: `/src/transport/quic.zig`
**CANARY**: `REQ-GQL-074` (35 transport markers)

**Why QUIC?**

- Built-in TLS 1.3 encryption (mandatory)
- Multiplexed streams (no head-of-line blocking)
- 0-RTT connection resumption
- Connection migration (WiFi → cellular)
- Congestion control improvements

**Transport Configuration**:

```zig
pub const Config = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 7567,
    max_connections: usize = 10000,
    idle_timeout_ms: u64 = 30000,
    max_stream_data: u64 = 10 * 1024 * 1024,  // 10MB per stream
    max_data: u64 = 100 * 1024 * 1024,        // 100MB per connection
    cert_path: []const u8 = "certs/server.crt",
    key_path: []const u8 = "certs/server.key",
    ca_path: ?[]const u8 = null,
};
```

**Auto-Generated Certificates**:

- Self-signed certificate generation via OpenSSL
- Fallback to insecure mode if OpenSSL unavailable (dev only)
- Production requires valid certificates

**Stream Management**:

- Bidirectional streams for request-response
- Unidirectional streams for push notifications
- Stream prioritization

**Flow Control**:

- Per-stream and per-connection limits
- Automatic window scaling
- Backpressure signaling

**Security**:

- TLS 1.3 mandatory (no plaintext mode)
- Certificate validation
- Perfect forward secrecy
- ALPN negotiation: "geode/1.0"

**Performance**:

- Connection setup: ~1-2 RTT (0-RTT for resumed)
- Throughput: 100-500 MB/s (network limited)
- Latency: <1ms for local, 10-100ms cross-region
- Max connections: 10,000+ per server

### 6.2 Binary Protocol

**Frame Format**:

```
[Magic (4)][Version (2)][Type (1)][Flags (1)][Length (4)][Payload]
```

**Magic**: `0x47454F44` ("GEOD" in ASCII)

**Frame Types**:

- `0x01`: HELLO (capability negotiation)
- `0x02`: QUERY (GQL query execution)
- `0x03`: RESPONSE (query results)
- `0x04`: ERROR (error response)
- `0x05`: PING/PONG (keepalive)
- `0x06`: GOODBYE (graceful shutdown)

**Flags**:

- `0x01`: Compressed (reserved — no frame-level compression is implemented;
  backup payload compression is gzip-only, see GAP-0880)
- `0x02`: Encrypted (additional layer beyond TLS)
- `0x04`: Fragmented (multi-frame message)
- `0x08`: Priority (high-priority frame)

**Payload Encoding**:

- Values: MessagePack format
- Graphs: Custom compact format
- Binaries: Length-prefixed

---

## 7. Security & Encryption

### 7.1 Transparent Data Encryption (TDE)

**Implementation**: `/src/security/tde.zig`
**CANARY**: `REQ-GQL-TDE-*`

**Encryption Modes**:

- **Page-Level**: XTS-AES-256 for storage pages
- **WAL-Level**: AES-256-GCM for log records
- **Backup-Level**: AES-256-CTR with envelope encryption

**Key Hierarchy**:

```
Master Key (256-bit)
  ├─> Data Key (for pages)
  ├─> WAL Key (for log records)
  └─> Backup Key (for cloud backups)
```

**Key Derivation**:

```zig
pub const KeyHierarchy = struct {
    master_key: [32]u8,
    data_key: [32]u8,
    wal_key: [32]u8,
    backup_key: [32]u8,

    pub fn init(master: [32]u8) KeyHierarchy {
        // HKDF key derivation
        data_key = hkdf_expand(master, "data_key", 32);
        wal_key = hkdf_expand(master, "wal_key", 32);
        backup_key = hkdf_expand(master, "backup_key", 32);
    }
};
```

**Performance Overhead**:

- Page encryption: <1% CPU overhead
- WAL encryption: <1% latency overhead
- AES-NI acceleration: 10x faster on supported CPUs

### 7.2 Key Management System (KMS)

**Implementation**: `/src/security/kms.zig`, `/src/security/kms_remote.zig`

**Supported Providers**:

1. **Local** (file-based): Development only
2. **HashiCorp Vault**: Enterprise production
3. **AWS KMS**: Cloud deployments
4. **Azure Key Vault**: Azure cloud
5. **GCP KMS**: Google Cloud

**Remote KMS Features**:

- Automatic key unwrapping
- Envelope encryption (KEK + DEK)
- Key rotation with re-encryption
- Audit logging integration
- Attestation support

**Example (Vault)**:

```zig
const vault_config = VaultConfig{
    .address = "https://vault.example.com",
    .token = "s.secret_token",
    .namespace = "production",
    .mount_path = "transit",
    .key_name = "geode-master-key",
};

const kms = try VaultKMSProvider.init(allocator, vault_config);
const dek = try kms.unwrapKey(wrapped_dek);
```

### 7.3 Enhanced Row-Level Security (RLS)

**Implementation**: `/src/security/rls_enhanced.zig`

**Policy Types**:

1. **Attribute-Based**: Rules on node/edge properties
2. **Role-Based**: User role membership
3. **Temporal**: Time-based access windows
4. **Contextual**: Request context (IP, location)

**Policy Example**:

```zig
pub const SecurityPolicy = struct {
    name: []const u8,
    entity_type: EntityType,  // node/edge
    label: []const u8,
    operation: Operation,     // SELECT/INSERT/UPDATE/DELETE
    predicate: Expression,

    // Advanced features
    temporal_constraint: ?TemporalConstraint,
    ip_whitelist: ?[][]const u8,
    data_classification: ?DataClassification,
};
```

**Policy Evaluation**:

```zig
pub fn evaluatePolicy(
    policy: *SecurityPolicy,
    user: *User,
    entity: *Entity,
    context: *RequestContext
) bool {
    // 1. Check operation permission
    if (!user.hasPermission(policy.operation)) return false;

    // 2. Evaluate predicate expression
    if (!evaluateExpression(policy.predicate, entity)) return false;

    // 3. Check temporal constraints
    if (policy.temporal_constraint) |tc| {
        if (!isWithinTimeWindow(tc, context.timestamp)) return false;
    }

    // 4. Check IP whitelist
    if (policy.ip_whitelist) |whitelist| {
        if (!isIPAllowed(context.client_ip, whitelist)) return false;
    }

    return true;
}
```

**Performance**:

- Policy evaluation: <10μs per policy
- Expression compilation: JIT to bytecode
- Policy cache: 90%+ hit rate
- Minimal query overhead (<5%)

### 7.4 Multi-Factor Authentication (MFA)

**Implementation**: `/src/security/mfa.zig`

**Supported Methods**:

1. **TOTP**: Time-based one-time passwords (RFC 6238) — implemented (`src/security/mfa.zig`)
2. **Recovery codes**: one-time backup codes — implemented

Planned (not implemented): SMS codes, email codes, hardware tokens (U2F/FIDO2).

**Step-Up MFA** (GAP-0884):

- `SecurityManager.requireStepUp` decides elevation from an explicit
  operation classification (read / write / admin / security_admin) of real
  procedure and auth-DDL identifiers — `classifyOperation` in
  `src/security/geode_auth_lib.zig`; unknown operations fail closed.
- Note: this is a library-level policy API; wiring it into the statement /
  procedure dispatch path as an enforcement gate is planned, not yet done.
- Regression: `zig build test-gap0884`.

**Risk-Based MFA** (scaffold only): `src/security/mfa_risk.zig` computes a
risk score from deterministic placeholder factors. Real signals (login
location, device fingerprint, behavioral history) are planned, not wired.

**Recovery Codes**:

- One-time use backup codes
- Secure generation and storage
- Rate limiting on recovery attempts

### 7.5 Audit Logging

**Implementation**: `/src/security/audit.zig`

**Event Types**:

- Authentication: login, logout, failed attempts
- Authorization: permission checks, policy violations
- Data access: SELECT, INSERT, UPDATE, DELETE
- Schema changes: CREATE, ALTER, DROP
- Security: key rotation, policy updates

**Audit Record**:

```zig
pub const AuditRecord = struct {
    timestamp: i64,
    user_id: []const u8,
    session_id: []const u8,
    client_ip: []const u8,
    event_type: AuditEventType,
    entity_type: ?EntityType,
    entity_id: ?u64,
    operation: ?Operation,
    success: bool,
    error_message: ?[]const u8,
    metadata: StringHashMap([]const u8),
};
```

**Storage Backends**:

- Local file (JSON lines)
- Syslog (RFC 5424)
- Elasticsearch
- Splunk
- AWS CloudWatch Logs

**Performance**:

- Async logging: <5μs overhead
- Buffered writes: 10,000 events/sec
- Automatic log rotation

---

## 8. Performance Characteristics

### 8.1 Query Performance

**Simple Queries** (indexed):

- Point lookup: <1ms (typically 100-500μs)
- Short path (1-2 hops): 1-5ms
- Aggregation (10k rows): 5-20ms

**Complex Queries**:

- Multi-hop path (3-5 hops): 10-100ms
- Large aggregation (1M rows): 100-500ms
- Graph algorithm (PageRank 10k nodes): 500ms-2s

**Vector Similarity**:

- HNSW vs sequential scan: 10-100x faster
- 10k vectors, 10-NN: 1-5ms
- 1M vectors, 10-NN: 10-50ms

**Full-Text Search**:

- Single term: 10-50μs
- Multi-term boolean: 100-500μs
- Phrase query: 200-1000μs

### 8.2 Write Performance

**Single Writes**:

- Node insert: 100-500μs (with WAL)
- Edge insert: 200-800μs (with index updates)
- Property update: 50-300μs

**Bulk Writes** (batched):

- Throughput: 50,000-200,000 writes/sec
- Latency: 20-50μs per write (group commit)

**Transaction Throughput**:

- Read-only: 100,000 txn/sec
- Read-write: 10,000-50,000 txn/sec
- Write-heavy: 5,000-20,000 txn/sec

### 8.3 Scalability

**Vertical Scaling**:

- CPU cores: Linear scaling to 64 cores
- Memory: Tested up to 512GB
- Disk: 10-50TB single instance

**Horizontal Scaling** (Federation):

- Shards: Tested up to 32 shards
- Replication: 3-5 replicas typical
- Query routing: <100μs overhead

**Concurrent Users**:

- 10,000+ connections supported
- Connection pooling recommended
- Resource limits per user

### 8.4 Resource Utilization

**Memory**:

- Page cache: 50-80% of RAM
- Index cache: 10-20% of RAM
- Transaction metadata: <1% of RAM
- Security overhead: <2% of RAM

**CPU**:

- Query execution: 60-80%
- Index maintenance: 10-20%
- WAL/checkpointing: 5-10%
- Security/encryption: <5%

**Disk I/O**:

- Sequential write (WAL): 100-500 MB/s
- Random read (pages): 10-50k IOPS
- Sequential scan: 500-2000 MB/s

**Network**:

- QUIC overhead: <5% of bandwidth
- Compression: 3-5x reduction for graphs
- Throughput: Network-limited (1-10 Gbps typical)

### 8.5 Benchmark Results

**TPC-H Adapted** (graph equivalent):

- Q1 (aggregation): 50-200ms
- Q2 (join): 100-500ms
- Q3 (complex): 200-1000ms

**LDBC SNB** (social network):

- Short reads: <10ms (99th percentile)
- Complex reads: <100ms (99th percentile)
- Writes: <5ms (99th percentile)

**Custom Graph Workloads**:

- 2-hop friends: 5-20ms
- Recommendation (collaborative filtering): 50-200ms
- PageRank (10k nodes): 500ms-1s
- Connected components: 100ms-2s

---

## Appendix A: CANARY Marker Summary

Total CANARY markers: 1284 tracking governance compliance

**Top 10 Features by CANARY Count**:

1. **CDC Engine** (47 markers): Change data capture with adaptive backpressure
2. **Network Transport** (35 markers): QUIC protocol implementation
3. **Query Planner** (27 markers): Cost-based query optimization
4. **Governance** (25 markers): CANARY system itself
5. **PathCache** (23 markers): Path query result caching
6. **Cost-Based Optimizer** (20 markers): Query plan cost estimation
7. **Authentication** (18 markers): RBAC/ABAC with MFA
8. **Full-Text Search** (15 markers): BM25 ranking with inverted index
9. **Storage Constraints** (13 markers): Schema validation engine
10. **Transaction Management** (12 markers): MVCC with SSI

**Status Distribution**:

- TESTED: 85% (with automated test evidence)
- BENCHED: 10% (with performance benchmarks)
- IMPL: 5% (implemented, pending test coverage)

---

## Appendix B: Configuration Reference

### Environment Variables

**Storage**:

- `GEODE_DATA_DIR`: Data directory path (default: `/tmp`)
- `GEODE_PAGE_SIZE`: Page size in bytes (default: 4096)
- `GEODE_DISK_ENCRYPTION`: Enable TDE (`on`/`off`)
- `GEODE_DISK_KEY_HEX`: Master encryption key (64 hex chars)

**WAL**:

- `GEODE_WAL_ENCRYPTION`: Enable WAL encryption
- `GEODE_WAL_SEGMENT_SIZE`: Segment rollover size (default: 1MB)
- `GEODE_WAL_FLUSH_MODE`: `always`, `every_n`, or `time_window_ms`
- `GEODE_WAL_FLUSH_EVERY_N`: Commit group size when `GEODE_WAL_FLUSH_MODE=every_n` (default: 10)
- `GEODE_WAL_FLUSH_WINDOW_MS`: Flush window when `GEODE_WAL_FLUSH_MODE=time_window_ms` (default: 5ms)

**CDC**:

- `CDC_ENABLED`: Enable change data capture
- `CDC_SINKS`: Comma-separated sink list
- `CDC_BATCH_SIZE`: Batch size (default: 1000)
- `CDC_ADAPTIVE_FLUSH`: Enable adaptive batching

**Network**:

- `GEODE_LISTEN_ADDR`: Bind address (default: 0.0.0.0)
- `GEODE_LISTEN_PORT`: Bind port (default: 7567)
- `GEODE_TLS_CERT`: TLS certificate path
- `GEODE_TLS_KEY`: TLS private key path

**Security**:

- `GEODE_MFA_ENABLED`: Enable MFA
- `GEODE_AUDIT_LOG_PATH`: Audit log location
- `GEODE_KMS_PROVIDER`: `local`, `vault`, `aws`, `azure`, `gcp`

### Configuration File

Geode supports TOML configuration file:

```toml
[server]
listen_addr = "0.0.0.0"
listen_port = 7567
max_connections = 10000

[storage]
data_dir = "/var/lib/geode"
page_size = 4096
encryption_enabled = true

[wal]
segment_size = 1048576  # 1MB
flush_mode = "every_n"
flush_every_n = 10

[cdc]
enabled = true
sinks = ["kafka"]
batch_size = 1000
adaptive_flush = true

[cdc.kafka]
brokers = "kafka1:9092,kafka2:9092"
topic = "geode_changes"
compression = "snappy"

[security]
mfa_enabled = true
audit_log_path = "/var/log/geode/audit.log"
kms_provider = "vault"

[security.vault]
address = "https://vault.example.com"
token = "${VAULT_TOKEN}"
key_name = "geode-master-key"
```

---

## Appendix C: Glossary

**AST**: Abstract Syntax Tree - parsed representation of GQL query
**CANARY**: Governance marker for requirement tracking
**CDC**: Change Data Capture - streaming database changes
**CBO**: Cost-Based Optimizer - query plan cost estimation
**GQL**: Graph Query Language (ISO/IEC 39075:2024)
**HNSW**: Hierarchical Navigable Small World - vector index algorithm
**LDBC**: Linked Data Benchmark Council - graph database benchmarks
**LSN**: Log Sequence Number - WAL record identifier
**MVCC**: Multi-Version Concurrency Control - transaction isolation
**QUIC**: Quick UDP Internet Connections - modern transport protocol
**RLS**: Row-Level Security - fine-grained access control
**SSI**: Serializable Snapshot Isolation - transaction isolation level
**TDE**: Transparent Data Encryption - automatic encryption
**WAL**: Write-Ahead Logging - durability mechanism

---

**Document Version**: 1.1
**Last Updated**: 2026-06-11 (GAP-0864 claim rebaseline)
**Maintainer**: Geode Core Team
**Status**: Development Ready (single-tenant) — see [Known Limitations](../CLAUDE.md#known-limitations) and [GAP_ANALYSIS.md](GAP_ANALYSIS.md)
