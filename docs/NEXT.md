# NEXT plan — ISO‑GQL alignment (execution‑ready)

Below is a Now/Next/Later plan with crisp acceptance checks. Clauses cited are anchors for developer reference only.

## Now (P0) — Spec‑correct core

### 1. Pagination + orderedness legality

- Work: carry ordered/unordered through parse/type info; in planner, forbid OFFSET pushdown without explicit ORDER; document US001.
- Acceptance: unit test fails when OFFSET is pushed without ORDER; passes when ORDER exists; doc note in `query_engine.md`.

### 2. YIELD and WHERE semantics

- Work: enforce YIELD aliasing/typing rules (16.14) and WHERE behavior (16.13); error on duplicate aliases.
- Acceptance: golden tests for YIELD renames and column types; duplicate‑alias yields a diagnostic.

### 3. Set operations completeness

- Work: implement INTERSECT/EXCEPT with ALL/DISTINCT; feature‑gate tags (GQ03–GQ07); parser + legality + planner IR.
- Acceptance: chaining case `q1 UNION ALL q2 EXCEPT q3` has correct duplicate semantics (tests).

### 4. CASE + string predicates

- Work: add CASE (simple/searched) and predicates STARTS WITH, ENDS WITH, CONTAINS, and `=~`.
- Acceptance: parse + eval tests; operator precedence consistent with comparisons.

### 5. Temporal literals & types

- Work: lexer for ISO‑8601 forms; type checks for instant/duration; minimal casts.
- Acceptance: literals round‑trip; ordering/comparison rules validated in tests.

## Next (P1) — DML/Procedures + Diagnostics/Conformance

### 6. INSERT + linear DML (parse + guards)

- Work: parse `<insert statement>`; reject in READ ONLY; feature gates wired.
- Acceptance: parse tests + RO rejection tests.

### 7. Procedure/NEXT skeleton

- Work: parse `<procedure body>`/`NEXT`; IR wired; round‑trip in printer.
- Acceptance: parse/print tests succeed.

### 8. Diagnostics & protocol mapping

- Work: status precedence mapping; list additional statuses; choose/document UA002 policy.
- Acceptance: protocol tests reflect precedence and multi‑status behavior.

### 9. Conformance Profile + Flagger (MVP)

- Work: fill profile (front‑end scope); ship a flagger marking extensions/options/impl‑defined behaviors.
- Acceptance: flagger unit tests; profile emitted in build artifacts.

## Later (P2) — Aggregation polish & params

### 10. Aggregation semantics

- Work: GROUP BY scoping; HAVING; aggregates catalog with arity/type checks.
- Acceptance: negative tests for non‑grouped non‑aggregates; HAVING evaluated correctly.

### 11. Params & ORDER BY polish

- Work: `$param` markers; NULLS FIRST/LAST on sort keys.
- Acceptance: parser + eval tests; keys carry nulls policy through to printer and planner properties.

### Continuous

- Maintain planner crosswalk compliance (OPTIONAL→LOJ; Order/Top‑k; PathExpand legality/tie‑break) per `docs/query_engine.md`.
