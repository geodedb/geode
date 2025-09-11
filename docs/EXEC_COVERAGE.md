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

  - op: Project | Distinct | Sort | Offset | Limit | AggregateBuild | AggregateEmit
  - input_rows / rows: pre/post tuple counts for the stage
  - time_ns: wall clock nanoseconds spent inside the stage (coarse; single-threaded)
  - bytes_out: approximate logical bytes of JSON row fragments (future: physical size once structured rows land)
  - bytes_alloc: heuristic currently mirroring bytes_out; roadmap to replace with real allocator delta sampling

- Aggregation:

  - AggregateBuild: rows_in = raw logical input rows (currently derived from param row count); rows_out = number of groups
  - AggregateEmit: rows_in = rows_out of build; rows_out identical (projection emission)

- Planned enhancements:

  - Structured row arena to measure precise bytes_out and allocation churn
  - Allocator wrapper capturing allocated/freed bytes per phase
  - Operator ID + dependency graph for multi-branch pipelines (joins, optional matches)
  - Distinct spill / Sort spill counters when external memory introduced

  Canonical DISTINCT / UNION semantics

  - Numeric canonicalization trims decimal scale (1.0, 1.00 -> 1) so numerically equal decimals and ints deduplicate.
  - Type-sensitive: numeric 1 and string "1" remain distinct (string values prefixed with type tag in canonical key).
  - Future: add temporal canonical forms (date/time equivalence) with flagger warnings for implicit normalization.
