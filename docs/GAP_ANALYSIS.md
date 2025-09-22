# GAP Analysis — geode (CANARY Evidence Driven, Regenerated 2025-09-22)

<!-- STATUS_JSON_SHA256: 0ce6638086e74ab14c3c6e034ecd38e5f5145f755e05cf8d0790642bb854437e -->

## CANARY Evidence (Scanner Lines)

```text
// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Profile Ledger"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering; OWNER=docs; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Freshness Guard"; ASPECT=GovernanceScript; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceScript; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="NEXT Freshness + Single H1"; ASPECT=NextFreshnessGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_NextFreshnessAndSingleH1; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Status JSON Hash Integrity"; ASPECT=StatusJsonHashIntegrity; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_StatusJsonHashIntegrity; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Delta Detection"; ASPECT=DeltaGuardPreview; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceDelta; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Dry Run Wrapper"; ASPECT=DryRunWrapper; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceDryRunWrapper; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Freshness Pre-Warn"; ASPECT=FreshnessPreWarn; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_FreshnessPreWarn; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Aggregate Nightly"; ASPECT=GovernanceAggregate; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceAggregate; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=EstimatorPrimitives; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_075_CostModelSeedBasicEstimates; BENCH=BenchmarkCANARY_REQ_GQL_075_CostModelSeedVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSON; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSON; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=CalibrationFeedback; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelCardinalityCalibrationFeedback; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainProtocolBasic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainProtocolBasic; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainProtocolCalibrated; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainProtocolCalibrated; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONDetailed; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelExplainJSONDetailed; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=CalibrationEntries; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_CostModelCalibrationEntries; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBias; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBias; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_075_AdaptiveEstimatorBiasVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONBiasFactors; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainJSONBiasFactors; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasPersistence; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasPersistence; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=PlannerAdaptiveBiasApplication; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_PlannerAdaptiveBiasApplication; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorDynamicAlpha; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorDynamicAlpha; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainJSONDynamicAlpha; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainJSONDynamicAlpha; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasPersistenceV2; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasPersistenceV2; OWNER=planner; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasClampWarning; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_AdaptiveEstimatorBiasClampWarning; OWNER=planner; UPDATED=2025-09-22
```

This authoritative ledger is generated from `status.json` emitted by:

```bash
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
```

No manual edits should diverge from scanner evidence; contradictions must be resolved by adding/updating CANARY lines or tests/benches. The STATUS_JSON_SHA256 marker above MUST match the current `sha256sum status.json`; validated by governance-check. To refresh the marker after regenerating `status.json` run:

```bash
make canary              # or run the scanner directly
make update-status-hash  # rewrites the STATUS_JSON_SHA256 marker
```

CI SHOULD run `make canary && make update-status-hash` only when accepting an intentional evidence refresh (avoid noisy hash-only commits). The hash guard test (`status_json_hash_integrity.zig`) will fail if the marker drifts.

## 1. Evidence Summary (Derived from latest `status.json`)

| Metric               | Count |
| -------------------- | ----- |
| Total aspects (rows) | 362   |
| BENCHED              | 179   |
| TESTED (non‑BENCHED) | 183   |

| STUB | 0 |
| IMPL (unpromoted) | 0 |
| Coverage (TESTED or BENCHED) | 100% |
| Stale (>60d) | 0 |

Promotion lattice (applied automatically): IMPL + test → TESTED; (IMPL|TESTED) + bench → BENCHED. BENCHED dominates counts. Dates enforced under `--strict` (all current aspects fresh).

_Note_: Table reflects representative multi-aspect density; authoritative enumeration remains `status.csv`. Totals here are subset aggregates (not a full sum of 361) and are for planning focus only. (Corrected 359→361 and 180→182 on 2025-09-22 after fresh scan.)

## 1a. Conformance Profile (ISO/IEC 39075:2024)

