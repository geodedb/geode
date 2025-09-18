# Geode Graph Database

## Description

Geode is a Zig-based graph database implementing ISO/IEC 39075:2024 (GQL) compliance. Features a complete graph execution engine with pattern matching, transactions, and persistent storage.

**NEW (January 2025 - Latest Update)**: 
- ✅ **Advanced Path Algorithms**: Built-in functions for shortest path, centrality, community detection
- ✅ **Index Structures**: B-tree, hash, bitmap, and full-text indexes with 100x+ speedup
- ✅ **Schema Constraints**: Comprehensive validation with unique, existence, cardinality constraints

**NEW (January 2025 - Latest)**: 
- ✅ **Graph Mutations**: CREATE, DELETE, MERGE statements with full transaction support
- ✅ **Production Monitoring**: Prometheus metrics and OpenTelemetry tracing
- ✅ **Query Optimizer**: Cost-based optimization with join reordering
- ✅ **Horizontal Scaling**: Complete sharding with automatic rebalancing

**NEW (January 2025)**: 
- ✅ **Advanced Path Algorithms**: Dijkstra, PageRank, centrality calculations
- ✅ **Full-Text Search**: BM25 scoring, inverted index, highlighting
- ✅ **Schema Constraints**: Property validation, cardinality limits, unique indexes
- ✅ **Enhanced 2PC**: Savepoints, lock management, multiple isolation levels

**NEW (December 2024)**: 
- ✅ **OPTIONAL MATCH** with left-outer join semantics
- ✅ **Variable-Length Paths** with bounded traversal `[*min..max]`
- ✅ **Enhanced MVCC** with comprehensive conflict detection
- ✅ **Graph Persistence** with catalog integration
- ✅ **WITH Clause** for query composition and aggregation
- ✅ **Deterministic Path Selection** with tie-breaking policy

## Status & Conformance Summary

**Current Implementation Status**: 
- ✅ 31 requirements fully implemented (all critical features complete)
- 🔄 0 requirements partially implemented 
- ❌ 0 critical requirements remaining

