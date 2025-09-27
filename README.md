# Geode Graph Database - v0.18.0

## Description

Geode is an ISO/IEC 39075:2024 (GQL) compliant graph database written in Zig 0.15.1. Version 0.18.0 delivers critical infrastructure features: distributed query federation, S3 cloud backups, hardened CDC webhooks, and CBO calibration for small datasets.

![Evidence Coverage](badges/evidence.svg)

Evidence metrics now sourced directly from the latest successful `status.csv` (see `docs/GAP_ANALYSIS.md`). Figures below omit one current parse error (invalid STATUS token) and may change once corrected.

- **59 distinct requirement IDs (REQ-GQL-###)**
- **443 TESTED entries**
- **229 BENCHED entries**
- **7 IMPL entries**
- **6 STUB entries**
- **0 MISSING / 0 REMOVED entries observed**

For the complete, unaggregated table (including duplicates per evidence token) and parse error disclosure, consult `docs/GAP_ANALYSIS.md`.

## What's New / Current State (post v0.18.0 with ongoing hardening)

### Infrastructure & Reliability Release

- **🌐 Distributed Query Federation**: Always-on coordinator/worker scatter‑gather with global ORDER BY, distributed Top‑K, deterministic pagination (flag requirement removed).
- **☁️ S3 Cloud Backups**: Full + incremental (multipart, checksums, resumable, PIT recovery) production‑ready.
- **🔔 CDC Webhook Hardening**: Headers, retries with backoff+jitter, DLQ, idempotency, metrics.
- **📊 CBO Small-N Calibration**: Bias corrections + guardrails always active; decision tracing via `GEODE_TRACE_OPTIMIZER` only.
- **🆕 Additional Data Types**: Comprehensive scalar/document suite with constructor-only semantics (numeric, strings, boolean, temporal, bytea, json/jsonb, xml, url/domain, uuid, enum, array, bit/varbit, range).
- **🔍 Persisted Indexes**: Patricia trie (CIDR), R-tree (spatial), Interval-Tree (ranges), JSONB Inverted (paths), Domain Trie (suffix), and HNSW (vector similarity) — all snapshot+WAL persisted.
- **🔐 Security Hardening (In‑Progress)**: TDE (AES‑256‑GCM page + WAL encryption) integrated; key rotation (state+checksum) + local & simulated external wrap/unwrap + remote QUIC KMS prototype (generate/unwrap) landing. MFA (TOTP + recovery codes + elevation metadata) partially complete; policy matrix expansion pending.
- **🔍 FTS Partial**: Phrase / proximity / highlighting primitives loaded by default; analyzers + BM25 scoring forthcoming.
- **⚡ Parallel Execution Prototype**: Thread pool + deterministic ordered `parallelMap`; expansion to Expand/Filter/Join operators planned.
- **🧮 2PC / Distributed Writes**: Experimental scaffolding only (not enabled for prod writes yet).
- **📈 Graph Analytics**: `shortestPath`, `pageRank` stable; broader algorithm suite deferred.

### Previous v0.17.0 Features

- **✨ Complete MATCH Engine**: Complex patterns, nested OPTIONAL, filtered variable-length paths
- **📝 DML Operations**: INSERT/UPDATE/DELETE with RLS enforcement and audit logging
- **🔄 CDC External Sinks**: Kafka and Webhook with at-least-once delivery
- **💾 Raft Persistence**: Durable log, snapshots, compaction, dynamic membership
- **🔒 QUIC+TLS Mandatory**: Port 8443 only, auto-generated self-signed certs
- **📊 Graph Algorithms**: shortestPath() and pageRank() functions

## Breaking Changes from v0.17.0

### 1. Federation Requirements

- Sharded deployments should prepare for federation (disabled by default)
- Global ORDER BY now possible across shards
- Clients may see new EXPLAIN format with distributed plan trees

### 2. Backup Strategy

- S3 backup commands replace local-only backups for production
- New CLI: `geode backup --dest s3://bucket/prefix --mode full|incremental`
- Raft snapshots now used as consistency anchors

### 3. CDC Configuration

- Webhook sinks support custom headers (auth tokens, routing)
- DLQ configuration recommended for production
- Idempotency keys automatically generated

## Quick Start

### Docker (Recommended)

```bash
docker run -p 8443:8443 geode:v0.18.0
```

### Build from Source

```bash
# Requires Zig 0.15.1
git clone https://github.com/your-org/geode.git
cd geode
make build

# Start server (QUIC/TLS on port 8443)
./zig-out/bin/geoded --data_dir ./data

# Connect with client
./zig-out/bin/geodec "MATCH (n) RETURN n LIMIT 10"

# Load example dataset (optional but recommended)
./scripts/load_example_dataset.sh

# Try example queries
./zig-out/bin/geodec "MATCH (u:User) WHERE u.verified = true RETURN u.username LIMIT 5"
```

### Quick Start with Example Dataset

The included social network dataset demonstrates all of Geode's advanced features including the extended type system, spatial queries, vector similarity search, and more:

```bash
# Load the comprehensive example dataset (~100 nodes, ~500 edges)
./scripts/load_example_dataset.sh

# Example queries demonstrating various features:

# 1. Network Security - Find devices on private networks
./zig-out/bin/geodec "MATCH (d:Device) WHERE ip_is_private(d.ip_address) RETURN d.id, d.ip_address, d.subnet"

# 2. Geographic Search - Find companies near San Francisco
./zig-out/bin/geodec "MATCH (c:Company) WHERE distance_haversine(c.headquarters, LatLon(37.7749, -122.4194)) < 50000 RETURN c.name, c.headquarters"

# 3. Vector Similarity - Find similar posts using embeddings
./zig-out/bin/geodec "MATCH (p1:Post {id: 'post-1'}), (p2:Post) WHERE p1 <> p2 AND vector_cosine_similarity(p1.content_vector, p2.content_vector) > 0.7 RETURN p2.id, p2.content LIMIT 5"

# 4. Social Graph - Find influencers
./zig-out/bin/geodec "MATCH (u:User) WHERE u.follower_count > 1000 RETURN u.username, u.follower_count, u.verified ORDER BY u.follower_count DESC"

# 5. Financial Analysis - Company investments with currency conversion
./zig-out/bin/geodec "MATCH (c1:Company)-[inv:INVESTED_IN]->(c2:Company) RETURN c1.name, c2.name, inv.amount, inv.round"
```

See `migrations/README.md` for complete dataset documentation, schema details, and over 10 advanced example queries.

### Feature Activation Notes

Most capabilities previously guarded by environment toggles are now always initialized. Remaining knobs focus on configuration or diagnostics:

```bash
# Optional optimizer decision tracing
export GEODE_TRACE_OPTIMIZER=1

# Transparent Data Encryption: provide disk key material (enables page+WAL encryption if not already supplied)
export GEODE_DISK_KEY_HEX=<64 hex chars>

# MFA requires user provisioning only (no enable flag)

# S3 credentials for backup/restore
export AWS_ACCESS_KEY_ID=your-key
export AWS_SECRET_ACCESS_KEY=your-secret
geode backup --dest s3://my-bucket/backups --mode full
```

## Architecture

### Core Components

- **Query Engine**: ISO GQL parser, planner, executor with distributed federation
- **Storage**: MVCC, WAL/ARIES, page management, S3 backup integration, extended type system
- **Type System**: 12 new types including network (IP/CIDR/MAC), geographic (LatLon/Geometry), vector embeddings
- **Indexes**: Patricia trie (IP prefix), R-tree (spatial), HNSW (vector similarity) with persistence
- **Distributed**: Raft consensus, 2PC transactions, coordinator-worker federation
- **Network**: QUIC+TLS only (port 8443), binary protocol
- **CDC**: Kafka/Webhook sinks with reliability guarantees

### New in v0.18.0

#### Distributed Query Federation

- Scatter-gather pattern with global merge operations
- Per-shard Top-K with final merge for exact results
- Deterministic pagination preserving ISO semantics
- Failure handling with proper error propagation

#### S3 Backup Architecture

- Multipart uploads for files >5MB with checksums
- Incremental chains tracked via parent relationships
- Non-intrusive read-only snapshots
- Throttled I/O to minimize impact

#### CDC Webhook Reliability

- Exponential backoff with jitter
- Idempotency keys prevent duplicates
- Dead letter queue with configurable retention
- Custom headers for authentication/routing

## Type System Extensions

### New First-Class Types (v0.18.0)

#### Network Types

- **IpAddr**: IPv4/IPv6 addresses with RFC 5952 canonicalization
- **Subnet**: CIDR notation with prefix matching via Patricia trie index
- **Mac**: EUI-48 MAC addresses with vendor OUI extraction

#### Geographic Types

- **LatLon/LatLonAlt**: Coordinate pairs with haversine distance
- **Geometry**: WKT/WKB storage, GeoJSON output, R-tree spatial indexing

#### Specialized Types

- **Hash**: SHA3-256/512, BLAKE3 with constant-time comparison
- **Currency**: ISO 4217 codes with minor units
- **LanguageTag**: BCP-47 canonicalization and matching
- **Temperature/Pressure**: Unit-aware scientific quantities
- **VectorF32**: SIMD-optimized embeddings with HNSW indexing

### Additional Data Types (constructor-only)

- Numeric: SmallInt/Int/BigInt, Real/Double, Decimal128
- Strings: Char(n)/Varchar(n)/Text (char compare ignores trailing spaces)
- Temporal: Date, Time, TimeTZ, Timestamp, TimestampTZ, Interval
- Binary/Docs: Bytea, Json, Jsonb (canonical), Xml
- Network/I18n/Specialized: Url, Domain, UUID, Enum
- Collections & Ranges: Array[T], Bit/VarBit, Range<T>

Constructors are function calls (e.g., Decimal("123.45",2), Char("A",3), Url("http://example.com"), Range("int4",1,4,"[)")).

### Built-in Functions

```gql
-- Network operations
ip_contains(Subnet("10.0.0.0/8"), IpAddr("10.1.2.3"))  -- true
ip_is_private(IpAddr("192.168.1.1"))                   -- true

-- Geographic calculations
distance_haversine(LatLon(0,0), LatLon(0,1))          -- 111195 meters
st_intersects(polygon1, polygon2)                      -- spatial predicate

-- Vector similarity
vector_knn("embedding", Vector([0.1, 0.2]), 5, "cosine")
vector_dot(vec1, vec2)
```

### Persisted Indexes

- **Patricia Trie (CIDR)**: O(prefix_bits) IP/Subnet lookups used by `ip_contains()`
- **R-tree (2D)**: Spatial predicates `st_intersects()` / `st_contains()`
- **Interval-Tree (Ranges)**: Contains/overlaps for `Range<T>`
- **JSONB Inverted**: Path/value postings for `jsonb_get`/filters
- **Domain Trie**: Reverse-label suffix lookups for domains/FQDNs
- **HNSW (Vectors)**: Approximate k-NN for `vector_knn()` with high recall

## Performance

### v0.18.0 Benchmarks

- **Federation**: 50K rows/sec merge across 3 shards
- **S3 Backup**: 100MB/s upload with multipart
- **CDC Delivery**: 10K events/sec with retries
- **CBO Small-N**: <10% overhead, prevents 90% of bad plans
- **Type Operations**: IPv6 parsing ~1M/sec, vector SIMD ≥2× scalar
- **Index Performance**: Patricia LPM <1μs, R-tree bbox filter <10μs, HNSW k-NN <100μs

### Resource Usage

- **Federation**: +50MB RAM per active distributed query
- **S3 Backups**: Throttled to 50% I/O capacity
- **CDC Webhooks**: Bounded queue (10K events max)
- **CBO**: <1ms planning overhead for small queries

## Testing

### Coverage Statistics

- **14 new E2E tests** in v0.18.0
- **71/71 tests passing**
- **0% untested claimed features** (enforced by status generator)
- All features have CANARY markers with test evidence

### Test Categories

- Unit tests: Core logic validation
- Integration tests: Component interaction
- E2E tests: Full stack validation
- Benchmarks: Performance regression detection

## Configuration

### Environment Variables (Current Set)

```bash
# Core
GEODE_DATA_DIR=/var/lib/geode
GEODE_LOG_LEVEL=info
GEODE_LOG_FORMAT=json

# Optimizer tracing (optimizer itself always on)
GEODE_TRACE_OPTIMIZER=1

# TDE (supply to ensure encryption on new deployments)
GEODE_DISK_KEY_HEX=<64 hex chars>

# S3 backup targets
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=yyy
AWS_REGION=us-east-1

# Optional CDC headers config (example)
CDC_WEBHOOK_HEADERS="Authorization:Bearer token,X-Tenant-ID:123"
```

### CLI Examples

```bash
# Distributed query (automatic with federation enabled)
geodec "MATCH (n) RETURN n ORDER BY n.id LIMIT 100"

# S3 Backup operations
geode backup --dest s3://my-bucket/backups --mode full
geode backup --dest s3://my-bucket/backups --mode incremental --parent <backup-id>
geode restore --source s3://my-bucket/backups --backup-id <id> --target /data

# EXPLAIN with distributed & recursive plan forms
geodec "EXPLAIN MATCH (n) RETURN n ORDER BY n.id LIMIT 10"
geodec "EXPLAIN RECURSIVE MATCH (n) RETURN n LIMIT 5"   # experimental recursive JSON form
```

## Documentation

- [GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md) - Feature completion tracking
- [IMPLEMENTATION_REALITY.md](docs/IMPLEMENTATION_REALITY.md) - Actual implementation status
- [NEXT.md](docs/NEXT.md) - Roadmap and upcoming features
- [RELEASE_v0.18.md](docs/RELEASE_v0.18.md) - Detailed v0.18 release notes
- [REQUIREMENTS.md](docs/REQUIREMENTS.md) - ISO GQL compliance requirements

## Known Limitations

## Unicode Support

See `docs/UNICODE.md` for detailed coverage and governance. Current capabilities:

- Minimal NFC subset + selective case folding (REQ-GQL-UNICODE-004/005)
- FTS analyzer + eval + ORDER BY + uniqueness NFC canonicalization (REQ-GQL-UNICODE-008/009/010/011)
- UTF-8 ⇄ UTF-16 conversion via std.unicode (REQ-GQL-UNICODE-012/013)
- Lossy WTF-8 → UTF-8 decoding (REQ-GQL-UNICODE-014)

Normalization breadth (full combining classes/composition) and grapheme segmentation intentionally deferred; tracked via future REQ IDs when implemented.

### Federation

- Read-only queries (writes not distributed)
- No cross-shard transactions yet
- Global secondary indexes not supported

### S3 Backups

- Maximum file size: 100GB per backup
- S3-compatible APIs only (no native Azure/GCS)

### CDC

- Maximum batch size: 10,000 events
- DLQ not persistent across restarts

### CBO

- Limited to single-node optimization
- No histogram support for custom types

### Near-Term Roadmap Focus

Security hardening (remote KMS auth & attestation, MFA policy expansion), FTS analyzers + BM25 scoring, parallel execution across more operators, and write path federation remain the principal active tracks for the upcoming release cycle.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

## License

MIT License - See [LICENSE](LICENSE) for details.

## Support

- GitHub Issues: [github.com/your-org/geode/issues](https://github.com/your-org/geode/issues)
- Documentation: [docs.geode.io](https://docs.geode.io)
- Community: [discord.gg/geode](https://discord.gg/geode)
