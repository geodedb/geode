# NEXT — Execution Plan (Slice Ledger) — Regenerated 2025-09-22

## 0. WHY (Strategic Intent)

Sustain fully evidence-backed GQL conformance while hardening runtime determinism and storage durability. Focus horizon: (a) stabilize variance of latency‑sensitive subsystems (WAL, planner, CDC, MVCC), (b) introduce missing cache + queue depth observability, (c) reduce future drift risk via freshness & delta tooling, and (d) prepare path for multi-tenant + adaptive planner features without re‑architecting later.

## 1. OBJECTIVES (Bounded)

Focus this period: deterministic planner phase timing, pagination execution stability, ARIES redo optimization path, phantom prevention robustness, and PathCache utilization enrichment. All slices below are independently mergeable and MUST land with CANARY evidence.

## 2. GLOBAL ACCEPTANCE (Machine-Checkable)

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

## 6. CURRENT EVIDENCE SNAPSHOT (Condensed)

From latest scan (see `status.json`) plus newly added execution pagination, degree bucket utilization, planner pre/group validation, pagination prefetch, projection prune variance benches, real degree bucket discrimination test, physiological redo optimization variance, MVCC phantom prevention predicate range detection & range tracker (REQ-GQL-023), cost-based plan enumeration & calibration (REQ-GQL-024), variable-length path property predicate execution (REQ-GQL-017 new aspect), write skew detection (REQ-GQL-025), redo optimization delta variance (REQ-GQL-022 new aspect), recovery corrupt page latency variance, and flagger completeness (REQ-GQL-026):

- BENCHED aspects: 199 (new strategic additions: AdvancedCostModelCalibrationVarianceEnvelope, MvRefreshLatencyVarianceEnvelope, InvertedIndexQueryLatencyVarianceEnvelope plus earlier RangeTrackerOverheadVarianceEnvelope, CorruptPageRecoveryLatencyVarianceEnvelope, PlannerAdaptiveReplanRefinementVarianceEnvelope, PathCacheEntropyVarianceEnvelope, RedoOptimizationDeltaVarianceEnvelope; retains prior PlanEnumerationVarianceEnvelope, PathVariableLengthPropertyPredicateVarianceEnvelope, WriteSkewVarianceEnvelope, FlaggerGenerationVarianceEnvelope, PlanSelectionVarianceEnvelope, PlanEnumerationCostPruneVarianceEnvelope, PlanSelectionPipelineVarianceEnvelope, PlanCostModelVarianceEnvelope, PlanJoinReorderVarianceEnvelope)
- TESTED (non-BENCHED): 202 (added: AdvancedCostModel, RefreshScheduler, InvertedIndexCore along with previously noted planner & path cache timing/enrichment tests)
- STUB/IMPL: 0
- Variance Guards Landed: 70+ (all passing thresholds; new guards include AdvancedCostModelCalibrationVarianceEnvelope, MvRefreshLatencyVarianceEnvelope, InvertedIndexQueryLatencyVarianceEnvelope)

Representative variance envelopes (all BENCHED): WALFlushBatch, WALSegmentRecycleLatency, WALPageFlushQueueDepthVarianceEnvelope, PlannerRewritePass, PlannerCardinalityEstimate, PlannerCostModelPhaseVarianceEnvelope, PlannerPreValidationVarianceEnvelope, PlannerGroupValidationVarianceEnvelope, PlannerProjectionPruneVarianceEnvelope, PaginationOrderedVarianceEnvelope, PaginationExecutionVarianceEnvelope, PaginationPrefetchVarianceEnvelope, PhysiologicalRedoVarianceEnvelope, RedoOptimizationDeltaVariance, CorruptPageRecoveryLatencyVarianceEnvelope, PlanEnumerationVarianceEnvelope, PlanSelectionVarianceEnvelope, PlanEnumerationCostPruneVarianceEnvelope, PathVariableLengthPropertyPredicateVarianceEnvelope, WriteSkewVarianceEnvelope, FlaggerGenerationVarianceEnvelope, SetOpDistinctDedup, QueryPlanCacheEvict, MVCCVersionPrune, CDCAdaptiveHeuristicsDecisionLatency, ConstraintPerfVariance, PathExpansionHeuristic, PathCacheHitMissVarianceEnvelope, PathCacheStructuralKeyCollisionEnvelope, PathCacheStructuralKeyCollisionTightened, PathCacheDegreeBucketUtilizationVarianceEnvelope, RangeTrackerOverheadVarianceEnvelope.

