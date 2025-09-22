# NEXT — Execution Plan (Unified CANARY Slice Format) — Generated 2025-09-22

## 0. WHY (Strategic Intent)

Sustain fully evidence-backed GQL conformance while hardening runtime determinism and storage durability. Focus horizon: (a) stabilize variance of latency‑sensitive subsystems (WAL, planner, CDC, MVCC), (b) introduce missing cache + queue depth observability, (c) reduce future drift risk via freshness & delta tooling, and (d) prepare path for multi-tenant + adaptive planner features without re‑architecting later.

## 1. WHAT (Objectives, Bounded)

1. Extend variance guard coverage to remaining planner sub-phases (group validation granularity) without mean overhead >1% (queue depth + cost model + pagination planning already landed).
2. Pagination execution (streaming page pull) variance envelope (execution-phase jitter) with thresholds (CV≤0.22, p95/mean≤2.55) – complement existing planning envelope.
3. Structural key degree bucket utilization stats & variance bench (validate discrimination improvement & collision rate stability after DBU integration).
4. Harden recovery corruption scenarios with targeted corrupt page fixture set (already TESTED—add latency bench if variance observed >0.20 CV).
5. Planner adaptive replan trigger refinement (threshold autotune experiment BENCHED) plus p95 guard where CV-only.
6. Automate ImplementationReality deltas in CI (landed) – extend to GAP_ANALYSIS self-check (fail on drift) & NEXT snapshot freshness.
7. Maintain 0 STUB policy; all new aspects enter as TESTED (minimum) with CANARY; performance-sensitive enter directly with paired BENCH where feasible.

## 2. ACCEPTANCE (Machine-Checkable)

Each slice MUST:

- Add ≥1 new CANARY line (STATUS=TESTED or BENCHED) with UPDATED=today.
- Introduce exactly one aspect promotion per requirement (avoid multi‑aspect hidden bundling).
- Provide test name `TestCANARY_REQ_GQL_<id>_<Aspect>`; bench (if any) `BenchmarkCANARY_REQ_GQL_<id>_<Aspect>`.
- Pass: `./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict`.
- If variance guard: assert (a) CV ≤ 0.22 (unless documented exception), (b) p95/mean ≤ 2.55.
- If introducing performance envelope on existing BENCHED aspect, show prior baseline JSON delta in PR description (auto-generated script accepted).

## 3. ISO REFERENCES (Anchor Catalog — paraphrased)

| Theme                   | ISO Clause Anchor | Paraphrased Intent                                                                |
| ----------------------- | ----------------- | --------------------------------------------------------------------------------- |
| Pagination legality     | §16.18–16.19      | ORDER required for deterministic pagination unless impl-defined override flagged. |
| Diagnostics precedence  | §23.x             | Highest precedence diagnostic reported; others folded with code list.             |
| Conformance profile     | §24.x             | Declare minimum + optional feature set; flag extensions.                          |
| Set operations DISTINCT | §14.x             | Duplicate elimination semantics governed by binding table equivalence.            |
| Transaction isolation   | §8.x              | Serializable isolation: prevent phantoms & write skew (SSI instrumentation).      |

## 4. DEPS / BLOCKERS

| Dependency                                         | Needed For                             | Status                    | Risk | Mitigation                                        |
| -------------------------------------------------- | -------------------------------------- | ------------------------- | ---- | ------------------------------------------------- |
| Deterministic monotonic time shim                  | Stable variance benches (Planner, WAL) | Present                   | Low  | Already used (std.time).                          |
| PathCache index structure                          | PathCache variance envelope            | Missing                   | Med  | Implement minimal LRU map (seeded hash).          |
| Queue depth instrumentation in WAL flush scheduler | WALPageFlushQueueDepthVarianceEnvelope | Landed (TESTED/BENCHED)   | Low  | Extend to real flush scheduler callbacks.         |
| Planner phase timing hooks                         | CostModelPhase variance                | Partial                   | Low  | Insert timers around rewrite & cardinality loops. |
| ImplementationReality delta tool CI step           | Drift prevention                       | Implemented (tool exists) | Low  | Wire into pipeline.                               |

