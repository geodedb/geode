# NEXT — Concise Forward Backlog — Regenerated 2025-09-22

Purpose: Maintain a minimal, actionable slice backlog strictly limited to forward work. Historical landed content lives in `GAP_ANALYSIS.md` & `IMPLEMENTATION_REALITY.md`.

## 1. Global Acceptance (Machine Enforced)

1. Exactly one aspect promotion per slice (TESTED or BENCHED).
2. New or promoted aspect must add a CANARY line with `UPDATED`=today.
3. All slices must pass `./bin/canaryscan --root . --verify docs/GAP_ANALYSIS.md --strict` prior to merge.
4. Variance benches use class thresholds (Hot≤0.18, Storage≤0.21, General≤0.22, GraphAnalytics≤0.23 CV; p95/mean caps 2.40–2.60) or add `// VARIANCE_EXCEPTION:`.
5. Bench failures emit `VARIANCE_FAIL_<TOKEN>`.
6. Freshness: regenerated within 24h (governance check).

## 2. Active Backlog (Actionable Only)

| Slice | REQ         | Title                              | WHY (Short)                           | Acceptance (Abbrev)                              | Class    | Owner     |
| ----- | ----------- | ---------------------------------- | ------------------------------------- | ------------------------------------------------ | -------- | --------- |
| S-015 | REQ-GQL-021 | PathCache Degree Utilization       | Improve cache discrimination          | Test+Bench (unique≥0.92, CV≤0.22)                | BENCH    | planner   |
| S-016 | REQ-GQL-022 | Redo Optimization Delta Tightening | Guard redo speedup stability          | Bench (speedup CV≤0.18, p95/mean≤1.35, mean≥1.0) | BENCH    | storage   |
| S-017 | REQ-GQL-023 | MVCC Phantom Prevention Stress     | Ensure no phantoms; quantify overhead | Tests (absence); Benches (overhead≤5%, CV≤0.22)  | TEST/BEN | mvcc      |
| S-018 | REQ-GQL-004 | Pagination Execution Streaming     | Stable page emission latency          | Bench (CV≤0.22)+ordering test                    | BENCH    | planner   |
| S-019 | REQ-GQL-021 | Adaptive Replan Autotune           | Stabilize replan triggers             | Test+Bench (post-conv CV≤0.20)                   | TEST/BEN | planner   |
| S-021 | REQ-GQL-024 | Flagger Completeness Expansion     | Surface impl-defined behaviors        | Test (all flags present)                         | TEST     | docs      |
| S-022 | REQ-GQL-012 | COUNT DISTINCT Spill Evict/Merge   | Complete agg spill pipeline           | Test+Bench (CV≤0.22)                             | TEST/BEN | engine    |
| S-023 | REQ-GQL-074 | QUIC Multiplexed Transport         | Reduce HOL blocking / future distrib  | Test+Bench (CV≤0.22)                             | TEST/BEN | wire      |
| S-024 | REQ-GQL-075 | Cost Model Enumeration Seed        | Enable future CBO                     | Test+Bench (CV≤0.20)                             | TEST/BEN | planner   |
| S-025 | REQ-GQL-076 | MV Refresh Scheduler               | Derived projection foundation         | Test+Bench (CV≤0.22)                             | TEST/BEN | engine    |
| S-026 | REQ-GQL-077 | Inverted Index Core                | Future text predicate path            | Test+Bench (CV≤0.22)                             | TEST/BEN | engine    |
| S-027 | REQ-GQL-078 | Multi-Leader Consensus Scaffold    | Sharded replication groundwork        | Test+Bench (CV≤0.22)                             | TEST/BEN | consensus |
| S-028 | REQ-GQL-079 | GPU Operator Kernel Foundations    | Acceleration feasibility              | Test+Bench (GPU≤1.10x CPU mean, CV≤0.23)         | TEST/BEN | accel     |
| S-029 | REQ-GQL-080 | Cross-Shard 2PC Executor           | Distributed atomic commit             | Tests+Bench (CV≤0.22)                            | TEST/BEN | txn       |
| S-030 | REQ-GQL-081 | Multi-Key TDE Rotation Scheduling  | Rolling encryption maintenance        | Test+Bench (throughput≥0.90 baseline, CV≤0.22)   | TEST/BEN | security  |

## 3. Variance Policy (Extract)

Hot≤0.18 p95/mean≤2.40; Storage/WAL≤0.21; General≤0.22; GraphAnalytics≤0.23 (p95/mean≤2.60). Exceptions require inline justification.

## 4. Governance Hooks

Run: `make governance-check` (freshness + strict verify). Stale (>24h) ⇒ fail.
Nightly (non-blocking) summary: `make governance-aggregate` emits combined delta + freshness pre-warn + dry-run JSON for observability.

## 5. Appendix (Pointer Only)

Historical slice details live in `docs/GAP_ANALYSIS.md` & `docs/IMPLEMENTATION_REALITY.md`.

## 6. Maintenance / Governance (De-Prioritized)

The following slice has been moved out of the feature-priority backlog. Governance freshness is now considered baseline hygiene, not a competitive differentiator; feature delivery (planner, storage, distributed, acceleration) takes precedence for the current cycle.

| Slice | REQ         | Title                          | Rationale (Why De-Prioritized)            | Current Evidence |
| ----- | ----------- | ------------------------------ | ----------------------------------------- | ---------------- |
| S-020 | REQ-GQL-010 | Governance Multi-Doc Freshness | Mechanism landed & enforced automatically | TEST (CANARY)    |

// CANARY: REQ=REQ-GQL-010; FEATURE="NEXT Backlog Accuracy"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceMultiDocFreshness; OWNER=tooling; UPDATED=2025-09-22