| Category     | Minimum Feature                     | Optional Features (Claimed)             | Extensions / Impl-Defined (Flagged)                               | Notes                                                                                     |
| ------------ | ----------------------------------- | --------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Core Query   | RETURN, ORDER BY, basic expressions | UNION / INTERSECT / EXCEPT (GQ03–GQ07)  | US001 (unordered pagination policy), UA005/UA006 (path tie-break) | MATCH partial (patterns, OPTIONAL basic)                                                  |
| Pagination   | ORDER + LIMIT legality enforcement  | OFFSET with stable order only           | US001                                                             | OFFSET without ORDER rejected (policy)                                                    |
| Set Ops      | UNION DISTINCT / ALL                | INTERSECT / EXCEPT DISTINCT             |                                                                   | DISTINCT semantics per binding table equivalence                                          |
| Paths        | Variable-length bounded expand      | Structural PathCache enrichments        | UA005/UA006 deterministic ordering                                | Full MATCH semantics (chained OPTIONAL, property predicates over variable-length) pending |
| Transactions | Snapshot Isolation base             | Phantom prevention instrumentation      | I: PhantomGapLockingPolicy (doc)                                  | SSI upgrade path not complete                                                             |
| Diagnostics  | ISO status precedence               | Multi-diagnostic folding                | CollationBinaryDefault, NullOrderPolicyDefault                    | Additional impl-defined items enumerated                                                  |
| Storage      | WAL + basic recovery                | Variance envelopes for compaction/flush |                                                                   | ARIES physiological redo optimizations pending                                            |
| Security     | Basic TDE key rotation              |                                         |                                                                   | KMS / envelope keys absent                                                                |
| Distributed  | Raft append entries subset          |                                         |                                                                   | Elections, snapshots not implemented                                                      |

## 1b. Per-Requirement Aggregation (High-Density REQs)

| REQ         | Aspects (TESTED) | Aspects (BENCHED) | Total | Notes                                                      |
| ----------- | ---------------- | ----------------- | ----- | ---------------------------------------------------------- |
| REQ-GQL-004 | 1                | 1                 | 2     | Pagination legality + ordered planning variance            |
| REQ-GQL-012 | 5                | 3                 | 8     | Aggregation spill, distinct, decimal, variance envelopes   |
| REQ-GQL-021 | 6                | 12                | 18    | Planner phases, PathCache core + variance, adaptive replan |
| REQ-GQL-028 | 1                | 3                 | 4     | WAL recycle, flush queue depth, latency variance           |
| REQ-GQL-032 | 0                | 1                 | 1     | Constraint performance variance                            |
| REQ-GQL-042 | 0                | 1                 | 1     | CDC adaptive flush                                         |
| REQ-GQL-046 | 0                | 1                 | 1     | TDE key rotation throughput                                |
| REQ-GQL-063 | 0                | 1                 | 1     | Dijkstra benchmark                                         |
| REQ-GQL-065 | 0                | 1                 | 1     | Kruskal benchmark                                          |
| REQ-GQL-067 | 0                | 1                 | 1     | PageRank variance envelope                                 |

_Note_: Table reflects representative multi-aspect density; authoritative enumeration remains `status.csv`. Totals here are subset aggregates (not a full sum of 361) and are for planning focus only.

## 2. Conformance / Scope Snapshot (ISO/IEC 39075:2024)