## 5. SCOPE (In / Out)

IN:

- Variance envelopes: WAL flush queue depth, planner cost model phase, adaptive replan trigger, path cache lookup.
- PathCache (read-mostly, size-bounded, eviction metric) minimal version.
- Recovery corruption latency probe (optional bench if instability detected).
- Automation: reality delta CI gate.

OUT (Future Release):

- Full distributed (multi-leader) consensus paths.
- GPU operator kernels (beyond flagger).
- Cross-shard 2PC executor.
- Advanced multi-key TDE rotation scheduling.

## 6. DRI / OWNERS

| Area                        | Owner   | Backup    |
| --------------------------- | ------- | --------- |
| Storage (WAL, queue)        | storage | engine    |
| Planner variance & phases   | planner | engine    |
| PathCache                   | planner | engine    |
| CDC adaptive heuristics     | cdc     | streaming |
| Freshness / Reality tooling | tooling | infra     |
| Constraints perf            | schema  | engine    |

## 7. CURRENT EVIDENCE SNAPSHOT

From latest scan (see `status.json`) plus newly added execution pagination, degree bucket utilization, planner pre/group validation, pagination prefetch, projection prune variance benches, real degree bucket discrimination test, physiological redo optimization variance, MVCC phantom prevention predicate range detection (REQ-GQL-023), cost-based plan enumeration (REQ-GQL-024), variable-length path property predicate execution (REQ-GQL-017 new aspect), write skew detection (REQ-GQL-025), redo optimization delta variance (REQ-GQL-022 new aspect), and flagger completeness (REQ-GQL-026):

- BENCHED aspects: 165 (added PlanCostModelCalibrationVarianceEnvelope this update along with prior PathCacheEntropyVarianceEnvelope, PlannerAdaptiveReplanRefinementVarianceEnvelope, PlanEnumerationVarianceEnvelope, PathVariableLengthPropertyPredicateVarianceEnvelope, WriteSkewVarianceEnvelope, RedoOptimizationDeltaVariance, FlaggerGenerationVarianceEnvelope, PlanSelectionVarianceEnvelope, PlanEnumerationCostPruneVarianceEnvelope, PlanSelectionPipelineVarianceEnvelope, PlanCostModelVarianceEnvelope, PlanJoinReorderVarianceEnvelope)
- TESTED (non-BENCHED): 168 (added PlanCostModelCalibration, PlanCostModelCalibrationRanking; plus PathCacheEntropyStats, PlannerAdaptiveReplanRefinement, PlanEnumerationEngine, PathVariableLengthPropertyPredicate, WriteSkewDetection, FlaggerCompleteness, PlanSelectionPipelineAdoption, PlanCostModelFactors, PlanJoinReorderDiversity, PhantomDetection)
- STUB/IMPL: 0
- Variance Guards Landed: 65 (all passing thresholds; new guard: PlanCostModelCalibrationVarianceEnvelope)

Representative variance envelopes (all BENCHED): WALFlushBatch, WALSegmentRecycleLatency, WALPageFlushQueueDepthVarianceEnvelope, PlannerRewritePass, PlannerCardinalityEstimate, PlannerCostModelPhaseVarianceEnvelope, PlannerPreValidationVarianceEnvelope, PlannerGroupValidationVarianceEnvelope, PlannerProjectionPruneVarianceEnvelope, PaginationOrderedVarianceEnvelope, PaginationExecutionVarianceEnvelope, PaginationPrefetchVarianceEnvelope, PhysiologicalRedoVarianceEnvelope, RedoOptimizationDeltaVariance, PlanEnumerationVarianceEnvelope, PlanSelectionVarianceEnvelope, PlanEnumerationCostPruneVarianceEnvelope, PathVariableLengthPropertyPredicateVarianceEnvelope, WriteSkewVarianceEnvelope, FlaggerGenerationVarianceEnvelope, SetOpDistinctDedup, QueryPlanCacheEvict, MVCCVersionPrune, CDCAdaptiveHeuristicsDecisionLatency, ConstraintPerfVariance, PathExpansionHeuristic, PathCacheHitMissVarianceEnvelope, PathCacheStructuralKeyCollisionEnvelope, PathCacheStructuralKeyCollisionTightened, PathCacheDegreeBucketUtilizationVarianceEnvelope.

