# Execution Coverage and Graph Algorithms Roadmap

Planner/Executor coverage priorities (near-term)

- Logical operators: NodeScan, Expand (out/in/both with label/type filters), Filter, Project, Group/Aggregate, SetOps, Distinct, Order, Limit, Offset
- Physical operators: NodeIndexScan (when index present), CSR adjacency scan, HashJoin (OPTIONAL as LOJ), Sort/Top-k, HashAggregate
- Pipeline rules:
  - OPTIONAL implemented as left-outer join over binding tables
  - ORDER BY with aliases and ordinals resolved pre-physical plan; ordered/order_keys emitted
  - No OFFSET pushdown without stable ORDER (US001)
  - SetOps: DISTINCT dedupe with deterministic order only when explicitly ordered later; ALL preserves stable-left
  - GROUP BY+HAVING evaluated before Project; ORDER/LIMIT applied after projection

Graph algorithms (initial set)

- BFS / unweighted shortest paths (bounded quantifiers); returns path bindings honoring UA005/UA006 tie-break
- Dijkstra (weighted shortest path) with property-based weights
- k-hop neighborhood expansion with label/type predicates
- Connected components (analytics baseline) — batch job mode; stable output policy documented

Test and conformance targets

- E2E tests for ORDER semantics, set ops composition, aggregation pipelines, OPTIONAL semantics, and pagination rules
- Path tie-break determinism tests (UA005/UA006)
- Performance smoke: ≥50k expands/sec (debug off) on 1M-edge graph (single node)

Storage interplay

- In-memory and disk-backed storage share page/record invariants
- CSR adjacency used by Expand; iterator interface stable across backends
- WAL/ARIES (disk) defines durability semantics; in-memory bypasses WAL but preserves operator contracts

Profiling & Metrics (current implementation)

- Per-operator metrics emitted in PROFILE JSON under result.json.ops[]:

  - profile_version: schema version (integer) for forward compatibility
  - op: Project | Distinct | Sort | Offset | Limit | AggregateBuild | AggregateEmit
  - input_rows / rows: pre/post tuple counts for the stage
  - time_ns: wall clock nanoseconds spent inside the stage (coarse; single-threaded)
  - cumulative_time_ns: running sum of time_ns across emitted ops (monotonic)
  - bytes_out: approximate logical bytes of JSON row fragments (future: physical size once structured rows land)
  - bytes_alloc: stage allocation delta (net allocator growth attributable to the stage); falls back to bytes_out if tracking unavailable
  - estimate_bytes: planner-style heuristic for expected memory usage (per stage)
  - estimate_vs_actual: (bytes_alloc \* 100) / estimate_bytes (0 if estimate_bytes==0 or bytes_alloc==0)
  - percent_peak: integer percentage (0-100) of process peak_bytes consumed by this stage's allocation delta
  - percent_net: percentage of current net_bytes represented by this stage's allocation delta at emission time
  - peak_contributors: top 3 ops by bytes_alloc with their allocation values
  - spill*reason: "forced" when triggered by GEODE_FORCE*\* env vars; "threshold" when peak_bytes >= GEODE_SPILL_THRESHOLD_BYTES
  - setop.distinct_fill_pct (UNION DISTINCT only): percentage of unique rows (hash_dedup_size) relative to total input rows (left+right); coarse selectivity signal

- Aggregation:

  - AggregateBuild: rows_in = raw logical input rows (currently derived from param row count); rows_out = number of groups
  - AggregateEmit: rows_in = rows_out of build; rows_out identical (projection emission)

- Planned enhancements:

  - Structured row arena to measure precise bytes_out and allocation churn
  - Freed bytes per stage (allocator hooks) & net_after_op field
  - Percent-of-peak cumulative validation & sum-of-deltas vs peak invariant tests (partial: initial invariants + top contributors in place)
  - Allocator wrapper capturing allocated/freed bytes per phase (delta implemented; freed pending)
  - Estimate calibration & error bounds (planner feedback loop)
  - Operator ID + dependency graph for multi-branch pipelines (joins, optional matches)
  - Distinct spill / Sort spill counters when external memory introduced

  Canonical DISTINCT / UNION semantics

  - Numeric canonicalization trims decimal scale (1.0, 1.00 -> 1) so numerically equal decimals and ints deduplicate.
  - Type-sensitive: numeric 1 and string "1" remain distinct (string values prefixed with type tag in canonical key).
  - Future: add temporal canonical forms (date/time equivalence) with flagger warnings for implicit normalization.
