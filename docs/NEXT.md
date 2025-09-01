# NEXT — ISO‑GQL alignment (execution‑ready backlog)

Swimlanes with concrete acceptance tests. ISO clause anchors are references (no quoting). Idempotent across runs.

Note: Completed items move to docs/IMPLEMENTED.md.

## Now (P0)

1. Diagnostics mapping (initial)

- Why: Standardize error surfaces (ISO 23.2) and enable conformance reporting (ISO 24.\*).
- What: Map planner/parser/evaluator errors to codes; define precedence; wire to CLI print.
- Acceptance:
  - Tests assert codes for: US001 (unordered pagination), GroupByIllegal, IllegalOrderKey, TypeMismatch.
  - README Troubleshooting lists codes and meanings.
- ISO anchors: 23.2 diagnostics; 14.10 (ORDER BY legality); 16.18–16.19 (US001); 24.\* conformance.
- Scope: S • DRI: core

1. String predicate evaluation

- Why: Complete common scalar semantics (ISO 16.x).
- What: Implement STARTS WITH, ENDS WITH, CONTAINS in evaluator with NULL/empty handling.
- Acceptance:
  - Truth tables for NULL x string and empty cases.
  - Integration tests in src/gql.zig exercising WHERE with these predicates.
- ISO anchors: 16.x expressions.
- Scope: S • DRI: core

## Next (P1)

1. CASE expression completeness

- Why: Production‑ready CASE semantics across NULLs.
- What: Extend evaluator for simple+searched CASE with 3VL; add exhaustive tests.
- Acceptance: Searched/operand CASE matrices pass; nested CASE works.
- ISO anchors: 16.x expressions.
- Scope: M • DRI: core

1. Parameters support ($param)

- Why: Real‑world query inputs and testability.
- What: Parse `$name`; bind from CLI map; evaluator substitution with types.
- Acceptance: Parser/evaluator tests; CLI `--param a=1 --param s=foo` works.
- ISO anchors: 16.x.
- Scope: M • DRI: core

## Later (P2)

1. Aggregation semantics (phase‑2)

- Why: Enable typed aggregates + HAVING filters.
- What: COUNT/SUM/MIN/MAX with GROUP BY legality; HAVING evaluation.
- Acceptance: Positive/negative tests for grouping/HAVING; printer stability.
- ISO anchors: 14.10; 16.x typing.
- Scope: L • DRI: core

1. Path search tie‑break (UA005/UA006)

- Why: Deterministic selective path selection.
- What: Document and implement tie‑break (length, id) policy.
- Acceptance: Stable results under ties; docs updated.
- ISO anchors: UA005/UA006.
- Scope: M • DRI: core

## Cutline

- Distributed execution, storage/WAL, GPU operators are out‑of‑scope for Milestone‑1; tracked separately.
- Procedures/transactions: design‑documented, not implemented in this milestone.
