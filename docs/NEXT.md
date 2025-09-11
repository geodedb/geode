# NEXT — Execution‑Ready Backlog (ISO‑GQL Aligned)

Swimlanes: Now (active), Next (queued), Later (strategic). Each task lists Why / What / Acceptance / ISO anchors / Deps / Scope / DRI.

## Now

1. Diagnostics precedence + additional_statuses (REQ-GQL-022/030/036)

   - Why: Multi-condition errors need deterministic ordering (23.2; 24.\* UA002)
   - What: Introduce precedence table; fold multiple findings into `additional_statuses` array.
   - Acceptance: Crafted query triggering IllegalOrderKey + US001 returns primary=US001, additional includes IllegalOrderKey.
   - ISO: 23.2, Annex D
   - Deps: diagnostics.zig, protocol.zig
   - Scope: S
   - DRI: core

2. EXPLAIN / PROFILE stabilization (REQ-GQL-019/020/033)

   - Why: Required for plan introspection & performance tuning (14.10)
   - What: Integrate planner metadata; emit logical op array + stable ordering; PROFILE adds per-op rows/time.
   - Acceptance: `EXPLAIN RETURN 1 AS x` emits JSON with logical=[Project]; PROFILE same plus metrics.
   - ISO: 14.10, 23.2
   - Deps: planner.zig, server/main.zig
   - Scope: M
   - DRI: core

3. Decimal comparison & ordering (REQ-GQL-031)

   - Why: Needed for ORDER BY numeric correctness (16.\*)
   - What: Implement compare aligning scales; add tests mixing scales & negative.
   - Acceptance: `RETURN 1.20 AS a, 1.2 AS b ORDER BY a,b` stable ordering; equality dedup in UNION DISTINCT works.
   - ISO: 16 numeric clauses
   - Deps: eval.zig
   - Scope: S
   - DRI: core

4. ORDER BY path fuzz harness (follow-up to REQ-GQL-037)

   - Why: Prevent regression of fixed panic; broaden input space.
   - What: Lightweight generator for random ORDER BY queries (ints/decimals/nulls) feeding server in-process.
   - Acceptance: 10k iterations no crash; coverage counters show distinct key shapes explored.
   - ISO: 14.10, 16.18–16.19
   - Deps: server/main.zig, tests fuzz harness
   - Scope: S
   - DRI: core

5. Plain text PROFILE & EXPLAIN parity tests (extend REQ-GQL-023)

   - Why: Ensure format encoder alignment across modes.
   - What: Add e2e tests invoking `--format txt` for EXPLAIN/PROFILE queries.
   - Acceptance: Golden txt outputs stable; diff on reorder fails test.
   - ISO: 24.\* (output representation)
   - Deps: client/main.zig
   - Scope: S
   - DRI: core

6. Counting allocator integration (StageTimings.bytes_alloc accuracy) — introduce TrackingAllocator wrapping page allocator; emit per-stage net allocations.
7. UNION value capture path reuse distinctDedup with value-based keys (ensure JSON field order independence).
8. Spill heuristic (row_count \* avg_row_size threshold) to auto-increment spill counters without env overrides; keep env for forcing.
9. NULL ordering policy (configurable NULLS FIRST/LAST) with flagger output & tests.

## Next

1. GROUP BY execution phase 1 (aggregation runtime) (REQ-GQL-016)

   - Why: Conformance option & lightweight inspection.
   - What: `--format=txt` emits header line + tab-separated rows, deterministic value formatting.
   - Acceptance: CLI round-trip test vs golden text.
   - ISO: 24.\*
   - Scope: S
   - DRI: core

2. Text/plain extended coverage (complex queries) (REQ-GQL-023 follow-up)

   - Why: Unlock analytics queries.
   - What: Hash aggregate operator; map HAVING to post-agg filter.
   - Acceptance: `RETURN a, SUM(b) GROUP BY a ORDER BY a` outputs grouped rows ordered.
   - ISO: 14.10
   - Scope: M
   - DRI: core

3. Parameter vectorization optimization (REQ-GQL-032)

   - Why: Reduce alloc churn; prepare for batch execution.
   - What: Pre-size env arrays; arena reinstated with safety tests.
   - Acceptance: Benchmark shows <50% allocs vs baseline on 1k param rows.
   - ISO: 16.\*
   - Scope: S
   - DRI: core

4. Transactions demarcation + state (REQ-GQL-027 subset)

   - Why: Prepare MVCC; user-visible semantics.
   - What: BEGIN/COMMIT/ROLLBACK frames with status codes; reject nested.
   - Acceptance: e2e txn test passes; second BEGIN yields TxnState error.
   - ISO: §8; 23.2
   - Scope: M
   - DRI: core

5. Storage page manager integration (REQ-GQL-025)

   - Why: Persist rows; future WAL.
   - What: Slotted page alloc/free; basic catalog; append-only segment.
   - Acceptance: unit_page_manager & new write/read tests green.
   - ISO: data model 4.\* (binding tables persisted)
   - Scope: M
   - DRI: storage

6. Binary protocol multi-status writer (REQ-GQL-022/036) — (folded into Now once precedence merged)

   - Why: Network & multi-status.
   - What: Add additional_statuses array; normalize status_subclass codes.
   - Acceptance: Multi-diagnostic test shows array ordering stable.
   - ISO: 23.2
   - Scope: S
   - DRI: core

7. UNION / set-op plan physical differentiation

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

## Added / Recent Progress

- Dynamic flagger on SCHEMA/BINDINGS/EXPLAIN/PROFILE + txn ACK frames (IllegalOrderKeyPolicy, NullsFirstPolicy, OrderTiebreak=LexJSON, DistinctOutputUnordered)
- StageTimings struct introduced for per-operator PROFILE metrics (simple query path only)
- Granular UNION PROFILE phases (UnionLeft, UnionTails, UnionDedup, SetOpUnion) + U:UnionPhaseTimings flag
- Parenthesized UNION pattern support ((q1 UNION q2) ORDER BY k LIMIT n)
- Text/plain encoding path
- GROUP BY execution (phase 1)
- Parameter vectorization optimization
- Clarify DistinctOutputUnordered semantics in multi-page streaming path
- Include memory stats per phase? (pending design)
- Should UNION ALL still emit UnionPhaseTimings flag (currently yes) or a separate indicator?
