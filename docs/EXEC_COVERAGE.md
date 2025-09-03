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