Automation Update: Added NEXT plan freshness guard script `scripts/next_freshness_check.zig` (aspect NextPlanFreshnessGuard) enforcing Generated date ≤1 day old.

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

## 7. SLICES (Canonical Format)

Each slice section below follows: ID, WHY, WHAT, ACCEPTANCE, ISO, DEPS, SCOPE, DRI, RISK.

### Slice S-000: QUIC Multiplexed Transport (REQ-GQL-074)

WHY: Establish low-latency, multiplexed session transport (QUIC) to reduce head-of-line blocking and enable future distributed features (Raft over QUIC, multi-tenant isolation) while measuring encode/decode latency variance.
WHAT: Implement minimal QUIC listener shim (feature-flagged), frame mux/demux, connection pool abstraction, and latency probe harness capturing per-frame encode/decode + round-trip metrics; add stub fallback to TCP when disabled.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_074_QUICMultiplexingBasic` (establish, send HELLO, RUN_GQL echo, close) – ensures deterministic frame sequencing.
- Bench: `BenchmarkCANARY_REQ_GQL_074_QuicFrameLatencyVarianceEnvelope` (CV≤0.22, p95/mean≤2.55) over N≥48 samples; collects encode_ns, decode_ns, rtt_ns.
- CANARY aspects added: QUICMultiplexing (IMPL→TESTED), QuicFrameLatencyVarianceEnvelope (BENCHED).
- Flagger emits `TransportQUICExperimental` when enabled; README updated with experimental notice.
- Governance passes (`zig run scripts/governance_ci.zig`).

ISO: §14 execution environment (transport not normative) – aligns with diagnostics & framing semantics; no language semantics change.
DEPS: Existing binary protocol framing; optional dependency on system QUIC library (stubbed internal implementation only in this slice).
SCOPE IN: Listener shim, mux/demux abstraction, latency harness, flagger hook.
SCOPE OUT: Congestion control tuning, TLS cert rotation automation, distributed consensus integration.
DRI: wire (backup: networking).
RISK: Medium (timing noise, potential flakiness) – mitigate with warm-up & median-of-window sampling.

### Slice S-000A: Cost Model Phase & Advanced Enumeration Seed (REQ-GQL-075)

WHY: Provide foundation for cost-based optimization (CBO) by introducing calibrated cardinality & cost factor aggregation plus enumeration skeleton necessary for future join reordering and access path selection.
WHAT: Add `cost_model.zig` with factor registry (row_count, sel_factor, cpu_cost, io_cost), introduce enumeration driver stub producing logical alternatives (baseline + swapped join order for 2-way joins), instrument calibration harness persisting factor snapshots (JSON) for variance comparison.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_075_AdvancedCostModelFactors` (ensures factors recorded and non-zero for sample query set).
- Bench: `BenchmarkCANARY_REQ_GQL_075_CostModelCalibrationVarianceEnvelope` (CV≤0.20, p95/mean≤2.50 for calibration time); failure code `VARIANCE_FAIL_COST_CAL`.
- CANARY aspects: AdvancedCostModel (IMPL→TESTED), CostModelCalibrationVarianceEnvelope (BENCHED), JoinEnumerationSeed (IMPL) – enumeration still IMPL until promotion slice.
- Stores calibration snapshot under `benchmarks/cost_model/last.json` (git-ignored) and delta compares to previous run emitting drift report (non-blocking unless >15% delta on any factor weight).

ISO: §14 (optimization not normative) – internal implementation-defined behavior; factors flagged via Flagger `CostModelExperimental`.
DEPS: Planner rewrite + phase timers.
SCOPE IN: Factor registry, enumeration seed (2-way), variance bench, snapshot delta.
SCOPE OUT: Full n-way join enumeration, histogram stats, selectivity estimation algorithms.
DRI: planner.
RISK: Low-Medium (overfitting to micro workload) – mitigate by using diverse sample queries & bounding factor drift.

### Slice S-000B: Materialized View Refresh Scheduler (REQ-GQL-076)

