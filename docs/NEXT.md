# NEXT — Execution Plan (Unified CANARY Slice Format) — Generated 2025-09-21

## 0. WHY (Strategic Intent)

Sustain fully evidence-backed GQL conformance while hardening runtime determinism and storage durability. Focus horizon: (a) stabilize variance of latency‑sensitive subsystems (WAL, planner, CDC, MVCC), (b) introduce missing cache + queue depth observability, (c) reduce future drift risk via freshness & delta tooling, and (d) prepare path for multi-tenant + adaptive planner features without re‑architecting later.

## 1. WHAT (Objectives, Bounded)

1. Land remaining variance guard candidates (queue depth, cost model phase) without increasing mean overhead >1%.
2. Introduce PathCache skeleton with deterministic hashing & hit/miss metrics (BENCHED hot path).
3. Add WAL page flush queue depth variance envelope (BENCHED) + regression guard on p95/mean < 2.4.
4. Harden recovery corruption scenarios with targeted corrupt page fixture set (already TESTED—extend with latency bench if variance observed >0.20 CV).
5. Planner adaptive replan trigger timing instrumentation (TESTED then BENCHED).
6. Automate ImplementationReality deltas in CI to block undocumented status promotions.
7. Keep STUB count at 0; any new feature enters directly as TESTED (minimum) with CANARY line.

## 2. ACCEPTANCE (Machine-Checkable)

Each slice MUST:

* Add ≥1 new CANARY line (STATUS=TESTED or BENCHED) with UPDATED=today.
* Introduce exactly one aspect promotion per requirement (avoid multi‑aspect hidden bundling).
* Provide test name `TestCANARY_REQ_GQL_<id>_<Aspect>`; bench (if any) `BenchmarkCANARY_REQ_GQL_<id>_<Aspect>`.
* Pass: `./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict`.
* If variance guard: assert (a) CV ≤ 0.22 (unless documented exception), (b) p95/mean ≤ 2.55.
* If introducing performance envelope on existing BENCHED aspect, show prior baseline JSON delta in PR description (auto-generated script accepted).

## 3. ISO REFERENCES (Anchor Catalog — paraphrased)

| Theme | ISO Clause Anchor | Paraphrased Intent |
|-------|-------------------|--------------------|
| Pagination legality | §16.18–16.19 | ORDER required for deterministic pagination unless impl-defined override flagged. |
| Diagnostics precedence | §23.x | Highest precedence diagnostic reported; others folded with code list. |
| Conformance profile | §24.x | Declare minimum + optional feature set; flag extensions. |
| Set operations DISTINCT | §14.x | Duplicate elimination semantics governed by binding table equivalence. |
| Transaction isolation | §8.x | Serializable isolation: prevent phantoms & write skew (SSI instrumentation). |

## 4. DEPS / BLOCKERS

| Dependency | Needed For | Status | Risk | Mitigation |
|------------|-----------|--------|------|-----------|
| Deterministic monotonic time shim | Stable variance benches (Planner, WAL) | Present | Low | Already used (std.time). |
| PathCache index structure | PathCache variance envelope | Missing | Med | Implement minimal LRU map (seeded hash). |
| Queue depth instrumentation in WAL flush scheduler | WALPageFlushQueueDepthVarianceEnvelope | Missing | Med | Add atomic counter + sampling hook. |
| Planner phase timing hooks | CostModelPhase variance | Partial | Low | Insert timers around rewrite & cardinality loops. |
| ImplementationReality delta tool CI step | Drift prevention | Implemented (tool exists) | Low | Wire into pipeline. |

## 5. SCOPE (In / Out)

IN:

* Variance envelopes: WAL flush queue depth, planner cost model phase, adaptive replan trigger, path cache lookup.
* PathCache (read-mostly, size-bounded, eviction metric) minimal version.
* Recovery corruption latency probe (optional bench if instability detected).
* Automation: reality delta CI gate.

OUT (Future Release):

* Full distributed (multi-leader) consensus paths.
* GPU operator kernels (beyond flagger).
* Cross-shard 2PC executor.
* Advanced multi-key TDE rotation scheduling.

## 6. DRI / OWNERS

| Area | Owner | Backup |
|------|-------|--------|
| Storage (WAL, queue) | storage | engine |
| Planner variance & phases | planner | engine |
| PathCache | planner | engine |
| CDC adaptive heuristics | cdc | streaming |
| Freshness / Reality tooling | tooling | infra |
| Constraints perf | schema | engine |

## 7. CURRENT EVIDENCE SNAPSHOT

From latest scan (see `status.json`):

* BENCHED aspects: 85
* TESTED (non-BENCHED): 107
* STUB/IMPL: 0
* Variance Guards Landed: 32 (all passing thresholds)

Representative variance envelopes (all BENCHED): WALFlushBatch, WALSegmentRecycleLatency, PlannerRewritePass, PlannerCardinalityEstimate, SetOpDistinctDedup, QueryPlanCacheEvict, MVCCVersionPrune, CDCAdaptiveHeuristicsDecisionLatency, ConstraintPerfVariance, PathExpansionHeuristic.

