# NEXT — Execution‑Ready Backlog (ISO‑GQL Aligned)

Swimlanes: Now (active), Next (queued), Later (strategic). Each task lists Why / What / Acceptance / ISO anchors / Deps / Scope / DRI.

## Now

1. Fix ORDER BY BINDINGS panic (REQ-GQL-037 / 001)

   - Why: Blocks all protocol conformance and hides diagnostics (14.10; 16.18–16.19; 23.2)
   - What: Root-cause write corruption; add allocator invariants; fuzz minimal ORDER queries.
   - Acceptance:
     - Query: `RETURN 1 AS x ORDER BY x LIMIT 1` → two JSON lines (SCHEMA then ordered BINDINGS) exit 0.
     - `RETURN 1 LIMIT 5 OFFSET 2` → exit 2; stderr contains `US001` + anchor `16.18–16.19`.
     - Memory sanitizer build (if feature flag) shows 0 invalid frees.
   - ISO: 14.10, 16.18–16.19, 23.2
   - Deps: protocol.zig, server/main.zig
   - Scope: M
   - DRI: core

2. Diagnostics precedence + additional_statuses (REQ-GQL-022/030/036)

   - Why: Multi-condition errors need deterministic ordering (23.2; 24.\* UA002)
   - What: Introduce precedence table; fold multiple findings into `additional_statuses` array.
   - Acceptance: Crafted query triggering IllegalOrderKey + US001 returns primary=US001, additional includes IllegalOrderKey.
   - ISO: 23.2, Annex D
   - Deps: diagnostics.zig, protocol.zig
   - Scope: S
   - DRI: core

3. EXPLAIN / PROFILE stabilization (REQ-GQL-019/020/033)

   - Why: Required for plan introspection & performance tuning (14.10)
   - What: Integrate planner metadata; emit logical op array + stable ordering; PROFILE adds per-op rows/time.
   - Acceptance: `EXPLAIN RETURN 1 AS x` emits JSON with logical=[Project]; PROFILE same plus metrics.
   - ISO: 14.10, 23.2
   - Deps: planner.zig, server/main.zig
   - Scope: M
   - DRI: core

4. Decimal comparison & ordering (REQ-GQL-031)

   - Why: Needed for ORDER BY numeric correctness (16.\*)
   - What: Implement compare aligning scales; add tests mixing scales & negative.
   - Acceptance: `RETURN 1.20 AS a, 1.2 AS b ORDER BY a,b` stable ordering; equality dedup in UNION DISTINCT works.
   - ISO: 16 numeric clauses
   - Deps: eval.zig
   - Scope: S
   - DRI: core

5. Flagger emission (REQ-GQL-029 / 020)
   - Why: Surface impl-defined (I*) & dependent (U*) decisions (24.\*)
   - What: Add `flagger_findings` array to all result frames with US001 policy, DISTINCT ordering policy.
   - Acceptance: Any LIMIT query without ORDER shows finding `U:US001=enforced` when rejected.
   - ISO: 24.\*, 16.18–16.19
   - Deps: protocol.zig
   - Scope: S
   - DRI: core

## Next

1. Text/plain encoding path (REQ-GQL-023)

   - Why: Conformance option & lightweight inspection.
   - What: `--format=txt` emits header line + tab-separated rows, deterministic value formatting.
   - Acceptance: CLI round-trip test vs golden text.
   - ISO: 24.\*
   - Scope: S
   - DRI: core

1. GROUP BY execution phase 1 (aggregation runtime) (REQ-GQL-016)

   - Why: Unlock analytics queries.
   - What: Hash aggregate operator; map HAVING to post-agg filter.
   - Acceptance: `RETURN a, SUM(b) GROUP BY a ORDER BY a` outputs grouped rows ordered.
   - ISO: 14.10
   - Scope: M
   - DRI: core

1. Parameter vectorization optimization (REQ-GQL-032)

   - Why: Reduce alloc churn; prepare for batch execution.
   - What: Pre-size env arrays; arena reinstated with safety tests.
   - Acceptance: Benchmark shows <50% allocs vs baseline on 1k param rows.
   - ISO: 16.\*
   - Scope: S
   - DRI: core

1. Transactions demarcation + state (REQ-GQL-027 subset)

   - Why: Prepare MVCC; user-visible semantics.
   - What: BEGIN/COMMIT/ROLLBACK frames with status codes; reject nested.
   - Acceptance: e2e txn test passes; second BEGIN yields TxnState error.
   - ISO: §8; 23.2
   - Scope: M
   - DRI: core

1. Storage page manager integration (REQ-GQL-025)

- Why: Persist rows; future WAL.
- What: Slotted page alloc/free; basic catalog; append-only segment.
- Acceptance: unit_page_manager & new write/read tests green.
- ISO: data model 4.\* (binding tables persisted)
- Scope: M
- DRI: storage

1. Binary protocol framing refinement (REQ-GQL-021/022)

- Why: Network & multi-status.
- What: Add additional_statuses array; normalize status_subclass codes.
- Acceptance: Multi-diagnostic test shows array ordering stable.
- ISO: 23.2
- Scope: S
- DRI: core

1. UNION / set-op plan physical differentiation

- Why: Efficiency for ALL vs DISTINCT.
- What: DISTINCT uses hash-set; ALL streaming concat.
- Acceptance: Profile shows DISTINCT path includes hash metric; ALL does not.
- ISO: 14.12
- Scope: S
- DRI: core

## Later

1. WAL/ARIES design + log record formats (REQ-GQL-026)

- Why: Durability foundation.
- Acceptance: Crash replay test recovers committed inserts.
- ISO: §8 durability references
- Scope: L | DRI: storage

1. MVCC snapshot isolation (REQ-GQL-027)

- Why: Correct concurrent reads.
- Acceptance: Concurrent read/write test shows consistent snapshots; write-write conflict detection.
- ISO: §8
- Scope: L | DRI: core

1. Path patterns & tie-break (REQ-GQL-017 full)

- Why: Expand query expressiveness.
- Acceptance: Bounded path query returns shortest paths with documented tie-break (length,id).
- ISO: 22.4; UA005/UA006
- Scope: L | DRI: core

1. Distributed scaffold (REQ-GQL-028)

- Why: Future scale-out.
- Acceptance: Raft leader election stub test & 2PC coordinator interface compile behind feature flag.
- ISO: Implementation-defined distributed semantics.
- Scope: L | DRI: dist

1. Adaptive re-optimization hooks

- Why: Plan robustness.
- Acceptance: Inject cardinality deviation triggers re-plan; log explain diff.
- ISO: 14.10 (execution semantics remain intact)
- Scope: M | DRI: core

1. Ranked (Any-k) ORDER BY early-stop

- Why: Performance for LIMIT queries.
- Acceptance: LIMIT 10 query avoids full materialization (measured via PROFILE rows scanned < total).
- ISO: 16.18–16.19
- Scope: M | DRI: core

## Cutline

Deferred until core protocol + storage stabilize: Full WAL/ARIES recovery validation, MVCC, path patterns, distributed scaffold, adaptive & ranked enumeration optimization.