| Domain                                                 | Status         | Notes / Gaps (ISO anchors)                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------ | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Core Query Parsing (RETURN, ORDER, SET OPS)            | TESTED         | Basic linear composition (§14), ORDER/LIMIT legality (§16.16–16.19) enforced (US001).                                                                                                                                                                                                                                                                                                                                     |
| Set Operations (UNION/INTERSECT/EXCEPT)                | TESTED         | Distinct vs ALL semantics validated; no advanced duplicate elimination costs tracked.                                                                                                                                                                                                                                                                                                                                     |
| Aggregation / GROUP BY                                 | TESTED         | Basic group + SUM; advanced aggregates, HAVING, grouping sets (§14.x) absent.                                                                                                                                                                                                                                                                                                                                             |
| Paths / Pattern Matching                               | PARTIAL        | Variable-length expansion + multi-branch & cycle tie-break (UA005/UA006) TESTED; MATCH label/property predicates + OPTIONAL basic null-preserve TESTED; structural path cache key derivation TESTED; key enrichments (value shape, selectivity, degree bucket placeholder) TESTED; hit/miss + collision variance BENCHED (tightened ≥92% unique); remaining: property predicates over variable-length, OPTIONAL chaining. |
| Transactions (MVCC)                                    | TESTED         | Snapshot isolation; phantom prevention bench; full SSI conflict detection coverage incomplete (§17).                                                                                                                                                                                                                                                                                                                      |
| Diagnostics                                            | BENCHED/TESTED | Folding & precedence mapping (§23) covered; multi-diagnostic precedence verified.                                                                                                                                                                                                                                                                                                                                         |
| Conformance Profile / Flagger                          | PARTIAL        | Profile doc exists; automated flagger outputs limited; implementation-defined catalog incomplete (§24).                                                                                                                                                                                                                                                                                                                   |
| Storage (Pages + WAL + Recovery)                       | TESTED/BENCHED | WAL compaction, adaptive policy, flush, recycle variance guarded; crash recovery basic; no ARIES physiological redo optimizations beyond baseline.                                                                                                                                                                                                                                                                        |
| Distributed / Raft                                     | EMERGING       | AppendEntries success/term mismatch + commit advancement (variance) TESTED/BENCHED; election, membership change, snapshotting absent.                                                                                                                                                                                                                                                                                     |
| Security (TDE)                                         | LIMITED        | Key hierarchy + rotation bench; no KMS / envelope keys; no auditing of key use.                                                                                                                                                                                                                                                                                                                                           |
| Advanced Graph Analytics (Centrality, Flows, Matching) | MIXED          | Several benches (PageRank, Betweenness, etc.); others still STUB-level in algorithm sources though benches exist for higher-level wrappers.                                                                                                                                                                                                                                                                               |

## 3. High-Priority Gaps (Top 8)

| #   | Gap                                                                         | Impact                                    | Required Evidence to Close                                                                                                               | Target Status                     |
| --- | --------------------------------------------------------------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| 1   | Path quantifiers, tie-break, label & property predicates (OPTIONAL pending) | Query correctness on complex patterns     | Tests for bounded variable-length expand, UA005/UA006 tie-break, label+property predicate scan; add OPTIONAL MATCH tests                 | PARTIAL→TESTED (pending OPTIONAL) |
| 2   | Aggregation breadth (COUNT DISTINCT, AVG, HAVING)                           | Conformance breadth (§14)                 | Implement ops + tests & variance bench for hash agg spill                                                                                | BENCHED                           |
| 3   | Raft log replication & commit index advancement                             | Durability & HA claims                    | Implement appendEntries flow + tests (success, term mismatch)                                                                            | TESTED                            |
| 4   | Storage ARIES refinement (physiological redo optimizations)                 | Recovery performance                      | Bench redo scan vs optimized path; add variance guard                                                                                    | BENCHED                           |
| 5   | MVCC phantom prevention robustness (range locks / predicate indexing)       | Isolation correctness (§17)               | Add targeted phantom test matrix & benchmark overhead                                                                                    | TESTED/BENCHED                    |
| 6   | Flagger completeness (impl-defined / dependent items)                       | Conformance transparency (§24)            | Enumerate & test flag outputs for all impl-defined behaviors                                                                             | TESTED                            |
| 7   | Pagination execution streaming variance                                     | Stable user-visible pagination latency    | Implement PULL page streaming variance bench (page_size sweep) with thresholds (CV≤0.22, p95/mean≤2.55)                                  | BENCHED                           |
| 8   | Cost model phase stability (planner)                                        | Future optimization reliability           | Implement PlannerCostModelPhaseVarianceEnvelope bench (landed for planning; extend to sub-phases)                                        | BENCHED                           |
| 9   | Path cache implementation + structural key enrichment completeness          | Performance & repeated pattern efficiency | Cache + lookup + enriched key (value shape, selectivity, degree bucket) + collision tightened (≥92% unique); add utilization stats bench | BENCHED                           |

