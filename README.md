# Geode Graph Database

## Description

Geode is a Zig-based graph database project exploring an ISO/IEC 39075:2024 (GQL) front end with
structured temporals, ORDER BY policy checks, and developer-friendly printers and CLI tooling.

# Geode Graph Database

## Description

Geode is a Zig-based graph database project exploring an ISO/IEC 39075:2024 (GQL) front end with
structured temporals, ORDER BY policy checks, and developer-friendly printers and CLI tooling.

## Status & Conformance Summary

**Current Implementation Status**: 32 requirements implemented, 8 partial, 6 missing (see detailed breakdown below)

**Key Links**:
- **Requirements Ledger**: [docs/GAP_ANALYSIS.md#1-requirements-ledger](docs/GAP_ANALYSIS.md#1-requirements-ledger) — Authoritative status of all REQ-GQL-### requirements with evidence
- **GQL Conformance Profile**: [docs/GAP_ANALYSIS.md#2-gql-conformance-profile-initial](docs/GAP_ANALYSIS.md#2-gql-conformance-profile-initial) — ISO/IEC 39075:2024 feature support matrix
- **Execution-ready backlog**: [docs/NEXT.md](docs/NEXT.md) — Prioritized tasks with acceptance criteria
- **GQL→Engine Crosswalk**: [docs/query_engine.md#10-gqlengine-crosswalk-milestone-v015-core](docs/query_engine.md#10-gqlengine-crosswalk-milestone-v015-core) — Mapping from GQL constructs to implementation

**Implementation Highlights**:
- ✅ **Core GQL Language**: MATCH/OPTIONAL patterns, ORDER BY with US001 policy, LIMIT/OFFSET, GROUP BY legality
- ✅ **Set Operations**: UNION/INTERSECT/EXCEPT with DISTINCT/ALL semantics and deterministic ordering
- ✅ **Expression Engine**: CASE expressions, string predicates, temporal literals, mixed-type arithmetic
- ✅ **Binary Protocol**: SCHEMA/BINDINGS frames with ordered metadata, status codes, diagnostics precedence
- ✅ **Profiling & Metrics**: PROFILE/EXPLAIN with stable JSON schema (profile_version=2)
- 🔄 **Storage Layer**: Slotted pages and WAL/ARIES (partial - missing catalog and adjacency structures)
- 🔄 **Transactions**: MVCC timestamps and basic lifecycle (partial - missing conflict detection)
- ❌ **Distributed**: Raft/2PC scaffold (missing - single-node only)

**High-Risk Areas**:
1. **Durability** (REQ-GQL-026): WAL/ARIES needs fuzz scaling and automated compaction
2. **Transactions** (REQ-GQL-027): MVCC lacks full conflict detection and lock management  
3. **Storage** (REQ-GQL-025): Missing persistent catalog and CSR adjacency structures
4. **Distribution** (REQ-GQL-028/042): No distributed scaffold limits scalability
5. **Indexing** (REQ-GQL-039): Only stub statistics, no real selectivity estimation

**Conformance Notes**:
- Implements ISO/IEC 39075:2024 minimum conformance plus selected optional features
- Implementation-defined policies: US001 (unordered pagination rejection), binary collation, int→decimal promotion
- Implementation-dependent behaviors: UA005/UA006 path tie-breaking (planned), null ordering policy
- All diagnostics follow ISO 23.2 precedence rules with proper status_class/subclass mapping

Highlights

- Parser/AST/printers for MATCH/OPTIONAL, ORDER BY, LIMIT/OFFSET, GROUP BY (parse-only),
  UNION/INTERSECT/EXCEPT (parse), pattern comprehensions, string predicates, CASE, and
  structured temporal literals (DATE/TIME/DATETIME/LOCAL DATETIME) with normalization.
- Runtime set-ops semantics (UNION/INTERSECT/EXCEPT) over binding tables with deterministic ordering:
  DISTINCT variants return sorted results; ALL variants preserve stable-left order.
- Planner policies: disallow OFFSET pushdown without explicit ORDER (US001), temporal-aware
  comparator for ORDER BY with session-local attachment.
- CLI: normalization/clamping for temporals; AST JSON with verbose temporals.

See USAGE.md for commands and flags.

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

## Diagnostics (policy and ISO anchors)

| Code            | Meaning                                                    | ISO anchor  | Example                        |
| --------------- | ---------------------------------------------------------- | ----------- | ------------------------------ |
| US001           | LIMIT/OFFSET on unordered table (requires stable ORDER BY) | 16.18–16.19 | RETURN 1 LIMIT 10 OFFSET 5     |
| IllegalOrderKey | ORDER BY key must be identifier (policy: ident-only)       | 14.10       | RETURN a ORDER BY f(a)         |
| GroupByIllegal  | Invalid GROUP BY legality (e.g., non-aggregated columns)   | 14.10       | RETURN a, SUM(b) GROUP BY a, b |
| TypeMismatch    | Illegal cross-type comparison/ordering                     | 16.x        | RETURN 1 < "2"                 |

The CLI and server surface diagnostics with status_class/subclass. Tests assert codes/anchors via stderr.

## Documentation Sync Utility

Maintain alignment between implemented requirement codes (REQ-GQL-###) and the ledger in `docs/GAP_ANALYSIS.md` using the doc sync script:

```bash
zig run scripts/doc_sync.zig
```

The script prints any MISSING (referenced in code but absent from GAP_ANALYSIS) or EXTRA (present in GAP_ANALYSIS but not found in source) requirement IDs. Resolve discrepancies by editing `docs/GAP_ANALYSIS.md` until the script outputs no differences. Integrate this check in CI to prevent drift.
