# MATCH Label/Property Predicate Execution Slice (Planned)

## Objective

Introduce minimal executable semantics for MATCH label and property predicate filtering without re-introducing STUB aspects into CANARY ledger. This document records the planned slice so evidence can land directly as TESTED/BENCHED.

## Scope (Minimal Viable)

1. Label filter on node pattern: `(n:Person)` limiting scans to nodes with `labels` array containing `Person`.
2. Single property equality predicate pushdown: `(n:Person { country: 'US' })`.
3. Combined label + property predicate in `WHERE` relocation equivalence: `MATCH (n:Person) WHERE n.country = 'US' RETURN n.id` yields identical binding set to inline form.
4. Deterministic path tie-break preserved (UA005/UA006) when filters applied (ordering unaffected).
5. Basic selectivity metric captured for planner phase timing envelope extension (attach to existing PlannerPipelinePhaseVarianceEnvelope as additional metadata when available).

## Out of Scope (Future Slices)

- Multiple label disjunction / conjunction.
- Range predicates, inequality, regex.
- OPTIONAL MATCH semantics.
- Index utilization (scan only).
- Cartesian product elimination.

## Implemented CANARY Lines

```text
CANARY: REQ=REQ-GQL-017; FEATURE="Match Label+Property Predicate"; ASPECT=Execution; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_MatchLabelProperty; OWNER=engine; UPDATED=2025-09-21
CANARY: REQ=REQ-GQL-017; FEATURE="Match Label+Property Predicate"; ASPECT=MatchLabelPropertyVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_017_MatchLabelPropertyVarianceEnvelope; OWNER=engine; UPDATED=2025-09-21
```

Variance bench measures added latency vs unlabeled scan; thresholds enforced: cv≤0.24, p95/mean≤2.65, mean overhead ≤5%.

## Tests (Acceptance)

1. `TestCANARY_REQ_GQL_016_MatchLabelPredicateExecution`: parse & execute pattern with label + property; assert filtered bindings.
2. Negative: unknown label yields empty set (no error).
3. Equivalence: inline property vs WHERE clause produce identical sorted bindings.
4. Determinism: repeated execution hash of binding table stable across 50 iterations (Wyhash of JSON serialization).

## Benchmark

`BenchmarkCANARY_REQ_GQL_016_MatchLabelPredicateVarianceEnvelope`: run labeled predicate expansion and unlabeled baseline; compute overhead ratio; emit schema v1+v2 variance lines and ensure thresholds.

## Implementation Sketch

- Extend planner node pattern struct with `labels: []const []const u8` and optional `property_predicates` slice.
- During execution NodeScan, add simple filter loop over candidate nodes (temporary linear scan; later index).
- Capture start/stop times inside existing planner phase instrumentation to attribute additional filter cost.

## Rollout

1. Implement execution + test (TESTED).
2. Add variance bench (BENCHED) in same PR → immediate promotion.
3. Update REQUIREMENTS and GAP notes from "Partial" to reflect label/property predicate basic support (still missing OPTIONAL).

## Risks

- Potential performance regression on large graphs (mitigated by small initial dataset in test harness; later add index slice).
- Overly broad scope causing STUB introduction (kept minimal intentionally).

## Exit Criteria

- Both CANARY lines present and passing.
- REQUIREMENTS updated with new partial description (OPTIONAL & advanced predicates still pending).
- GAP high-priority item #1 re-scoped to remaining OPTIONAL + advanced predicates.

## Status

Implemented 2025-09-21. OPTIONAL MATCH and multi-predicate support outstanding.