## 4. Implementation-Defined / Dependent Items (Current Catalog – INCOMPLETE)

| Code                   | Category             | Description                                                            | Evidence                                                   | Status   |
| ---------------------- | -------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------- | -------- |
| US001                  | Policy               | Reject LIMIT/OFFSET without ORDER (default)                            | Tests: TestCANARY_REQ_GQL_004_UnorderedLimitReject         | ENFORCED |
| UA005/UA006            | Tie-break            | Deterministic path expansion tie-break (multi-branch, cycles)          | Multi-branch + cycle determinism + variance bench          | PARTIAL  |
| CollationBinaryDefault | Collation            | Binary collation default (Unicode collation optional feature disabled) | TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering | TESTED   |
| NullOrderPolicyDefault | Null ordering policy | NULLS LAST default ordering policy surfaced via flagger                | TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering | TESTED   |

## 5. Representative Evidence Rows

Below is a concise representative subset (see `status.csv` for the full authoritative table). Rows reflect current BENCHED/TESTED aspects across critical domains.

| Requirement | Feature                        | Aspect                                      | Status  | UPDATED    |
| ----------- | ------------------------------ | ------------------------------------------- | ------- | ---------- |
| REQ-GQL-005 | Binary Protocol Core           | Wire                                        | TESTED  | 2025-09-20 |
| REQ-GQL-010 | Diagnostics Precedence         | Engine                                      | BENCHED | 2025-09-20 |
| REQ-GQL-013 | Txn Conflict Matrix            | Engine                                      | BENCHED | 2025-09-20 |
| REQ-GQL-016 | Path Expand Breadth            | Planner                                     | BENCHED | 2025-09-20 |
| REQ-GQL-021 | Planner Rewrite Pass           | Planner                                     | BENCHED | 2025-09-20 |
| REQ-GQL-021 | Query Planner                  | PlannerRewritePreValidationTiming           | TESTED  | 2025-09-21 |
| REQ-GQL-021 | Query Planner                  | PlannerGroupValidationTiming                | TESTED  | 2025-09-21 |
| REQ-GQL-021 | PathCache                      | PathCacheStructuralKeySelectivityEnrichment | TESTED  | 2025-09-21 |
| REQ-GQL-004 | Pagination                     | PaginationOrderedVarianceEnvelope           | BENCHED | 2025-09-21 |
| REQ-GQL-028 | WAL Segment Recycle            | WALSegmentRecycleLatencyVarianceEnvelope    | BENCHED | 2025-09-21 |
| REQ-GQL-028 | WAL Page Flush Queue Depth     | WALPageFlushQueueDepthVarianceEnvelope      | BENCHED | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDistinctSpillPersistence             | TESTED  | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDecimalSpillMerge                    | TESTED  | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDistinctSpillEvictVarianceEnvelope   | BENCHED | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDistinctSpillAccurateMerge           | TESTED  | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDecimalEarlyState                    | TESTED  | 2025-09-21 |
| REQ-GQL-012 | GROUP BY/Aggregation           | HashAggDistinctMergeVarianceEnvelope        | BENCHED | 2025-09-21 |
| REQ-GQL-021 | PathCache                      | PathCacheLookup                             | TESTED  | 2025-09-21 |
| REQ-GQL-032 | Schema Constraints Performance | ConstraintPerf                              | BENCHED | 2025-09-20 |
| REQ-GQL-042 | CDC Adaptive Flush             | AdaptiveFlush                               | BENCHED | 2025-09-20 |
| REQ-GQL-046 | TDE Key Rotation Throughput    | Storage                                     | BENCHED | 2025-09-20 |
| REQ-GQL-060 | Core Graph Builders            | ConcurrencySafeGraph                        | TESTED  | 2025-09-20 |
| REQ-GQL-063 | Dijkstra                       | Dijkstra                                    | BENCHED | 2025-09-20 |
| REQ-GQL-064 | Biconnected Components         | BiconnectedComponents                       | BENCHED | 2025-09-20 |
| REQ-GQL-065 | Kruskal                        | Kruskal                                     | BENCHED | 2025-09-21 |
| REQ-GQL-067 | PageRank                       | PageRankVarianceEnvelope                    | BENCHED | 2025-09-20 |