Update 2025-09-21 (post-slice execution):

- Added PathCache skeleton + lookup test + variance bench (S-002 / S-003 partial) now present as TESTED (Lookup, Eviction) and BENCHED (LookupVarianceEnvelope).
- Added distinct spill persistence & merge test `TestCANARY_REQ_GQL_012_HashAggDistinctSpillPersistence` (HashAggDistinctSpillPersistence TESTED) with serialization of COUNT DISTINCT sets.
- Added decimal spill merge test `TestCANARY_REQ_GQL_012_HashAggDecimalSpillMerge` (HashAggDecimalSpillMerge TESTED) validating SUM/AVG precision across spill segments.
- Added distinct spill eviction variance envelope benchmark `BenchmarkCANARY_REQ_GQL_012_HashAggDistinctSpillEvictVarianceEnvelope` (HashAggDistinctSpillEvictVarianceEnvelope BENCHED).
- Added WAL Page Flush Queue Depth instrumentation & variance envelope benchmark (QueueDepthInstrumentation TESTED, WALPageFlushQueueDepthVarianceEnvelope BENCHED) with CV / p95 thresholds enforced.
- Added reality delta CI script `scripts/reality_delta_ci.sh` (governance automation) referenced in Section 11.
- Added Planner phase timing instrumentation (PhaseTiming IMPL) plus variance bench (PlannerCostModelPhaseVarianceEnvelope BENCHED) and adaptive replan trigger (PlannerAdaptiveReplanTrigger TESTED + variance envelope BENCHED).
- Integrated new synthetic `planner/pipeline.zig` orchestrating rewrite/cardinality/cost phases with PathCache + AdaptiveReplan; added integration tests (phase timing >0, cache second-run hit, replan trigger) and `BenchmarkCANARY_REQ_GQL_021_PlannerPipelineVarianceEnvelope` (CV thresholds rewrite/cardinality/cost ≤0.20). CANARY aspects promoted: PlannerPipelineOrchestration, PathCachePlannerIntegration, AdaptiveReplanExecutionIntegration (IMPL awaiting auto-promotion after next evidence scan).
  - Promotions completed (now BENCHED) after evidence scan; added `planQueryWithPipeline` wrapper integrating real `planQuery` legality check with instrumentation plus wrapper test `TestCANARY_REQ_GQL_021_PlannerPipelineWrapperIntegration`.
  - Added real phase timing integration wrapper `planQueryRealTimed` (coarse phase mapping) with CANARY test `TestCANARY_REQ_GQL_021_PlannerPhaseRealTimingIntegration`.
  - Replaced synthetic rewrite/cardinality spins with actual AST rewrite & group validation hooks (`rewrite.zig`), adding aspects `RewriteHookImplementation`, `GroupValidationHookImplementation`, and pipeline integration tests (`RewriteHookPipelineIntegration`, `GroupValidationHookPipelineIntegration`). Synthetic spin logic removed from `pipeline.zig`.
  - Added new variance envelope benchmark `BenchmarkCANARY_REQ_GQL_021_PlannerPipelineP95MeanVarianceEnvelope` enforcing combined CV (≤0.20) and p95/mean (≤2.4) per phase; added CANARY aspect `PlannerPipelineP95MeanVarianceEnvelope`.
  - Promoted `PlannerCostModelPhaseTiming` aspect to BENCHED (variance envelope already present) and added snapshot method to phase timer for safe copy semantics.
  - Added AVG aggregation variance envelope `BenchmarkCANARY_REQ_GQL_012_AvgVarianceEnvelope` (CV≤0.22, p95/mean≤2.55) with CANARY aspect `AvgVarianceEnvelope` (BENCHED).
  - Added high-cardinality hash aggregation spill variance envelope `BenchmarkCANARY_REQ_GQL_012_HashAggSpillVarianceEnvelope` (CV≤0.22, p95/mean≤2.55) validating stable performance under forced spill; CANARY aspect `HashAggSpillVarianceEnvelope` (BENCHED).
  - Added phase-1 functional spill flag test `TestCANARY_REQ_GQL_012_HashAggSpillFlag` (HashAggSpillFlag TESTED) verifying spill flag set without yet evicting in-memory groups (future phase will implement streaming merge & eviction).
  - Added decimal overflow guard tests for SUM and AVG (`TestCANARY_REQ_GQL_012_DecimalOverflowSum` / `...Avg`) ensuring overflow returns NULL (DecimalOverflowSum / DecimalOverflowAvg TESTED).
  - Confirmed planner pipeline variance bench already enforces p95/mean guard (≤2.4) across rewrite/card/cost; no upgrade required—documented to avoid duplicate envelope.
  - Spill Phase-2 (planned): binary serialization of AggregateState to segment files + eviction + merge-on-read; forthcoming aspects: HashAggSpillEvict (TESTED) and HashAggSpillEvictVarianceEnvelope (BENCHED).
  - Added bounded path quantifier execution tests (`PathQuantifierBoundedExecution`) and multi-branch tie-break determinism test (`PathTieBreakMultiBranchDeterminism`), plus variance envelope `PathQuantifierBoundedVarianceEnvelope` (CV≤0.22, p95/mean≤2.55) covering variable-length expansion stability. - Added multi-source deeper branching determinism test (`PathMultiBranchDeterminism`) extending UA005/UA006 evidence to multiple start nodes. - Added Raft commit advancement test (`AppendEntriesCommitAdvance`) validating majority replication commit index update. - Expanded implementation-defined flagger outputs with `CollationBinaryDefault` and `NullOrderPolicyDefault` (tests: `TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering`), surfacing conformance transparency (§24) for collation and NULL ordering policies.
    - Added cycle stress determinism test (`PathCycleStressDeterminism`) validating UA005/UA006 ordering under overlapping cycles (1↔2↔3 plus side cycles) with repeat-run ordering equality.
    - Added zero-length inclusion policy test (`PathZeroLengthInclusionPolicy`) asserting implementation-defined exclusion of zero-length paths even when min_hops=0 (documented; future flagger hook pending).
    - Added high-branch determinism test (`PathHighBranchDeterminism`) for width=8 star+second layer ensuring stable ordering across reruns.
    - Added high-branch expansion variance envelope bench (`PathHighBranchVarianceEnvelope`) with Graph Analytics class thresholds (CV≤0.23, p95/mean≤2.60) – initial run passing.
    - Added allocation variance envelope for variable-length expansion (`PathExpandAllocVarianceEnvelope`) enforcing hot-path thresholds (CV≤0.18, p95/mean≤2.40) using counting allocator wrapper.
  - Added multi-source deeper branching determinism variance envelope (`PathMultiBranchDeterminismVarianceEnvelope`) BENCHED (Graph Analytics thresholds CV≤0.23, p95/mean≤2.60) covering multiple start nodes ordering stability.
  - Added Raft commit advancement variance envelope (`CommitAdvancementVarianceEnvelope`) BENCHED with control-path thresholds (CV≤0.22, p95/mean≤2.55) validating stable majority ack commit latency.
  - Extended protocol implementation-defined flagger test to assert presence of `CollationBinaryDefault` and `NullOrderPolicyDefault` in schema frame outputs (evidence for transparent surfacing of impl-defined policies §24).
  - Implemented OPTIONAL MATCH null-preserving semantics test (`OptionalMatchNullPreserve` aspect) complementing existing MATCH label+property predicate execution; remaining path gaps: property predicates over variable-length expansions and chained OPTIONAL over variable-length patterns.
  - Added structural query key derivation module (`structural_key.zig`) and PathCache hook upgrade from raw bytes to structural signature ignoring variable names & literal values (aspect `PathCacheStructuralKeyDerivation` TESTED).
  - Added structural key equivalence test `TestCANARY_REQ_GQL_021_PathCacheStructuralKeyEquivalence` ensuring same structural pattern with different variable names / literal property values map to identical cache key.
  - Added hit vs miss latency variance envelope benchmark `BenchmarkCANARY_REQ_GQL_021_PathCacheHitMissVarianceEnvelope` (aspect `PathCacheHitMissVarianceEnvelope` BENCHED) asserting mean_hit ≤ mean_miss and CV/p95 thresholds for both distributions.
  - Enriched structural key to encode sorted property key name sets (aspect `PathCacheStructuralKeyEnrichment` TESTED) increasing discrimination beyond counts-only; equivalence still normalizes variable names & literal values.
  - Added collision rate benchmark `BenchmarkCANARY_REQ_GQL_021_PathCacheStructuralKeyCollisionEnvelope` (aspect `PathCacheStructuralKeyCollisionEnvelope` BENCHED) requiring ≥90% unique keys (unique_ratio ≥0.90) across 1500 randomized structural patterns.
  - Enriched structural key with value shape classes (N,S,B,U,A,O) per node endpoint (aspect `PathCacheStructuralKeyValueShapeEnrichment` TESTED) increasing discrimination across heterogeneous property value distributions while preserving equivalence for literal value differences.
  - Tightened collision benchmark guard to ≥92% unique (added aspect `PathCacheStructuralKeyCollisionTightened` BENCHED) and updated benchmark to fail below threshold, reflecting improved key space spread after value shape enrichment.
  - Added structural key degree bucket enrichment (aspect `PathCacheStructuralKeyDegreeBucketEnrichment` TESTED + BENCHED) establishing placeholder DBU category for future stats-based bucketing; follow-up slice will validate utilization and impact on collision ratio.
  - Added ordered pagination planning variance envelope (`PaginationOrderedVarianceEnvelope`) enforcing CV≤0.22, p95/mean≤2.55 across planning timing phases (rewrite/cardinality/cost under an ORDER+LIMIT query shape).
  - Added execution pagination variance envelope (`PaginationExecutionVarianceEnvelope`) covering streaming page latency across configurable page sizes.
  - Added path cache degree bucket utilization variance envelope (`PathCacheDegreeBucketUtilizationVarianceEnvelope`) stabilizing structural key enrichment forward-path.

