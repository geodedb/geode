# Geode Graph Database

## Description

Geode is a Zig-based graph database project exploring an ISO/IEC 39075:2024 (GQL) front end with
structured temporals, ORDER BY policy checks, and developer-friendly printers and CLI tooling.

## Status & Conformance Summary

- Requirements Ledger and evidence: see docs/GAP_ANALYSIS.md
- GQL Conformance Profile (initial): see docs/GAP_ANALYSIS.md (bottom)
- Execution-ready backlog: see docs/NEXT.md

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

- `profile_version`: schema version integer.
- `ops[]`: per-stage objects with:
  - `op`, `input_rows`, `rows`, `time_ns`, `cumulative_time_ns`
  - `bytes_out`, `bytes_alloc`
  - `estimate_bytes`, `estimate_vs_actual`
  - `percent_peak`, `percent_net`
- `peak_contributors`: top 3 ops by `bytes_alloc`.
- `total_time_ns`: wall-clock pipeline time.
- `spills`: `{sort_spills, distinct_spills, union_spills}` plus optional `spill_reason` (`forced|threshold`).
- `memory`: `{net_bytes, peak_bytes, total_alloc_bytes}`.

### Env Vars (runtime policies, spills, profiling)

| Variable                      | Effect                                                                 |
| ----------------------------- | ---------------------------------------------------------------------- |
| `GEODE_NULLS_LAST`            | Switch ORDER BY null ordering from default nulls-first to nulls-last.  |
| `GEODE_SPILL_THRESHOLD_BYTES` | When peak_bytes >= threshold, mark spill counters (sort/distinct).     |
| `GEODE_FORCE_SORT_SPILL`      | Force `sort_spills` = 1 (spill_reason=forced).                         |
| `GEODE_FORCE_DISTINCT_SPILL`  | Force `distinct_spills` = 1 (spill_reason=forced).                     |
| `GEODE_FORCE_UNION_SPILL`     | Force `union_spills` = 1 (spill_reason=forced).                        |
| `GEODE_PROFILE_MEMCURVE`      | Enable `mem_curve` emission (alternative to CLI `--profile-memcurve`). |

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
{"profile_version":1,"ops":[{"op":"Project","input_rows":5,"rows":5,"time_ns":...,"cumulative_time_ns":...,"bytes_out":...,"bytes_alloc":...,"estimate_bytes":...,"estimate_vs_actual":...,"percent_peak":...,"percent_net":...}],"peak_contributors":[...],"total_time_ns":...,"spills":{"sort_spills":0,"distinct_spills":0,"union_spills":0},"memory":{"net_bytes":...,"peak_bytes":...,"total_alloc_bytes":...}}
```

Metrics are stable for automation; additions bump `profile_version`.

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