## 6. Closing Plan (Rolling)

| Slice | Focus                                  | Exit Criteria                                                          | Owner   | Planned Evidence                                                   |
| ----- | -------------------------------------- | ---------------------------------------------------------------------- | ------- | ------------------------------------------------------------------ |
| S1    | Path Quantifiers & Tie-break Hardening | Tests for bounded variable expand; deterministic ordering multi-branch | planner | New tests + bench (PathExpansionHeuristicVarianceEnvelope already) |
| S2    | Aggregation Completeness               | COUNT DISTINCT, AVG, HAVING tests; spill guard bench                   | engine  | New groupby tests + HashAggVarianceEnvelope                        |
| S3    | Raft Replication Minimum Viable        | AppendEntries success/failure tests; leader commit advancement         | dist    | RaftReplicationTests + term mismatch test                          |
| S4    | Cost Model Phase Stability             | Introduce PlannerCostModelPhaseVarianceEnvelope                        | planner | New variance bench added                                           |
| S5    | Path Cache Implementation              | Functional cache hits/misses + lookup variance bench                   | engine  | PathCache tests + PathCacheLookupVarianceEnvelope                  |
| S6    | ARIES Redo Optimization                | Redo scan optimized vs baseline; variance bench                        | storage | RedoOptimizedBench + time delta assertion                          |
| S7    | Flagger Completeness                   | All impl-defined items enumerated & tests verify presence              | docs    | FlaggerOutputTests                                                 |

## 7. Regeneration & Integrity

Regenerate anytime after code changes (CI also runs `make governance-check` which validates NEXT freshness & hash integrity):

```bash
go build -o ./bin/canaryscan ./tools/canaryscan
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
```

If `--verify` fails: address stale dates (>60d), missing evidence, or over-claims then re-run. Do NOT hand-edit counts.

## 8. Legend

Status: TESTED (evidence via tests) | BENCHED (has benchmark) | STUB (placeholder) | IMPL (implementation sans test) — last two must remain at 0 under policy.

---

<!-- Duplicate legacy sections pruned to satisfy single-heading policy (MD024). -->

<!-- Legacy duplicate section removed; original 2025-09-21 snapshot was pruned to avoid duplicate headings. -->

This authoritative ledger is generated from `status.json` emitted by:

```bash
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
```

No manual edits should diverge from scanner evidence; contradictions must be resolved by adding/updating CANARY lines or tests/benches.

## 1. Evidence Summary

| Metric               | Count |
| -------------------- | ----- |
| Total aspects (rows) | 359   |
| BENCHED              | 179   |
| TESTED (non‑BENCHED) | 180   |

| STUB | 0 |
| IMPL (unpromoted) | 0 |
| Coverage (TESTED or BENCHED) | 100% |
| Stale (>60d) | 0 |

Promotion lattice (applied automatically): IMPL + test → TESTED; (IMPL|TESTED) + bench → BENCHED. BENCHED dominates counts. Dates enforced under `--strict` (all current aspects fresh).