## 8. ROLLING PLAN (30 / 14 / 7 Day)

### 30 Day (Thematic)

1. Granular planner sub-phase timing (group validation, projection pruning) variance with p95/mean guard (synthetic spins fully removed – refinement only).
2. Pagination execution streaming variance (PULL pages) – ensure stable page delivery latency under varying page_size.
3. Harden path quantifier execution & deterministic tie-break multi-branch (UA005/UA006 stress tests).

   - (Partially Done) Initial bounded quantifier + multi-branch tie-break tests and variance envelope landed.

4. Aggregation breadth (COUNT DISTINCT + HAVING + AVG + variance envelopes: baseline distinct, high-card distinct, AVG, spill) — remaining: extended numeric types, additional HAVING predicate mixes, decimal AVG overflow edge tests.

5. Raft log replication minimal (AppendEntries success/failure) instrumentation & variance.

### 14 Day (Commitment)

Planned upcoming optional slices (post degree bucket integration):

- **Physiological Redo Optimization Variance**
  - Implement baseline optimized redo scan path vs existing logical replay.
  - Add CANARY tests: `TestCANARY_REQ_GQL_022_PhysiologicalRedoCorrectness` and bench `BenchmarkCANARY_REQ_GQL_022_PhysiologicalRedoVarianceEnvelope` (targets CV≤0.18, p95/mean≤2.3 due to sequential I/O predictability).
