# NEXT — ISO‑GQL alignment (execution‑ready backlog)

Swimlanes with concrete acceptance tests. ISO clause anchors are references (no quoting). Idempotent across runs.

Note: Completed items move to docs/IMPLEMENTED.md.

## Now (P0)

1. Diagnostics mapping (initial)

- Why: Standardize error surfaces (ISO 23.2) and enable conformance reporting (ISO 24.\*).
- What: Map planner/parser/evaluator errors to codes; define precedence; wire to CLI print.
- Acceptance tests (names illustrative; include in src/diagnostics.zig and CLI harness):
  - GQL: `RETURN 1 LIMIT 10 OFFSET 5` (no ORDER BY) → Error code: US001; details: unordered pagination. ISO: 16.18–16.19.
  - GQL (ident-only policy): `RETURN a ORDER BY f(a)` → Error code: IllegalOrderKey. ISO: 14.10.
  - GQL: `RETURN a, SUM(b) GROUP BY a, b` → Error code: GroupByIllegal. ISO: 14.10.
  - GQL: `RETURN 1 < "2"` → Error code: TypeMismatch. ISO: 16.x.
  - Binding table shape: n/a (diagnostics); CLI prints code, message, anchors.
- ISO anchors: 23.2 diagnostics; 14.10 (ORDER BY legality); 16.18–16.19 (US001); 24.\* conformance.
- Dependencies: none.
- Scope: S • DRI: core

1. README troubleshooting section

- Why: Document codes for users and conformance reviewers.
- What: Add a concise Codes table (US001, GroupByIllegal, IllegalOrderKey, TypeMismatch) with one-liners and ISO anchors.
- Acceptance: README contains the table and anchors; links from GAP_ANALYSIS.md and NEXT.md.
- ISO anchors: 23.2; 24.\*
- Dependencies: (1)
- Scope: S • DRI: core

## Next (P1)

1. CASE expression completeness

- Why: Production‑ready CASE semantics across NULLs.
- What: Extend evaluator for simple+searched CASE with full three‑valued logic (3VL); add exhaustive tests.
- Acceptance tests:
  - GQL: `RETURN CASE WHEN a IS NULL THEN 'n' WHEN a THEN 't' ELSE 'f' END AS r`
    - Input bindings: a: [NULL, true, false]
    - Expected binding table columns: [r STRING]; rows: ['n'], ['t'], ['f'].
  - GQL: `RETURN CASE a WHEN 1 THEN 'one' WHEN 2 THEN 'two' ELSE 'x' END AS r`
    - Input: a: [NULL, 1, 2, 3]
    - Expected: r: [NULL, 'one', 'two', 'x'] (NULL propagates). ISO: 16.x.
- ISO anchors: 16.x expressions.
- Dependencies: none.
- Scope: M • DRI: core

1. ORDER BY policy guard integration

- Why: Ensure parser policy (ident‑only) is enforced and surfaced via diagnostics.
- What: Wire ident‑only guard to diagnostics layer; add planner‑stage guard to reject OFFSET pushdown without order (already present) with code US001.
- Acceptance tests:
  - GQL (policy ident‑only): `RETURN a ORDER BY a.b` → IllegalOrderKey.
  - GQL: `MATCH (n) RETURN n LIMIT 5 OFFSET 3` (no ORDER BY) → US001.
- ISO anchors: 14.10; 16.18–16.19.
- Dependencies: Diagnostics (P0‑1).
- Scope: S • DRI: core

## Later (P2)

1. Aggregation semantics (phase‑2)

- Why: Enable typed aggregates + HAVING filters.
- What: COUNT/SUM/MIN/MAX/AVG with GROUP BY legality; HAVING evaluation; ORDER BY over aggregated outputs (aliases/ordinals).
- Acceptance tests:
  - GQL: `MATCH () RETURN a, COUNT(*) AS c GROUP BY a HAVING c > 1 ORDER BY c DESC NULLS LAST LIMIT 10`
    - Expected columns: [a ANY, c INT]; ordered desc by c; top 10.
  - GQL: `RETURN AVG(x) AS a, SUM(x) AS s` over x: [1, 2, NULL, 3]
    - Expected: a = 2 (INT), s = 6 (INT). ISO: 14.10; 16.x typing.
- ISO anchors: 14.10; 16.x typing.
- Dependencies: none.
- Scope: L • DRI: core

1. Path semantics groundwork (policy only)

- Why: Lock down UA005/UA006 tie‑breaking before implementing path operators.
- What: Keep deterministic `(length, id‑sequence)` tiebreak helper and tests.
- Acceptance test:
  - Unit: pathLess(a, b) orders shorter paths first; if equal length, lexicographic node id list.
- ISO anchors: 22.4; UA005/UA006.
- Dependencies: none.
- Scope: S • DRI: core

## Cutline

- Server & Protocol: geoded/geodec processes and binary protocol (HELLO/BEGIN/COMMIT/ROLLBACK/RUN_GQL/PULL) are tracked post‑M1.
- Storage & Durability: slotted pages, adjacency CSR, property heap, WAL (ARIES), recovery — tracked post‑M1.
- Transactions: MVCC (SI) with locks for DML, protocol demarcation — tracked post‑M1.
- Distributed scaffold: leader‑only Raft stubs, 2PC coordinator interfaces, shard map placeholders — tracked post‑M1.
- GPU operators and advanced features remain out‑of‑scope for Milestone‑1.