## 8. ROLLING PLAN (30 / 14 / 7 Day)

### 30 Day (Thematic)

1. Implement PathCache skeleton + lookup variance guard.
2. Land WALPageFlushQueueDepthVarianceEnvelope.
3. Instrument planner cost model phases + variance envelope.
4. Adaptive replan trigger instrumentation + initial variance capture.
5. CI wiring: ImplementationReality delta gate & freshness WARN surfacing in PR summary.

### 14 Day (Commitment)

1. WAL page flush queue depth instrumentation + bench (REQ-GQL-028 new ASPECT=WALPageFlushQueueDepthVarianceEnvelope).
2. PathCache minimal LRU (REQ-GQL-021 extension) + TESTED ingestion & lookup test.
3. Planner phase timers + TESTED cost metrics extraction (no bench yet).

### 7 Day (Immediate Slices)

1. Add atomic queue depth counter + sampling; bench envelope thresholds CV≤0.20, p95/mean≤2.45.
2. Implement PathCache map (fixed buckets + per-bucket small vector) + lookup smoke test.
3. Add `RealityDeltaCI` step to pipeline YAML (ensuring no silent promotions).

## 9. UPCOMING SLICES (Canonical Form)

| Slice | REQ | Feature/Aspect | Type | New Evidence | Exit Criteria |
|-------|-----|----------------|------|--------------|---------------|
| S-001 | REQ-GQL-028 | WALPageFlushQueueDepthVarianceEnvelope | BENCH | BenchmarkCANARY_REQ_GQL_028_WALPageFlushQueueDepthVarianceEnvelope | CV≤0.20 p95/mean≤2.45 & strict verify passes |
| S-002 | REQ-GQL-021 | PathCacheLookup (TESTED) | TEST | TestCANARY_REQ_GQL_021_PathCacheLookup | Hit ratio metrics & deterministic eviction test |
| S-003 | REQ-GQL-021 | PathCacheLookupVarianceEnvelope | BENCH | BenchmarkCANARY_REQ_GQL_021_PathCacheLookupVarianceEnvelope | CV≤0.22 p95/mean≤2.55 |
| S-004 | REQ-GQL-021 | PlannerCostModelPhaseVarianceEnvelope | BENCH | BenchmarkCANARY_REQ_GQL_021_PlannerCostModelPhaseVarianceEnvelope | All phase timings stable (CV≤0.18 hot phases) |
| S-005 | REQ-GQL-021 | PlannerAdaptiveReplanTrigger (TESTED) | TEST | TestCANARY_REQ_GQL_021_AdaptiveReplanTrigger | Deterministic replan threshold test |
| S-006 | REQ-GQL-021 | PlannerAdaptiveReplanVarianceEnvelope | BENCH | BenchmarkCANARY_REQ_GQL_021_PlannerAdaptiveReplanVarianceEnvelope | Trigger latency CV≤0.22 |
| S-007 | REQ-GQL-028 | CorruptRecoveryLatency (optional) | BENCH | BenchmarkCANARY_REQ_GQL_028_CorruptRecoveryLatency | Only if CV>0.20 observed in probe |

## 10. VARIANCE ENVELOPE POLICY (Active)

| Class | Target CV | Max p95/mean | Notes |
|-------|-----------|--------------|-------|
| Hot Path (PropertyAccess, Planner phases) | ≤0.18 | ≤2.40 | Re-run 2x if fail then flag regression |
| Storage / WAL Adaptive | ≤0.21 | ≤2.55 | Allow moderate I/O jitter |
| CDC Adaptive / Heuristic | ≤0.22 | ≤2.55 | External event timing noise |
| Graph Analytics (Large) | ≤0.23 | ≤2.60 | Iteration count drift acceptable |

Deviations require explicit doc note + CANARY comment `// VARIANCE_EXCEPTION: reason`.

## 11. AUTOMATION & GOVERNANCE

Pipelines enforce: freshness, variance, over-claim, reality delta, and (soon) slice naming pattern `S-###`. Failure in any gate blocks merge.

## 12. PR CHECKLIST (Operational)

1. New CANARY line added (diff shows UPDATED today).
2. Tests/benches green locally: `zig build test`.
3. Run scanner verify: `./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict`.
4. For BENCH promotions attach variance metrics (mean, cv, p95/mean).
5. No modification of unrelated UPDATED fields.

## 13. COMMANDS (Reference)

```bash
go build -o ./bin/canaryscan ./tools/canaryscan
./bin/canaryscan --root . --out status.json --csv status.csv
./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict
```

## 14. APPENDIX (Historical Context Condensed)

* 32 variance envelopes landed; no pending STUB aspects.
* Transitioned from broad algorithm BENCH promotions to subsystem variance stabilization.
* Freshness & reality delta tools reduce governance overhead and prevent drift.

---

End of NEXT (unified slice format). Authoritative evidence: `status.csv` & CANARY lines in source.
