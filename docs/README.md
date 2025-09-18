# Geode Design Documentation

## Status & Conformance Summary

- Requirements Ledger and evidence: [`docs/GAP_ANALYSIS.md#requirements-ledger`](GAP_ANALYSIS.md#requirements-ledger)
- GQL Conformance Profile (current): [`docs/GAP_ANALYSIS.md#gql-conformance-profile`](GAP_ANALYSIS.md#gql-conformance-profile)
- Execution-ready backlog: [`docs/NEXT.md`](NEXT.md)

## Troubleshooting (diagnostics quick reference)

- US001 — Unordered pagination: LIMIT/OFFSET without explicit ORDER BY on an unordered input is illegal (ISO 16.18–16.19).
- IllegalOrderKey — ORDER BY key violates ident‑only policy (ISO 14.10).
- GroupByIllegal — RETURN/HAVING expressions not aligned with GROUP BY keys or aggregates (ISO 14.10).
- TypeMismatch — Incomparable types for the requested operation (e.g., ordering across heterogeneous types) (ISO 16.x; 23.2).
  - Can arise at runtime during expression evaluation (e.g., attempting arithmetic across incompatible types) as well as during planning. Runtime occurrences surface as ERROR frames with primary code=TypeMismatch and no additional status codes.

## Flagger Findings (policy / behavior flags)

Frames may include a `flagger_findings` array describing enforced policies or behavioral caveats.

Current flags:

- I:IllegalOrderKeyPolicy=ident-only — ORDER BY restricted to simple identifiers (preventing arbitrary expressions/functions).
- U:NullsFirstPolicy — Server currently applies a NULLS FIRST ordering policy (deterministic, not client configurable yet).
- U:OrderTiebreak=LexJSON — Final ordering tie-break uses lexical comparison of full row JSON to ensure deterministic output when keys compare equal.
- U:DistinctOutputUnordered — DISTINCT applied to an otherwise unordered input (surface to client that row order is not guaranteed beyond selection semantics).
- U:US001/enforced — Unordered pagination legality (US001) was enforced for this statement (appears only on related ERROR frames).
- U:UnionPhaseTimings — Granular UNION PROFILE includes phase timing ops (UnionLeft, UnionTails, UnionDedup, SetOpUnion).

Planned additions (not yet emitted):

- U:ComparatorFuzzed — Indicates comparator implementation passed extended fuzz harness (post-integration quality marker).

Semantics:

- Prefix I: indicates an invariant policy enforced by the server.
- Prefix U: indicates an usability / behavior flag providing clarity rather than a strict invariant breach.

Clients should treat unknown flags as informational (forward compatible). Flags are intentionally terse for low overhead in wire encoding.

## Profiling Extensions (PROFILE ...)

The `PROFILE` prefix produces a JSON PROFILE line (after the SCHEMA line) describing per-operator execution metrics. Key fields (profile_version=1):

- ops[]: Ordered array of operator objects with: op, op_index, input_rows, rows, time_ns, cumulative_time_ns, bytes_out, bytes_alloc, freed_bytes (if any), net_after_op, percent_peak, percent_net, estimate_bytes (if enabled), error_bytes, error_abs_pct.
- peak_contributors[]: Top three operators by bytes_alloc (descending) with bytes_alloc snapshot.
- spills: Object with sort_spills, distinct_spills, union_spills counts. When any are non-zero additional fields may appear:
  - spill_reason: "forced" (env-forced) or "threshold" (peak memory exceeded GEODE_SPILL_THRESHOLD_BYTES).
  - peak_bytes_at_spill: Peak allocator bytes at time spill condition first observed.
  - first_spill_op_index: op_index of first spilling operator (derived from actual op indices, not heuristic).
- memory: net_bytes (live after last op), peak_bytes, total_alloc_bytes (cumulative alloc traffic) from profiling allocator.
- planner_estimates: Summary of estimation accuracy and adjusted_estimate_factor for future adaptive tuning.
- mem_curve (optional): Present when `--profile-memcurve` flag supplied. Array of `{op_index, net_after_op}` capturing allocator net bytes immediately after each operator emission. Indices strictly increase.
- Adaptive estimates groundwork: set `GEODE_ADAPT_ESTIMATES=1` to surface flag `U:AdaptiveEstimatesPlanned` (no behavioral change yet).

### Enabling mem_curve

Pass `--profile-memcurve` to `geoded` with a PROFILE query, e.g.:

```
./zig-out/bin/geoded --profile-memcurve "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1"
```

The PROFILE output will then include a `"mem_curve":[{"op_index":0,"net_after_op":...}, ...]` section. This is useful for visualizing memory evolution across operators and attributing the precise point of peak memory or first spill. The curve is unsampled in v0.15.0 (one entry per emitted operator); future versions may down-sample for very large plans.

### Invariants (validated by tests)

- op_index values in mem_curve are strictly increasing.
- mem_curve length equals the count of emitted operator objects (1:1 mapping for v0.15.0).
- first_spill_op_index (when present) corresponds to an op_index listed in mem_curve.
- percent_net/percent_peak values never exceed 100.

### Freed Bytes Attribution

`freed_bytes` is currently demonstrated via a synthetic scratch slab freed just before Sort (if any) to illustrate attribution mechanics. Real freed tracking will replace this in a later iteration using allocator delta snapshots at operator boundaries.

### Stability Notes

- Added fields (mem_curve, peak_bytes_at_spill, first_spill_op_index) are optional; clients should feature-detect their presence.
- profile_version will increment if field semantics change or ordering invariants are relaxed (e.g., sampling). A strict schema guard test enforces immutability of existing field names in v0.15.0.