WHY: Enable foundational incremental view maintenance path and refresh cadence scheduling for future analytical acceleration and derived graph projections (pattern caches, aggregation rollups).
WHAT: Introduce MV catalog (in-memory), view definition registration (pattern + projection list), on-demand REFRESH command stub, and scheduled refresh loop (interval-based) with execution timing variance guard.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_076_RefreshSchedulerBasic` (register, refresh, detect updated timestamp monotonicity).
- Bench: `BenchmarkCANARY_REQ_GQL_076_RefreshSchedulerVarianceEnvelope` (CV≤0.22, p95/mean≤2.55 for refresh execution over N≥40 samples of trivial view).
- CANARY aspects: RefreshScheduler (IMPL→TESTED), RefreshSchedulerVarianceEnvelope (BENCHED).
- Flagger emits `MaterializedViewsExperimental` when any MV registered.
- README updated with experimental note & no persistence guarantee disclaimer.

ISO: §14 linear composition semantics preserved; MV layer is implementation-defined optimization.
DEPS: Executor projection + plan reuse stubs.
SCOPE IN: In-memory MV catalog, interval scheduler, refresh execution wrapper, variance bench.
SCOPE OUT: Incremental delta maintenance, dependency graph, persistence, query rewrite to use MVs.
DRI: engine.
RISK: Low (scoped to in-memory scheduling) – mitigate with small code surface & feature flag guard.

### Slice S-000C: Inverted Index Core (Full-Text Search Skeleton) (REQ-GQL-077)

WHY: Provide search-oriented access path scaffold (tokenization + postings) enabling future text predicates and ranking integration without coupling to primary storage layout.
WHAT: Implement minimal tokenizer (whitespace + lowercase), postings builder (in-memory), index build & simple term query executor returning node ids; add variance bench for build & query latency across sample documents; integrate flagger `FullTextSearchExperimental`.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_077_InvertedIndexCoreBasic` (index 5 docs, query yields expected doc id set; deterministic ordering).
- Bench: `BenchmarkCANARY_REQ_GQL_077_InvertedIndexBuildQueryVarianceEnvelope` (build/query CV≤0.22, p95/mean≤2.55; prints metrics on failure with `VARIANCE_FAIL_FTS`).
- CANARY aspects added: InvertedIndexCore (IMPL→TESTED), InvertedIndexVarianceEnvelope (BENCHED).
- README & GAP_ANALYSIS updated to list feature under experimental once promoted.

ISO: Not normative (implementation-defined optimization / access path) – must not alter query semantics; only adds optional predicate path in future.
DEPS: None (standalone module + test harness).
SCOPE IN: Tokenizer, postings structure, build & query API, variance bench.
SCOPE OUT: Ranking (BM25), phrase queries, positional postings, persistence, concurrency.
DRI: engine.
RISK: Low (in-memory only) – mitigate with bounded test corpus and deterministic token ordering.

### Slice S-001: Pagination Execution Variance (REQ-GQL-004)

WHY: Ensure stable latency for streaming page pulls; complements existing planning variance envelope.
WHAT: Implement execution harness timing page pulls across page_size sweep {32,64,128,256}; add benchmark + test validating ordered emission semantics.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_004_PaginationExecutionOrdering`
- Bench: `BenchmarkCANARY_REQ_GQL_004_PaginationExecutionVarianceEnvelope` (CV≤0.22, p95/mean≤2.55)
- CANARY lines added (Planner|Engine aspects) with UPDATED=today
- Scanner strict verify passes; no increase in mean >3% vs planning baseline

ISO: §16.16–16.19 (pagination legality & ordering semantics)
DEPS: Existing pagination operator & ordered variance bench
SCOPE IN: Execution timing harness, variance envelope, ordering test
SCOPE OUT: Adaptive prefetch heuristics
DRI: planner (backup: engine)
RISK: Moderate (timing noise) — mitigated by warm-up + median-of-N sampling

### Slice S-002: Planner Group Validation Timing Guard (REQ-GQL-021)

WHY: Add micro-phase determinism visibility; detect regressions in validation cost.
WHAT: Insert timing hooks around group validation; add variance envelope bench.
ACCEPTANCE:

- Bench: `BenchmarkCANARY_REQ_GQL_021_PlannerGroupValidationVarianceEnvelope` (CV≤0.18, p95/mean≤2.40)
- CANARY aspect: PlannerGroupValidationVarianceEnvelope BENCHED

ISO: §14 (query composition) — group semantics baseline
DEPS: Existing phase timer infra
SCOPE OUT: Full cost model enumeration
DRI: planner
RISK: Low (hooks only)

### Slice S-003: ARIES Physiological Redo Optimization (REQ-GQL-022)

WHY: Reduce redo recovery latency & variance; foundational for durability claims.
WHAT: Add optimized page-oriented redo scan path; differential benchmarking vs baseline logical replay.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_022_PhysiologicalRedoCorrectness`
- Bench: `BenchmarkCANARY_REQ_GQL_022_PhysiologicalRedoVarianceEnvelope` (CV≤0.18, p95/mean≤2.30; mean speedup ≥1.15x baseline)
- CANARY aspects: PhysiologicalRedo IMPL→TESTED; PhysiologicalRedoVarianceEnvelope BENCHED