- **MVCC Phantom Prevention Stress**
  - Add predicate range scan + concurrent insert pattern tests to detect phantom anomalies.
  - Bench overhead `BenchmarkCANARY_REQ_GQL_023_MVCCPhantomPreventionOverheadEnvelope` (ensure mean overhead <5%, CV≤0.22, p95/mean≤2.55).
- **Pagination Execution Streaming Variance (PULL)**
  - Implement streaming page pull timing harness; test stable ordered vs unordered page emission ordering semantics.
  - Bench `BenchmarkCANARY_REQ_GQL_024_PaginationStreamingVarianceEnvelope` with page_size sweep {32,64,128,256}.
- **Adaptive Replan Threshold Autotune Tightening**
  - Auto-adjust threshold based on recent variance; bench convergence stability.
- **Path Quantifier Bounded Tie-Break Expansion**
  - Multi-branch bounded quantifier stress tests for UA005/UA006 determinism under randomized insertion order.
- **Degree Bucket Selectivity Feedback Loop (Follow-up)**
  - Use observed degree buckets to refine selectivity class; bench collision reduction delta vs baseline.

1. Pagination execution variance envelope (page streaming) with environment-tunable `GEODE_PAGINATION_BENCH_PAGE_SIZES` sweep.
2. Add p95/mean augmentation to remaining planner-related benches lacking p95 guard (verify none outstanding after sweep; if all covered, demote slice).
3. Implement remaining aggregation numeric breadth (extended integer/decimal types) and additional HAVING predicate mixes. (Completed: COUNT DISTINCT executor + canonical parser rewrite + HAVING filter test + AVG executor variance + spill & distinct variance envelopes.)
   | S-XXX | REQ-GQL-012 | CountDistinctVarianceEnvelope | BENCH | BenchmarkCANARY_REQ_GQL_012_CountDistinctVarianceEnvelope | Landed (CV≤0.22, p95/mean≤2.55) |

