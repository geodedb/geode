# Geode Graph Database

## Description

Geode is a partially-implemented Zig-based database with basic GQL query support. While documentation claims extensive features, the actual implementation is approximately 25% complete with most advanced features being stubs or placeholders.

## Actually Working Features

### Basic Query Operations
- ✅ **Simple Queries**: RETURN, ORDER BY, LIMIT, OFFSET
- ✅ **Set Operations**: UNION, INTERSECT, EXCEPT with ALL/DISTINCT
- ✅ **Aggregations**: GROUP BY with COUNT, SUM, AVG, MIN, MAX
- ✅ **Transactions**: MVCC implementation with snapshot isolation
- ⚠️ **Graph Operations**: Basic MATCH parsing (limited execution)

### Not Actually Implemented (Despite Documentation)
- ❌ **Distributed Features**: No Raft, no sharding, no clustering
- ❌ **GPU Acceleration**: Complete stub with empty implementations  
- ❌ **Machine Learning**: Only basic PageRank, no real ML algorithms
- ❌ **CDC/Streaming**: No change capture or sink integration
- ❌ **Materialized Views**: Just type definitions with TODOs
- ❌ **Query Optimization**: No adaptive or cost-based optimization
- ❌ **Full-Text Search**: Not implemented
- ❌ **QUIC Transport**: Returns NotImplemented, falls back to TCP

## Real Implementation Status

### Actual State
- **~25% Implemented**: Basic queries and transactions work
- **171+ NotImplemented errors**: Throughout the codebase
- **Extensive TODOs**: Most advanced features are stubs
- **Not Production Ready**: Missing critical features