ISO: §8 (transaction recovery) paraphrased for durability semantics
DEPS: WAL segment iteration API
SCOPE OUT: Parallel redo, prefetch I/O
DRI: storage
RISK: Medium (log record edge cases) — mitigate via dual-apply validation harness

### Slice S-004: MVCC Phantom Prevention Stress (REQ-GQL-023)

WHY: Validate absence of phantoms & bound overhead of range tracking.
WHAT: Add range scan vs concurrent insert tests; overhead + memory variance benches.
ACCEPTANCE:

- Tests: `TestCANARY_REQ_GQL_023_MVCCPhantomAbsenceBaseline`, `...PredicateLockGranularity`
- Bench: `BenchmarkCANARY_REQ_GQL_023_MVCCPhantomPreventionOverheadEnvelope` (overhead ≤5%)
- Bench: `BenchmarkCANARY_REQ_GQL_023_MVCCGapTrackerMemoryVarianceEnvelope` (CV≤0.18)
- CANARY aspects promoted to TESTED/BENCHED

ISO: §8 (isolation) phantom prevention paraphrase
DEPS: Predicate/range tracker, feature flag harness
SCOPE OUT: SSI full serialization upgrade
DRI: mvcc_adv (backup: storage)
RISK: Medium (test flakiness) — mitigate with deterministic seed & retry-on-first-fail

### Slice S-005: PathCache Degree Bucket Utilization (REQ-GQL-021)

WHY: Confirm structural key enrichment yields utilization & reduced collision.
WHAT: Add utilization stats gathering + variance envelope on hit/miss & bucket distribution.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_021_PathCacheDegreeBucketUtilization`
- Bench: `BenchmarkCANARY_REQ_GQL_021_PathCacheDegreeBucketUtilizationVarianceEnvelope` (unique key ratio ≥0.92, CV≤0.22)
- CANARY aspect BENCHED

ISO: §14 (execution model) context for path expansion caching
DEPS: Existing PathCache instrumentation
SCOPE OUT: Adaptive eviction scoring
DRI: planner
RISK: Low

### Slice S-006: Adaptive Replan Threshold Autotune (REQ-GQL-021)

WHY: Stabilize replan triggers under workload shifts.
WHAT: Implement rolling window variance-based threshold tuner + determinism test.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_021_AdaptiveReplanAutotune`
- Bench: `BenchmarkCANARY_REQ_GQL_021_AdaptiveReplanAutotuneVarianceEnvelope` (post-convergence CV≤0.20)
- No regression in baseline replan overhead (>2% change aborts)

ISO: §14 planning adaptability (paraphrased)
DEPS: Existing replan trigger metrics
DRI: planner
RISK: Medium (overfitting) — mitigate with min/max clamp & hysteresis

### Slice S-007: Flagger Completeness & Impl-Defined Catalog Expansion (REQ-GQL-024)

WHY: Conformance transparency; ensure all impl-defined/ dependent behaviors surfaced.
WHAT: Enumerate remaining items (phantom gap policy, zero-length path inclusion, null ordering) and tests verifying flag presence.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_024_FlaggerCompleteness`
- CANARY aspects updated to TESTED with UPDATED=today

ISO: §24 conformance profile & impl-defined catalog
DEPS: Existing flagger emission pipeline
DRI: docs (backup: engine)
RISK: Low

### Slice S-008: Governance Enhancements (REQ-GQL-010)

WHY: Prevent multi-doc drift (NEXT, GAP_ANALYSIS, IMPLEMENTATION_REALITY, README) beyond single run.
WHAT: Extend governance script to validate NEXT slice dates & per-REQ aggregation table freshness.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_010_GovernanceMultiDocFreshness`
- Added step in `governance_ci.zig` capturing NEXT freshness & per-REQ totals

ISO: §24 evidence traceability support
DEPS: Existing governance_ci infrastructure
DRI: tooling
RISK: Low

