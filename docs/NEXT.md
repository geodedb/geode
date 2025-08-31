# NEXT plan — ISO‑GQL alignment (execution‑ready)

Swimlanes with concrete acceptance tests. ISO clause anchors are references (no quoting).

## Now (P0)

1. Pagination legality + US001 guardrails

- Why: Prevent incorrect OFFSET/LIMIT pushdowns on unordered tables (ISO 16.18–16.19, US001; 14.10).
- What: Keep explicit order tracking; reject unsafe pushdowns; document behavior in `query_engine.md`.
- Acceptance:
  - Tests: planner.zig “offset pushdown rejected/allowed”.
  - Docs: US001 note present in § ORDER & page.
- Scope: S • DRI: core

1. Temporal session offset end‑to‑end

- Why: Local datetimes compare correctly with a session offset (ISO 18.x; 14.10; sessions §7).
- What: Thread CLI flag into comparator; demo path; tests.
- Acceptance:
  - Exec test for local vs zoned equality under offset.
  - CLI: `--session-offset` affects sort demo output.
- Scope: S • DRI: core • Dep: REQ‑GQL‑009

1. GROUP BY legality (phase‑1) and HAVING legality

- Why: Enforce scoping of non‑aggregates (ISO 14.10).
- What: Planner legality checks; tests; diagnostics placeholders.
- Acceptance:
  - Tests: planner “group by legality basic”, “having legality”.
- Scope: M • DRI: core

1. Conformance flagger (skeleton)

- Why: Track supported features and impl‑defined choices (ISO 24.\*; 23.2 shape).
- What: Emit JSON feature profile; CLI flag; tests.
- Acceptance:
  - Test asserts presence of 14.4, 14.10, 16.18, 16.19, 14.12, 18.x.
  - Output includes US001/UA005/UA006 notes.
- Scope: S • DRI: core

## Next (P1)

1. Set ops semantics (DISTINCT/ALL)

- Why: Make UNION/INTERSECT/EXCEPT observable (ISO 14.12 + Annex).
- What: Exec semantics for bag/set; stable ordering policy.
- Acceptance:
  - `UNION DISTINCT` removes duplicates; `INTERSECT ALL` keeps multiplicities.
  - Tests assert counts.
- Scope: M • DRI: core

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