### Documentation
- [Requirements Ledger](docs/GAP_ANALYSIS.md#requirements-ledger) — Implementation status with evidence
- [GQL Conformance Profile](docs/GAP_ANALYSIS.md#gql-conformance-profile) — Feature support matrix
- [API Documentation](docs/API_DOCUMENTATION.md) — Complete API reference
- [Graph Execution API](docs/GRAPH_EXECUTION_API.md) — Graph-specific operations
- [Roadmap](docs/NEXT.md) — Future features and priorities

## Core Features (Currently Implemented)

### Query Engine
- **Graph Operations**: MATCH/OPTIONAL MATCH with pattern matching, CREATE/DELETE/MERGE mutations
- **Query Features**: RETURN with expressions, WHERE filtering, ORDER BY with sort specs, LIMIT/OFFSET with US001 policy
- **Aggregations**: GROUP BY with COUNT, SUM, AVG, MIN, MAX, STDEV, VARIANCE
- **Set Operations**: UNION/INTERSECT/EXCEPT with DISTINCT/ALL semantics
- **Path Operations**: Variable-length paths `[*1..5]`, shortest path algorithms

### Expression Evaluation
- **CASE Expressions**: Searched CASE with 3-valued logic
- **String Operations**: STARTS WITH, ENDS WITH, CONTAINS predicates
- **Temporal Support**: DATE/TIME/DATETIME literals per ISO 8601
- **Type System**: Automatic numeric promotion with Int→Decimal→Float hierarchy

### Transaction Support
- **ACID Compliance**: BEGIN/COMMIT/ROLLBACK with full isolation
- **MVCC**: Multi-version concurrency control with conflict detection
- **Conflict Types**: Write-write, read-write, write-read, phantom read detection
- **ISO Status Codes**: 00000 (success), 25000 (txn state), 40001 (serialization failure)

### Storage Layer
- **WAL**: Write-ahead logging with STEAL/NO-FORCE policy
- **Page Management**: Checksummed pages with automatic recovery
- **Graph Persistence**: Catalog integration with metadata storage
- **Compaction**: Automatic WAL compaction with configurable intervals

### Protocol & Transport  
- **QUIC/TLS 1.3**: Default secure high-performance transport
- **Binary Protocol**: HELLO, RUN_GQL, PULL frames with ISO diagnostics
- **Fallback Modes**: TCP and stdio for compatibility
- **Output Formats**: JSON (default) and text/plain

### Client Libraries
- **Zig Client**: Native client with full protocol support
- **Go Client**: Complete driver with connection pooling and query builder
- **Cross-Platform**: Pre-built binaries for Windows, Linux (x86_64/ARM64), macOS (x86_64/ARM64)
- **Cross-Compilation**: Full support for all major platforms (see [docs/CROSS_COMPILATION.md](docs/CROSS_COMPILATION.md))

### Production Features
- **Monitoring**: Prometheus metrics, OpenTelemetry tracing
- **Query Optimization**: Cost-based optimizer with statistics
- **Horizontal Scaling**: Sharding with automatic rebalancing
- **Security**: Row-level security (RLS), user authentication, TLS encryption
- **Profiling**: EXPLAIN/PROFILE with timing, memory, and spill metrics

See [USAGE.md](USAGE.md) for commands and flags.

## Building from Source

### Prerequisites
- Zig 0.15.1 or later
- Git (for submodules)
- Optional: Go 1.19+ (for Go client)
- Optional: QEMU (for testing cross-compiled binaries)
- Optional: Wine (for testing Windows binaries on Linux)

### Quick Start
```bash
# Clone with submodules (includes QUIC library)
git clone --recursive https://github.com/yourusername/geode.git
cd geode

# Or if already cloned, initialize submodules
git submodule update --init --recursive

# Build all components (server, clients, tools)
make build

# Run tests
make test

# Build client libraries for all platforms
make cross-clients

# Test cross-compiled clients with QEMU/Wine
make qemu-test-clients
```

### Available Make Targets
```bash
make help              # Show all available targets
make release           # Build optimized release version
make cross-compile     # Cross-compile for all platforms
make docker-build      # Build Docker images
make go-example        # Run Go client example
make tools             # Build auxiliary tools (cert_gen, wal_compact, etc.)
```

### QUIC Library
The QUIC transport layer is included as a git submodule at `vendor/quic/`. For more details, see [docs/QUIC_SUBMODULE_SETUP.md](docs/QUIC_SUBMODULE_SETUP.md).

## Quick Start Guide

### Starting the Server
```bash
# QUIC mode (default, recommended)
./zig-out/bin/geoded --listen-quic 0.0.0.0:7567

# TCP mode (legacy)
./zig-out/bin/geoded --listen-tcp 127.0.0.1:7567

# With persistent storage
./zig-out/bin/geoded --data_dir ./data --listen-quic 0.0.0.0:7567
```

### Using the CLI Client
```bash
# Simple query
./zig-out/bin/geodec "RETURN 1 AS x ORDER BY x LIMIT 1"

# With QUIC connection
./zig-out/bin/geodec "MATCH (n:Person) RETURN n.name" --server 127.0.0.1:7567

# Profile a query
./zig-out/bin/geodec "PROFILE MATCH (n) RETURN COUNT(n)" --format json
```

### Docker Deployment

Pre-built multi-platform Docker images are available from GitHub Container Registry:

```bash
# Pull the latest image (supports linux/amd64 and linux/arm64)
docker pull ghcr.io/[owner]/geode:latest

# Run the server with QUIC
docker run -d -p 7567:7567/udp ghcr.io/[owner]/geode:latest

# Run a query
docker run --rm ghcr.io/[owner]/geode:latest geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --no-quic

# Using Docker Compose
docker compose up -d

# Build and run locally
make docker-build
make docker-up-singleton
```

See [Docker Usage Guide](docs/DOCKER_USAGE.md) for detailed deployment instructions.

## Documentation

### Core Documentation
- **[API Documentation](docs/API_DOCUMENTATION.md)**: Complete API reference
- **[Graph Execution API](docs/GRAPH_EXECUTION_API.md)**: Graph-specific operations
- **[Binary Protocol](docs/BINARY_PROTOCOL.md)**: Wire protocol specification
- **[Cross-Compilation Guide](docs/CROSS_COMPILATION.md)**: Building for multiple platforms
- **[Docker Usage Guide](docs/DOCKER_USAGE.md)**: Complete Docker deployment guide
- **[Docker Deployment](docs/DOCKER_DEPLOYMENT.md)**: Docker Compose examples

### Implementation Status
- **[Gap Analysis](docs/GAP_ANALYSIS.md)**: Requirements ledger and conformance profile
- **[Current State](docs/CURRENT_STATE.md)**: Detailed implementation status
- **[Next Steps](docs/NEXT.md)**: Prioritized roadmap and future features
- **[Conformance Matrix](docs/CONFORMANCE_MATRIX.md)**: ISO GQL compliance tracking

### Advanced Topics
- **[Numeric Promotion](docs/NUMERIC_PROMOTION.md)**: Type coercion rules
- **[Query Engine](docs/query_engine.md)**: Internal query execution details
- **[Profiling Guide](docs/PROFILING.md)**: Performance analysis and optimization
- **[Research Papers](docs/research.md)**: Academic foundation and algorithms

## Profiling & Metrics

Use the `PROFILE` prefix before a GQL query (via server line protocol or `geodec`) to emit a PROFILE frame. The first frame is SCHEMA; the second contains JSON with:

`op`, `input_rows`, `rows`, `time_ns`, `cumulative_time_ns`
`bytes_out`, `bytes_alloc`
`estimate_bytes`, `estimate_vs_actual`
`percent_peak`, `percent_net`

### Env Vars (runtime policies, spills, profiling)

| Variable                      | Effect                                                                 |
| ----------------------------- | ---------------------------------------------------------------------- |
| `GEODE_NULLS_LAST`            | Switch ORDER BY null ordering from default nulls-first to nulls-last.  |
| `GEODE_SPILL_THRESHOLD_BYTES` | When peak_bytes >= threshold, mark spill counters (sort/distinct).     |
| `GEODE_FORCE_SORT_SPILL`      | Force `sort_spills` = 1 (spill_reason=forced).                         |
| `GEODE_FORCE_DISTINCT_SPILL`  | Force `distinct_spills` = 1 (spill_reason=forced).                     |
| `GEODE_FORCE_UNION_SPILL`     | Force `union_spills` = 1 (spill_reason=forced).                        |
| `GEODE_PROFILE_MEMCURVE`      | Enable `mem_curve` emission (alternative to CLI `--profile-memcurve`). |
| `GEODE_WAL_COMPACT_INTERVAL`  | Trigger WAL compaction every N commits (default: 5).                   |

### WAL Compaction Tool

`wal_compact` reclaims obsolete WAL segment files.

Usage:

```bash
zig build tools      # build auxiliary tools
./zig-out/bin/wal_compact --base /path/to/data/geode_wal --auto
```

Options:

- `--base <path>`: Prefix path used when WAL was opened (without `.wal.N`).
- `--auto`: Scan segments to find last checkpoint LSN and compact using that durable boundary.
- `--durable-lsn N`: Explicit durable LSN boundary (numeric) instead of auto scan.

Example flow:

1. Database emits periodic checkpoints (via internal `writeCheckpoint`).
2. Run `wal_compact --auto` after a checkpoint + data flush to reclaim older segments.

Safety: Active segment (currently open for append) is not deleted even if below durable boundary. Future versions may add a rotation+compact combined command.

### CLI Profiling Flags

| Flag                 | Effect                                     |
| -------------------- | ------------------------------------------ |
| `--no-estimates`     | Suppress planner estimate & error fields.  |
| `--profile-compact`  | Omit zero-value optional metrics.          |
| `--profile-memcurve` | Emit `mem_curve` points (same as env var). |

Percentage metrics (`estimate_vs_actual`, `error_abs_pct`) are capped at 999 for stability.

### Example

```bash
geodec "PROFILE RETURN a AS x DISTINCT ORDER BY x LIMIT 3" --json-param a "[1,2,2,3,4]"
```

Yields PROFILE JSON (abridged):

```json
{"profile_version":2,"ops":[{"op":"Project","input_rows":5,"rows":5,"time_ns":...,"cumulative_time_ns":...,"bytes_out":...,"bytes_alloc":...,"estimate_bytes":...,"estimate_vs_actual":...,"percent_peak":...,"percent_net":...}],"peak_contributors":[...],"total_time_ns":...,"spills":{"sort_spills":0,"distinct_spills":0,"union_spills":0},"memory":{"net_bytes":...,"peak_bytes":...,"total_alloc_bytes":...}}
```

Metrics are stable for automation; additions bump `profile_version`.

## Stability & Fuzz Coverage

- PROFILE / EXPLAIN schema frozen at `profile_version=2`. Any structural key additions or removals REQUIRE incrementing this version and updating snapshot signatures.
- Decimal ordering correctness validated by a 10k pair randomized fuzz harness (`e2e_protocol_decimal_fuzz.zig`) covering mixed int/decimal scales and ensuring transitive comparator semantics.
- Comparator invariants: antisymmetry, transitivity, and total ordering over (int, decimal) domain with scale normalization. Violations would panic in fuzz; current corpus passes.
- Version bump policy: (1) modify schema, (2) update freeze tests (`e2e_protocol_profile_explain_freeze.zig`), (3) bump `profile_version`, (4) regenerate README example if changed.
- Future extensions (counting allocator, HashAgg) will NOT alter existing keys; additions append optional fields gated by version bump if structural.

### Snapshot & Test Workflow

Snapshot tests assert structural stability of PROFILE output while tolerating numeric variance.

Implemented snapshot layers:

- Baseline structural signature (`e2e_protocol_profile_snapshot.zig`)
- mem_curve presence/prefix (`e2e_protocol_profile_memcurve_snapshot.zig`)
- Estimates suppression (`e2e_protocol_profile_no_estimates_snapshot.zig`)
- Spill reasons (forced & threshold) tests
- Allocation delta & op ordering invariants (`e2e_protocol_profile_alloc_deltas.zig`)

Signature Generation / Update:

1. Run `zig build test` after intentional PROFILE schema change.
2. Failing snapshot test prints `SNAPSHOT_SIGNATURE=...`.
3. Replace the `EXPECTED_SIGNATURE` constant in the snapshot test with the printed value.
4. Commit new snapshot along with schema change; bump `profile_version` if shape changed.

Normalization Rules:

- All digit sequences (including decimals) collapsed to '0'.
- Whitespace removed.
- Order of keys preserved; new keys require version bump.

Allocation Deltas:

- Per-stage `bytes_alloc` derived from net allocator snapshots at each stage boundary (delta from previous boundary).
- `percent_peak` / `percent_net` computed from these deltas, not cumulative sums.

Spill Reason Semantics:

- `forced` when an explicit `GEODE_FORCE_*` env var triggers spill counters.
- `threshold` when `GEODE_SPILL_THRESHOLD_BYTES` <= peak_bytes and no explicit force provided.

Updating Tests for New Ops:

- Add new op to ordering validation allowlist in `e2e_protocol_profile_alloc_deltas.zig` (maintain monotonic order).
- Update snapshot signature after confirming stable normalized output.

## Numeric Promotion Matrix (REQ-GQL-013)

Geode implements ISO/IEC 39075:2024 numeric type coercion with the following promotion rules:

### Type Precedence (lowest to highest)
1. **Int** (64-bit signed integer)
2. **Decimal** (128-bit coefficient with scale)
3. **Float** (64-bit IEEE 754)

### Promotion Rules
| From    | To      | Valid? | Lossy? | Notes                                    |
|---------|---------|--------|--------|------------------------------------------|
| Int     | Decimal | ✓      | ✗      | Always safe, scales coefficient by 10^n |
| Int     | Float   | ✓      | ✗      | Safe for values within float precision  |
| Decimal | Int     | ✓      | ✓      | Truncates fractional part               |
| Decimal | Float   | ✓      | ✓      | May lose precision for large decimals   |
| Float   | Int     | ✓      | ✓      | Truncates fractional part               |
| Float   | Decimal | ✓      | ✓      | May lose precision at extremes          |

### Operation Result Types
- **Addition/Subtraction**: Result type is the higher precedence operand type
- **Multiplication**: Result type is the higher precedence operand type  
- **Division**: Result type is at least Decimal (Int÷Int→Decimal for precision)
- **Comparison**: All numeric types are comparable through promotion

### Division by Zero Handling
Division by zero operations emit `TypeMismatch.DivZero` diagnostic (ISO 16.x) instead of runtime panic.

```gql
RETURN 1/0  -- Emits TypeMismatch.DivZero with status_class 22000
```

### Implementation-Defined Policies
- **I:NumericPromotion**: Int→Decimal widening preserves exact value
- **I:DecimalScale**: Default scale is 2 for division results
- **I:FloatPrecision**: IEEE 754 double precision (53-bit mantissa)

## Diagnostics (policy and ISO anchors)

| Code                | Meaning                                                    | ISO anchor  | Example                        |
| ------------------- | ---------------------------------------------------------- | ----------- | ------------------------------ |
| US001               | LIMIT/OFFSET on unordered table (requires stable ORDER BY) | 16.18–16.19 | RETURN 1 LIMIT 10 OFFSET 5     |
| IllegalOrderKey     | ORDER BY key must be identifier (policy: ident-only)       | 14.10       | RETURN a ORDER BY f(a)         |
| GroupByIllegal      | Invalid GROUP BY legality (e.g., non-aggregated columns)   | 14.10       | RETURN a, SUM(b) GROUP BY a, b |
| TypeMismatch        | Illegal cross-type comparison/ordering                     | 16.x        | RETURN 1 < "2"                 |
| TypeMismatch.DivZero| Division by zero operation                                 | 16.x        | RETURN 1/0                     |
| TxnState            | Transaction state error (invalid lifecycle transition)     | 8           | COMMIT without BEGIN           |
| StoragePageChecksum | Page checksum mismatch during storage operations          | 4           | Corrupted page detected        |

The CLI and server surface diagnostics with status_class/subclass per ISO 23.2. Tests assert codes/anchors via stderr.

## Documentation Sync Utility

Maintain alignment between implemented requirement codes (REQ-GQL-###) and the ledger in `docs/GAP_ANALYSIS.md` using the doc sync script:

```bash
zig run src/tools/doc_sync.zig
```

The script prints any MISSING (referenced in code but absent from GAP_ANALYSIS) or EXTRA (present in GAP_ANALYSIS but not found in source) requirement IDs. Resolve discrepancies by editing `docs/GAP_ANALYSIS.md` until the script outputs no differences. Integrate this check in CI to prevent drift.

## Contributing

Contributions are welcome! Please ensure:
- All tests pass (`make test`)
- Code is formatted (`make fmt`)
- Cross-compilation works (`make cross-compile`)
- Documentation is updated for new features

## License

MIT License - see LICENSE file for details.

## Support

- **Issues**: GitHub Issues for bug reports and feature requests
- **Documentation**: See the [docs/](docs/) directory for detailed guides
- **Examples**: Check [examples/](examples/) for query examples and use cases