### 7 Day (Immediate Slices)

1. (Done) Ordered pagination planning variance envelope (planning-phase jitter guard) – execution streaming variance pending.
2. Structural key degree bucket utilization probe (collision differential & hit ratio impact) – add variance envelope if measurable effect.
3. COUNT DISTINCT spill Phase-2: eviction + merge-on-read (HashAggSpillEvict / HashAggSpillEvictVarianceEnvelope).
4. Planner group validation micro-phase timing guard (if measurable > noise floor) else document exclusion rationale.

5. MVCC Phantom Prevention Stress (Range Scan vs Concurrent Insert)
   - Add new REQ: REQ-GQL-023 (PhantomPreventionSI) tracking Snapshot Isolation phantom detection & prevention instrumentation.
   - Tests to add:
     - `TestCANARY_REQ_GQL_023_MVCCPhantomAbsenceBaseline` (repeatable read style range scan + concurrent inserts outside snapshot; expect NO phantom rows in committed result set across 25 iterations).
     - `TestCANARY_REQ_GQL_023_MVCCPhantomDetectionHarness` (instrument harness that intentionally disables predicate index pruning to simulate phantom; validates harness can observe anomaly when guard off; guarded behind build flag `mvcc_phantom_harness`).
     - `TestCANARY_REQ_GQL_023_MVCCPredicateLockGranularity` (ensures predicate/range lock (or gap tracking substitute) covers half-open interval [low, high) and blocks mid-range insert until scan commit/finish depending on SI semantics documented §8.x).
   - Benchmarks:
     - `BenchmarkCANARY_REQ_GQL_023_MVCCPhantomPreventionOverheadEnvelope` comparing range scan latency with and without predicate lock/gap tracking enabled (feature flag) over N=48 samples; thresholds: overhead ≤5% mean, CV≤0.22, p95/mean≤2.55.
     - `BenchmarkCANARY_REQ_GQL_023_MVCCGapTrackerMemoryVarianceEnvelope` (Hot Path class) tracking memory consumed by gap tracker across 10k inserts spread over 1k keyspace; thresholds: CV≤0.18, p95/mean≤2.40.
   - Acceptance:
     - All tests pass under default (protection ON) and harness anomaly test only active with `-Dmvcc_phantom_harness`.
     - Overhead envelope passes thresholds; failure prints `VARIANCE_FAIL PhantomPreventionOverhead` with metrics.
     - New CANARY lines (Storage|Engine aspects) with UPDATED=today; BENCHED aspects include overhead + memory variance envelopes.
   - ISO Anchor: §8 (transaction isolation) — paraphrase: SNAPSHOT isolation must present a consistent view preventing phantoms within a statement / explicit snapshot (document any implementation-defined gap lock strategy as I: PhantomGapLockingPolicy).
   - Risks/Mitigations: Potential lock amplification → mitigate via interval merging (coalesce contiguous gaps); fallback eviction if >64 intervals.
   - Owner: mvcc_adv (backup: storage)

