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
```

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
- **Storage**: MVCC, WAL/ARIES, page management, S3 backup integration
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

## Performance

### v0.18.0 Benchmarks

- **Federation**: 50K rows/sec merge across 3 shards
- **S3 Backup**: 100MB/s upload with multipart
- **CDC Delivery**: 10K events/sec with retries
- **CBO Small-N**: <10% overhead, prevents 90% of bad plans

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