### Slice S-009: Redo Optimization Delta Variance Tightening (REQ-GQL-022)

WHY: Detect regressions after initial physiological redo landing.
WHAT: Add delta variance envelope comparing optimized vs baseline (wall-clock & I/O count).
ACCEPTANCE:

- Bench: `BenchmarkCANARY_REQ_GQL_022_RedoOptimizationDeltaVarianceEnvelope` (delta CV≤0.18, p95/mean≤2.40)
- Fails with clear `VARIANCE_FAIL_REDO_DELTA` code when outside bounds

ISO: §8 durability performance (paraphrased)
DEPS: Slice S-003 completion
DRI: storage
RISK: Low incremental

### Slice S-010: COUNT DISTINCT Spill Phase-2 (REQ-GQL-012)

WHY: Complete aggregation spill pipeline for high-cardinality correctness.
WHAT: Implement eviction + merge-on-read logic with serialization & variance guard.
ACCEPTANCE:

- Test: `TestCANARY_REQ_GQL_012_HashAggSpillEvict`
- Bench: `BenchmarkCANARY_REQ_GQL_012_HashAggSpillEvictVarianceEnvelope` (CV≤0.22, p95/mean≤2.55)
- Promotion of SpillEvict aspects to TESTED/BENCHED

ISO: §14 aggregation semantics (resource management)
DEPS: Existing spill flag groundwork
DRI: engine
RISK: Medium (I/O overhead) — mitigate via segmented iterator reuse

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

## 8. UPCOMING (Deferred / Watch List)

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

## 9. VARIANCE ENVELOPE POLICY (Active)

| Class                                     | Target CV | Max p95/mean | Notes                                  |
| ----------------------------------------- | --------- | ------------ | -------------------------------------- |
| Hot Path (PropertyAccess, Planner phases) | ≤0.18     | ≤2.40        | Re-run 2x if fail then flag regression |
| Storage / WAL Adaptive                    | ≤0.21     | ≤2.55        | Allow moderate I/O jitter              |
| CDC Adaptive / Heuristic                  | ≤0.22     | ≤2.55        | External event timing noise            |
| Graph Analytics (Large)                   | ≤0.23     | ≤2.60        | Iteration count drift acceptable       |

Deviations require explicit doc note + CANARY comment `// VARIANCE_EXCEPTION: reason`.

## 10. AUTOMATION & GOVERNANCE

Pipelines enforce: freshness, variance, over-claim, reality delta, and (soon) slice naming pattern `S-###`. Failure in any gate blocks merge.

New: `scripts/reality_delta_ci.sh` validates `IMPLEMENTATION_REALITY.md` numeric counts against live CANARY scan (`status.json`) and fails on divergence (exit 2 with REALITY_DELTA_FAIL message).

Combined governance check (freshness + strict canary verify) can be invoked locally via:

```bash
make governance-check
# or
zig run scripts/governance_ci.zig
```

Outputs JSON summary line:

```json
{
  "type": "governance_summary",
  "status": "success",
  "steps": [
    { "name": "freshness", "ok": true },
    { "name": "canary_verify", "ok": true }
  ]
}
```

Status values:

- `success`: All governance steps passed.
- `failure`: Policy violation (e.g., stale NEXT, verification mismatch) – exit code 2.
- `err`: Execution error (tool missing / internal issue) – non‑2 non‑zero exit code.

CI SHOULD gate merges on `make governance-check` to preempt stale plan or GAP_ANALYSIS drift.

## 11. PR CHECKLIST (Operational)

1. New CANARY line added (diff shows UPDATED today).
2. Tests/benches green locally: `zig build test`.
3. Run scanner verify: `./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict`.
4. For BENCH promotions attach variance metrics (mean, cv, p95/mean).
5. No modification of unrelated UPDATED fields.

## 12. COMMANDS (Reference)

```bash
go build -o ./bin/canaryscan ./tools/canaryscan
./bin/canaryscan --root . --out status.json --csv status.csv
./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict
```

## 13. APPENDIX (Historical Context Condensed)

- 32 variance envelopes landed; no pending STUB aspects.
- Transitioned from broad algorithm BENCH promotions to subsystem variance stabilization.
- Freshness & reality delta tools reduce governance overhead and prevent drift.

---

End of NEXT (unified slice format). Authoritative evidence: `status.csv` & CANARY lines in source.
