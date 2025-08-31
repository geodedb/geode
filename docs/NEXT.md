# NEXT plan — ISO‑GQL alignment (execution‑ready)

Swimlanes with concrete acceptance tests. ISO clause anchors are references (no quoting).

## Now (P0)

1. Pagination legality + US001 guardrails

- Why: Prevent incorrect OFFSET/LIMIT pushdowns on unordered tables (ISO 16.18–16.19, US001).
- What: Keep explicit order tracking in planner; reject unsafe pushdowns; document behavior.
- Acceptance:
  - Test: src/planner.zig:105 fails when pushing OFFSET without ORDER.
  - Test: src/planner.zig:119 passes with explicit ORDER BY.
  - Docs: query_engine.md updated with US001 note in §3.
- ISO: 16.18, 16.19, US001; 14.10.
- Scope: S; DRI: core.

1. Temporal session offset wiring end‑to‑end

- Why: Ensure local datetimes compare correctly with a session offset (ISO 18.x + 14.10 ordering).
- What: Thread CLI flag to exec comparator; expose in lib API; add smoke tests.
- Acceptance:
  - Exec test uses local vs zoned datetimes with session offset; ordering stable.
  - CLI: --session-offset "+05:00" affects JSON verbose temporals and ORDER comparator.
- ISO: 18.x, 14.10; Sessions (7) for context.
- Scope: S; DRI: core; Dep: REQ-GQL-009.

1. GROUP BY legality (phase 1)

- Why: Enforce scoping of non‑aggregates (ISO 14.10).
- What: Parser/planner checks; error diagnostics; printer unchanged.
- Acceptance:
  - Negative tests when non‑aggregated column appears without being grouped.
  - Positive tests with proper GROUP keys and aggregates.
- ISO: 14.10; 23.2 diagnostics (shape only).
- Scope: M; DRI: core.

1. Conformance flagger (skeleton)

- Why: Track supported features and impl‑defined choices (ISO 24.\* conformance; 23.2 diagnostics).
- What: Emit JSON profile with features and statuses; expose CLI flag.
- Acceptance:
  - `zig build test` includes a test asserting presence of feature tags for 14.4, 14.10, 16.18, 16.19, 14.12, 18.x.
  - Output includes US001, UA005, UA006 markers with notes.
- ISO: 24.\*, 23.2.
- Scope: S; DRI: core.

## Next (P1)

1. Set ops semantics (dedup/ALL)

- Why: Make UNION/INTERSECT/EXCEPT observable (ISO 14.12 + Annex set ops).
- What: Planner and exec layers implement bag/set semantics; stable ordering policy.
- Acceptance:
  - GQL: `q1 UNION DISTINCT q2` removes duplicates; `INTERSECT ALL` preserves multiplicities.
  - Tests: binding tables match expected multiset counts.
- ISO: 14.12; Annex (set ops).
- Scope: M; DRI: core.

1. CASE expression evaluation + string predicates eval

- Why: Complete expression semantics for common queries (ISO 16.x).
- What: Eval layer for CASE simple/searched; STARTS/ENDS/CONTAINS; =~ regex.
- Acceptance:
  - GQL: `RETURN CASE WHEN a>0 THEN 'p' ELSE 'n' END` → correct values.
  - Predicates evaluate correctly with null/empty edge cases.
- ISO: 16.x.
- Scope: M; DRI: core.

1. Diagnostics mapping (initial)

- Why: Standardize status precedence and error surfaces (ISO 23.2).
- What: Map internal errors to codes; basic precedence; doc in query_engine.md.
- Acceptance:
  - Unit tests assert diagnostic codes for ORDER BY illegal key, GROUP BY misuse.
- ISO: 23.2.
- Scope: S; DRI: core.

## Later (P2)

1. Aggregation semantics (phase 2: HAVING, catalog)

- Why: Enable group filters and typed aggregates (ISO 14.10, 16.x).
- What: Add HAVING; aggregates catalog (arity/types); planner checks.
- Acceptance:
  - Negative tests for misuse (non‑grouped ref); positive HAVING tests.
- Scope: M/L; DRI: core.

1. Parameters + ORDER BY NULLS FIRST/LAST

- Why: Real‑world queries and sort control (ISO 16.x; 14.10).
- What: `$param` markers; nulls policy in AST and comparator; printer support.
- Acceptance:
  - GQL: `ORDER BY n.prop NULLS FIRST` orders nulls ahead.
  - Param substitution test passes.
- Scope: M; DRI: core.

1. Path search tie‑break (UA005/UA006)

- Why: Deterministic selective path selection.
- What: Document and implement deterministic tie‑break (length, id) for selective path ops.
- Acceptance:
  - Planner/executor returns stable paths under ties; doc updated.
- ISO: UA005/UA006 (implementation‑dependent).
- Scope: M; DRI: core.

## Cutline

- Distributed execution, storage/WAL, and GPU operators are out‑of‑scope for Milestone‑1; tracked separately in docs.
- Procedure bodies and transactions are design‑documented but not implemented in this milestone.
