# NEXT plan — ISO‑GQL alignment (execution‑ready)

Swimlanes with concrete acceptance tests. ISO clause anchors are references (no quoting).

Note: Completed items have moved to docs/IMPLEMENTED.md. This plan lists only upcoming work.

## Now (P0)

1. Diagnostics mapping (initial)

- Why: Standardize error surfaces (ISO 23.2).
- What: Map errors to codes; precedence; doc.
- Acceptance:
  - Tests for US001, GroupByIllegal, IllegalOrderKey codes.
- Scope: S • DRI: core

## Next (P1)

1. Expression eval: CASE + string predicates

- Why: Complete common scalar semantics (ISO 16.x).
- What: Eval for CASE simple/searched; STARTS/ENDS/CONTAINS; regex.
- Acceptance:
  - `RETURN CASE WHEN a>0 THEN 'p' ELSE 'n' END` produces expected values.
  - Null/empty edge cases covered.
- Scope: M • DRI: core

1. Diagnostics mapping (initial)

- Why: Standardize error surfaces (ISO 23.2).
- What: Map errors to codes; precedence; doc.
- Acceptance:
  - Tests for US001, GroupByIllegal, IllegalOrderKey codes.
- Scope: S • DRI: core

## Later (P2)

1. Aggregation semantics (phase‑2)

- Why: Enable typed aggregates + HAVING filters (ISO 14.10; 16.x typing).
- What: Aggregate catalog (COUNT/SUM/MIN/MAX), eval, HAVING.
- Acceptance: Positive/negative tests for grouping & HAVING.
- Scope: M/L • DRI: core

1. Parameters + ORDER BY NULLS FIRST/LAST end‑to‑end

- Why: Real‑world queries and sort control (ISO 16.x; 14.10).
- What: `$param` parse/bind; substitution in eval; nulls policy honored at runtime.
- Acceptance: Param substitution test; nulls policy tests.
- Scope: M • DRI: core

1. Path search tie‑break (UA005/UA006)

- Why: Deterministic selective path selection.
- What: Document and implement tie‑break (length, id) policy.
- Acceptance: Stable results under ties; docs updated.
- Scope: M • DRI: core

## Cutline

- Distributed execution, storage/WAL, and GPU operators are out‑of‑scope for Milestone‑1; tracked separately.
- Procedures/transactions: design‑documented, not implemented in this milestone.