## 9. UPCOMING SLICES (Canonical Form)

| Slice | REQ         | Feature/Aspect                         | Type  | New Evidence                                                       | Exit Criteria                                   |
| ----- | ----------- | -------------------------------------- | ----- | ------------------------------------------------------------------ | ----------------------------------------------- |
| S-001 | REQ-GQL-028 | WALPageFlushQueueDepthVarianceEnvelope | BENCH | BenchmarkCANARY_REQ_GQL_028_WALPageFlushQueueDepthVarianceEnvelope | CV≤0.22 p95/mean≤2.4 & strict verify passes     |
| S-002 | REQ-GQL-021 | PathCacheLookup (TESTED)               | TEST  | TestCANARY_REQ_GQL_021_PathCacheLookup                             | Hit ratio metrics & deterministic eviction test |
| S-003 | REQ-GQL-021 | PathCacheLookupVarianceEnvelope        | BENCH | BenchmarkCANARY_REQ_GQL_021_PathCacheLookupVarianceEnvelope        | CV≤0.22 p95/mean≤2.55                           |
| S-004 | REQ-GQL-021 | PlannerCostModelPhaseVarianceEnvelope  | BENCH | BenchmarkCANARY_REQ_GQL_021_PlannerCostModelPhaseVarianceEnvelope  | All phase timings stable (CV≤0.18 hot phases)   |
| S-005 | REQ-GQL-021 | PlannerAdaptiveReplanTrigger (TESTED)  | TEST  | TestCANARY_REQ_GQL_021_AdaptiveReplanTrigger                       | Deterministic replan threshold test             |
| S-006 | REQ-GQL-021 | PlannerAdaptiveReplanVarianceEnvelope  | BENCH | BenchmarkCANARY_REQ_GQL_021_PlannerAdaptiveReplanVarianceEnvelope  | Trigger latency CV≤0.22                         |
| S-007 | REQ-GQL-028 | CorruptRecoveryLatency (optional)      | BENCH | BenchmarkCANARY_REQ_GQL_028_CorruptRecoveryLatency                 | Only if CV>0.20 observed in probe               |
| S-008 | REQ-GQL-004 | PaginationExecutionVarianceEnvelope    | BENCH | BenchmarkCANARY_REQ_GQL_004_PaginationExecutionVarianceEnvelope    | CV≤0.22 p95/mean≤2.55 across page sizes         |
| S-009 | REQ-GQL-021 | PathCacheDegreeBucketUtilization       | BENCH | BenchmarkCANARY_REQ_GQL_021_PathCacheDegreeBucketUtilization       | Collision ratio stable (≥92% unique)            |

## 10. VARIANCE ENVELOPE POLICY (Active)

| Class                                     | Target CV | Max p95/mean | Notes                                  |
| ----------------------------------------- | --------- | ------------ | -------------------------------------- |
| Hot Path (PropertyAccess, Planner phases) | ≤0.18     | ≤2.40        | Re-run 2x if fail then flag regression |
| Storage / WAL Adaptive                    | ≤0.21     | ≤2.55        | Allow moderate I/O jitter              |
| CDC Adaptive / Heuristic                  | ≤0.22     | ≤2.55        | External event timing noise            |
| Graph Analytics (Large)                   | ≤0.23     | ≤2.60        | Iteration count drift acceptable       |

Deviations require explicit doc note + CANARY comment `// VARIANCE_EXCEPTION: reason`.

## 11. AUTOMATION & GOVERNANCE

Pipelines enforce: freshness, variance, over-claim, reality delta, and (soon) slice naming pattern `S-###`. Failure in any gate blocks merge.

New: `scripts/reality_delta_ci.sh` validates `IMPLEMENTATION_REALITY.md` numeric counts against live CANARY scan (`status.json`) and fails on divergence (exit 2 with REALITY_DELTA_FAIL message).

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

- 32 variance envelopes landed; no pending STUB aspects.
- Transitioned from broad algorithm BENCH promotions to subsystem variance stabilization.
- Freshness & reality delta tools reduce governance overhead and prevent drift.

---

End of NEXT (unified slice format). Authoritative evidence: `status.csv` & CANARY lines in source.