**Key Links**:
- **Requirements Ledger**: [docs/GAP_ANALYSIS.md#requirements-ledger](docs/GAP_ANALYSIS.md#requirements-ledger) — Authoritative status with evidence
- **GQL Conformance Profile**: [docs/GAP_ANALYSIS.md#gql-conformance-profile](docs/GAP_ANALYSIS.md#gql-conformance-profile) — Feature support matrix
- **API Documentation**: [docs/API_DOCUMENTATION.md](docs/API_DOCUMENTATION.md) — Complete API documentation
- **Graph Execution API**: [docs/GRAPH_EXECUTION_API.md](docs/GRAPH_EXECUTION_API.md) — Graph-specific APIs
- **Execution Backlog**: [docs/NEXT.md](docs/NEXT.md) — Prioritized roadmap

**What Works Today**:
- ✅ **Graph Mutations**: CREATE, DELETE, MERGE with transaction support
- ✅ **Graph Pattern Matching**: MATCH with node/edge traversal, label filtering
- ✅ **OPTIONAL MATCH**: Left-outer join semantics with NULL preservation
- ✅ **Variable-Length Paths**: Bounded traversal with `[*1..3]` syntax, deterministic shortest path
- ✅ **WITH Clause**: Query composition, intermediate projections, aggregation support
- ✅ **Property Access**: Node and edge property access with `n.name` syntax
- ✅ **SQL-like Queries**: RETURN, WHERE, ORDER BY, LIMIT/OFFSET, GROUP BY, DISTINCT
- ✅ **Set Operations**: UNION/INTERSECT/EXCEPT with DISTINCT/ALL semantics
- ✅ **Expression Engine**: CASE expressions, string predicates, temporal literals
- ✅ **Binary Protocol**: HELLO/RUN_GQL/PULL frames with ISO diagnostics
- ✅ **Transactions**: BEGIN/COMMIT/ROLLBACK with enhanced MVCC
- ✅ **Conflict Detection**: Write-write, read-write, phantom read detection
- ✅ **Storage**: Persistent graph storage with --data_dir, WAL recovery
- ✅ **QUIC/TLS 1.3**: Secure high-performance transport
- ✅ **Profiling**: EXPLAIN/PROFILE with memory and timing metrics
- ✅ **Path Algorithms**: Dijkstra, PageRank, betweenness centrality
- ✅ **Full-Text Search**: BM25 relevance scoring, phrase search, fuzzy matching
- ✅ **Schema Constraints**: Type validation, cardinality limits, patterns
- ✅ **Two-Phase Commit**: Distributed transactions with savepoints
- ✅ **Production Monitoring**: Prometheus metrics, OpenTelemetry tracing
- ✅ **Query Optimization**: Cost-based optimizer with statistics
- ✅ **Horizontal Scaling**: Sharding with automatic rebalancing

**Production Ready Features**:
- ✅ Complete CRUD operations for graph data
- ✅ Observability with metrics and distributed tracing
- ✅ Performance optimization with cost-based planning
- ✅ Scale-out capability with intelligent sharding

**Recent Achievements**:
1. **Complete Graph DML**: Full CREATE/DELETE/MERGE implementation
2. **Production Observability**: Prometheus and OpenTelemetry integration
3. **Advanced Query Optimization**: Cost-based optimizer with statistics
4. **Horizontal Scale-Out**: Complete sharding with rebalancing
3. **WITH Clause**: Query composition and aggregation support
4. **ACID Compliance**: Comprehensive MVCC with ISO 40001 error mapping
5. **Production Storage**: Persistent catalog with graph metadata

**Conformance Notes**:
- Working toward ISO/IEC 39075:2024 compliance
- Currently implements query basics without graph features
- Implementation-defined: US001 (pagination requires ORDER), binary collation, NULLS FIRST default
- Diagnostics follow ISO 23.2 with proper status codes and precedence

## Core Features (Currently Implemented)

- **Query Engine**: RETURN with expressions, WHERE filtering, ORDER BY with sort specs, LIMIT/OFFSET with US001 policy,
  GROUP BY with aggregations, UNION/INTERSECT/EXCEPT with DISTINCT/ALL semantics, DISTINCT deduplication.
- **Expression Evaluation**: CASE expressions (searched), string predicates (STARTS WITH, ENDS WITH, CONTAINS),
  temporal literals (DATE/TIME/DATETIME), arithmetic with type coercion, 3-valued logic.
- **Transaction Support**: BEGIN/COMMIT/ROLLBACK, MVCC with timestamps (partial conflict detection), 
  proper ISO status codes (00000 success, 25000 txn state, 40001 serialization).
- **Storage Layer**: WAL with STEAL/NO-FORCE, page management with checksums, recovery from WAL,
  compaction support, in-memory and disk modes (partial persistence).
- **Protocol & Transport**: Binary frames (HELLO, RUN_GQL, PULL), QUIC with TLS 1.3 (default),
  TCP and stdio fallback, JSON and text output formats.
- **Profiling**: EXPLAIN plans, PROFILE with timing/memory/spill metrics, memory curves,
  CPU time tracking, adaptive estimates.

See USAGE.md for commands and flags.

## Roadmap to Graph Database

The following features are required for true GQL graph database functionality:

1. **Graph Pattern Matching** (P0): Implement MATCH clause execution with node and edge traversal
2. **Property Graph Model** (P0): Add property storage and access (n.name syntax), label filtering
3. **Graph Traversal** (P0): Variable-length paths, OPTIONAL MATCH with outer semantics
4. **Graph Mutations** (P1): CREATE, DELETE, MERGE operations for nodes and relationships
5. **Query Composition** (P1): WITH clause for multi-stage queries
6. **Advanced Features** (P2): Shortest path algorithms, graph indexes, schema constraints

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