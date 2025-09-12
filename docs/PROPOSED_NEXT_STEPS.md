# Proposed Next Steps (Post Phase 3 Hardening)

1. WAL Fast Redo Index (COMPLETED)

   - Sparse pageLSN index built during recovery scan (fast-seek) enabling binary skip.
   - Next: expose skip% metric & add test (>60% synthetic pattern) — remaining.

2. Recovery Fuzz Scaling (COMPLETED phase 1)

   - Implemented 1..1000 seeds with truncation & checksum corruption.
   - Next: optional scale to 5k (runtime gate) + richer invariants.

3. MVCC Delete Lifecycle (COMPLETED initial)

   - delete_ts + rollback undo + visibility test implemented.
   - Next: GC of obsolete versions & snapshot epoch pinning.

4. Index Stats Maintenance (COMPLETED hooks; metadata inline pending)

   - Row count & basic distinct heuristic hooks in place.
   - Next: inline index_name/selectivity (remove IndexMeta stub) + estimator refinement.

5. Planner Cost Model Evolution (PENDING)

   - To follow after selectivity refinement & skip% instrumentation.

6. Doc Sync CI Gate (COMPLETED uniqueness phase / CI wiring pending)

   - Uniqueness enforcement added; action wiring next.

7. Peak Attribution Accuracy Test (COMPLETED ordering; real allocator pending)

   - Ordering test added. Next: integrate real allocator counters.

8. Page Checksum Diagnostic (CODE ADDED; propagation pending)

   - Diagnostic enum present. Next: map recovery error → emitted diagnostic.

9. WAL Segment Compaction (PENDING)

   - Awaiting stable checkpoint & skip% metrics.

10. Adaptive Re-optimization Prototype (PENDING)

- Depends on baseline cost model.

11. Path Expansion Operator Skeleton (PENDING)

- Will integrate after index metadata stabilization.

12. Encryption Design Doc (PENDING)

- To draft post durability & MVCC GC.

13. WAL Skip% Metric Exposure (NEW)

- Emit skip_ratio in PROFILE recovery stats; test asserts threshold.

14. Index Plan Rationale Field (NEW)

- Add rationale string listing selectivity & cost factors in PROFILE NodeIndexScan.

15. MVCC Version GC (NEW)

- Epoch-based reclamation; test ensures reclaimed versions invisible & memory freed.
