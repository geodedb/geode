# Cost Model Enumeration Seed (S-024 / REQ-GQL-075)

Purpose: Establish foundational data structures and enumeration phases to enable future cost-based optimization (CBO) without altering existing heuristic planner semantics.

Scope (Initial):

- Collect basic cardinality & selectivity heuristics for: NodeScan (by label), Expand (by average degree bucket), Filter (predicates by type), SetOp (estimated distinct factor).
- Introduce `planner/cost/model.zig` with:
  - `struct CardinalityEstimate { rows: f64, confidence: f32 }`
  - `struct Cost { cpu: f64, memory: f64, io: f64 }`
  - Interfaces: `fn estimate(op: *LogicalOp, ctx: *Context) CostEstimate`.
- Enumeration: Linear chain with optional branch for set operations; future extension to join reordering.
- Evidence Path:
  - TEST: `TestCANARY_REQ_GQL_075_CostModelSeedBasicEstimates` verifying non-zero estimates & monotonic filter reduction.
  - BENCH (later): Variance envelope for cost estimation stability across synthetic graphs.

Assumptions:

- Degree histogram available via existing PathCache enrichment stats (reuse buckets).
- Label cardinalities approximated via stored counts updated transactionally (MVCC-safe read snapshot).
- Memory cost approximated as `row_width * rows` with row_width from projected columns metadata.

Next Steps After Seed:

1. Introduce join (pattern) enumeration once multi-pattern MATCH joins land.
2. Add adaptive feedback loop comparing estimated vs actual rows for calibration.
3. Persist rolling error metrics (per op type) and surface via diagnostics.

Explain JSON Integration (2025-09-22):
An initial lightweight `explainChain` API now emits `cost_explain.v1` JSON summarizing linear operator chains (op kind, estimated rows, confidence, cost). This is an observational surface only (no plan selection influence yet) and forms the substrate for future calibration feedback loops and user-facing `EXPLAIN` output enrichment.

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=DesignDoc; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_075_CostModelSeedBasicEstimates; BENCH=BenchmarkCANARY_REQ_GQL_075_CostModelSeedVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
