# GAP Analysis — geode (CANARY Evidence Driven, Regenerated 2025-09-21)

This authoritative ledger is generated from `status.json` emitted by:

```bash
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
```

No manual edits should diverge from scanner evidence; contradictions must be resolved by adding/updating CANARY lines or tests/benches.

## 1. Evidence Summary

| Metric               | Count |
| -------------------- | ----- |
| Total aspects (rows) | 305   |
| BENCHED              | 150   |
| TESTED (non‑BENCHED) | 155   |

| STUB | 0 |
| IMPL (unpromoted) | 0 |
| Coverage (TESTED or BENCHED) | 100% |
| Stale (>60d) | 0 |

Promotion lattice (applied automatically): IMPL + test → TESTED; (IMPL|TESTED) + bench → BENCHED. BENCHED dominates counts. Dates enforced under `--strict` (all current aspects fresh).

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

Regenerate anytime after code changes:

```bash
go build -o ./bin/canaryscan ./tools/canaryscan
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict
```

If `--verify` fails: address stale dates (>60d), missing evidence, or over-claims then re-run. Do NOT hand-edit counts.

## 8. Legend

Status: TESTED (evidence via tests) | BENCHED (has benchmark) | STUB (placeholder) | IMPL (implementation sans test) — last two must remain at 0 under policy.

---

End of generated ledger (representative subset only; authoritative source: `status.csv`).

## 9. Focus Areas (No Remaining STUB Aspects)

All previously identified STUB gaps have been closed (each aspect now at least TESTED). Focus shifts from gap closure to:

1. Performance deepening for high-impact BENCHED aspects (identify variance & regression guards).
2. Freshness monitoring (ensure UPDATED stays <60d; automate reminder if >45d).
3. Expansion of analytics (GreyCardinal) & advanced MVCC heuristics with micro-bench coverage.
4. Protocol hardening under adverse network simulations (planned slices tracked in NEXT.md).

## 10. Summary Statistics (Derived from status.csv)

-- Total aspect rows (status.csv): 305
-- BENCHED: 150

- TESTED (non-BENCHED): 155
- STUB / IMPL remaining: 0
- Effective coverage: 100%

Regenerate to refresh: `./bin/canaryscan --root . --out status.json --csv status.csv` then `./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict`.
