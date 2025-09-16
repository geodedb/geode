# NEXT — Execution‑Ready Backlog

Each task lists: Why • What • Acceptance • ISO Anchors • Deps • Scope (S/M/L) • DRI. Swimlanes: Now / Next / Later. All acceptance include concrete GQL plus expected result shape or diagnostic.

## Now (P0)

1. **Index selectivity estimator (reservoir/HLL++) (REQ-GQL-039)**
   - **Why**: Enable cost-based index vs scan decisions
   - **What**: Maintain per-label/property HLL++ distinct + sample; expose in EXPLAIN estimates
   - **Acceptance**: Selective label query picks index; non-selective chooses scan; EXPLAIN shows selectivity <0.10
   - **ISO**: 14.4 (MATCH), 14.10 (planning semantics)
   - **Deps**: src/planner.zig, estimator stats
   - **Scope**: M
   - **DRI**: core

2. **NodeIndexScan inline metadata (REQ-GQL-039)**
   - **Why**: Remove indirection (IndexMeta stub) and expose selectivity + index_name for PROFILE consumers
   - **What**: Elide IndexMeta op; extend PROFILE op JSON with `index_name`,`selectivity_est` fields
   - **Acceptance**: `PROFILE RETURN 1 AS x` (with synthetic index usage case) shows NodeIndexScan op having `index_name` and numeric `selectivity_est`; IndexMeta absent
   - **ISO**: 14.10 (primitive result), 23.2 (diagnostics unaffected)
   - **Deps**: src/server/main.zig (profile emission), src/planner.zig
   - **Scope**: S
   - **DRI**: core

3. **Result formatting parity TXT (EXPLAIN/PROFILE) (REQ-GQL-023/019/020)**
   - **Why**: Ensure consistent multi-format outputs for automation
   - **What**: Add text serializer; tests diff-stable
   - **Acceptance**: `PROFILE RETURN 1` with `--format=txt` matches golden file; mismatch fails test
   - **ISO**: 24.x (conformance disclosure), 14.10
   - **Deps**: src/client/main.zig, src/server/main.zig
   - **Scope**: S
   - **DRI**: core

## Next (P1)

1. **Result formatting parity TXT (EXPLAIN/PROFILE) (REQ-GQL-023/019/020)**
   - **Why**: Ensure consistent multi-format outputs for automation
   - **What**: Add text serializer; tests diff-stable
   - **Acceptance**: `PROFILE RETURN 1` with `--format=txt` matches golden file; mismatch fails test
   - **ISO**: 24.x (conformance disclosure), 14.10
   - **Deps**: src/client/main.zig, src/server/main.zig
   - **Scope**: S
   - **DRI**: core

2. **Conformance auto-regeneration script (REQ-GQL-018/034/045)**
   - **Why**: Prevent drift between source annotations and GAP ledger
   - **What**: Script enumerates REQ-GQL-### & features, rewrites tables; CI check ensures no manual divergence
   - **Acceptance**: `zig run scripts/doc_sync.zig --regen` produces zero git diff
   - **ISO**: 24.x
   - **Deps**: docs/*.md, scripts/
   - **Scope**: M
   - **DRI**: docs

3. **Numeric promotion matrix & div/0 subclass (REQ-GQL-013/012)**
   - **Why**: Clarify coercion + stable diagnostics for analysis
   - **What**: Add promotion table to README or dedicated doc; introduce TypeMismatch.DivZero subclass code
   - **Acceptance**: `RETURN 1/0` emits TypeMismatch.DivZero; mixed int+decimal operations match table
   - **ISO**: 16.x, 23.2
   - **Deps**: src/eval.zig, src/diagnostics.zig
   - **Scope**: S
   - **DRI**: core

4. **WAL compaction cadence & rotation choreography (REQ-GQL-026)**
   - **Why**: Automate segment reclamation after checkpoint
   - **What**: Server option triggers rotate + compact if reclaim ratio > threshold
   - **Acceptance**: Integration test forces segment rollover; after checkpoint auto compaction removes ≥1 old segment
   - **ISO**: §8
   - **Deps**: src/wal/wal.zig, src/server/main.zig
   - **Scope**: M
   - **DRI**: storage

5. **Index selectivity estimator (reservoir/HLL++) (REQ-GQL-039)**
   - **Why**: Enable cost-based index vs scan decisions
   - **What**: Maintain per-label/property HLL++ distinct + sample; expose in EXPLAIN estimates
   - **Acceptance**: Selective label query picks index; non-selective chooses scan; EXPLAIN shows selectivity <0.10
   - **ISO**: 14.4 (MATCH), 14.10 (planning semantics)
   - **Deps**: src/planner.zig, estimator stats
   - **Scope**: M
   - **DRI**: core

6. **NodeIndexScan inline metadata (REQ-GQL-039)**
   - **Why**: Remove indirection (IndexMeta stub) and expose selectivity + index_name for PROFILE consumers
   - **What**: Elide IndexMeta op; extend PROFILE op JSON with `index_name`,`selectivity_est` fields
   - **Acceptance**: `PROFILE RETURN 1 AS x` (with synthetic index usage case) shows NodeIndexScan op having `index_name` and numeric `selectivity_est`; IndexMeta absent
   - **ISO**: 14.10 (primitive result), 23.2 (diagnostics unaffected)
   - **Deps**: src/server/main.zig (profile emission), src/planner.zig
   - **Scope**: S
   - **DRI**: core

## Later (P2+)

1. **MVCC Snapshot Isolation full (REQ-GQL-027)**
   - **Why**: Provide consistent reads & write-write conflict handling
   - **What**: Version chains, snapshot visibility rules, write lock detection
   - **Acceptance**: Concurrent conflicting updates produce abort; snapshot sees pre-commit values
   - **ISO**: §8
   - **Deps**: src/txn/manager.zig, wal integration
   - **Scope**: L
   - **DRI**: core

2. **Path patterns & deterministic tie-break (REQ-GQL-017)**
   - **Why**: Enable pattern queries with bounded paths & reproducible ordering
   - **What**: PathExpand operator BFS; tie-break (length, start_id, end_id) docs + flags
   - **Acceptance**: Bounded path query returns stable ordering across runs; flag UA005/UA006 present
   - **ISO**: 22.4, UA005/UA006
   - **Deps**: src/planner.zig, storage adjacency
   - **Scope**: L
   - **DRI**: core

3. **Distributed scaffold + 2PC coordinator (REQ-GQL-028/042)**
   - **Why**: Foundation for future scale-out
   - **What**: Raft leader stub; 2PC interfaces; feature flag build
   - **Acceptance**: Feature-flag e2e test simulates prepare/commit phases; state machine transitions logged
   - **ISO**: impl-defined distribution semantics
   - **Deps**: dist/, src/txn/
   - **Scope**: L
   - **DRI**: dist

4. **Encryption at rest design (REQ-GQL-038)**
   - **Why**: Prepare for compliance & data protection
   - **What**: Design doc with key hierarchy, KMS placeholders, threat model
   - **Acceptance**: Doc merged; GAP ledger evidence row updated to Implemented (design phase)
   - **ISO**: impl-defined security
   - **Deps**: docs/, research.md
   - **Scope**: M
   - **DRI**: security

5. **Page compaction & free space vacuum (REQ-GQL-040)**
   - **Why**: Mitigate space amplification in slotted pages
   - **What**: Background vacuum scanning pages with fragmentation > threshold
   - **Acceptance**: Synthetic fragmentation test reduces waste <15% with metrics reported
   - **ISO**: impl-defined storage mgmt
   - **Deps**: src/storage/page_manager.zig
   - **Scope**: M
   - **DRI**: storage

6. **Recovery harness expansion (REQ-GQL-041)**
   - **Why**: Validate crash safety & log correctness
   - **What**: Deterministic crash injection mid-append + replay verification scripts
   - **Acceptance**: Harness passes 100 randomized seeds <30s; zero mismatches
   - **ISO**: §8
   - **Deps**: src/wal/, tests/
   - **Scope**: M
   - **DRI**: storage

7. **Ranked enumeration / early top-k (REQ-GQL-ORDER-OPT)**
   - **Why**: Reduce work for ORDER BY LIMIT queries
   - **What**: TopK physical + ranked join order; early-stop metrics in PROFILE
   - **Acceptance**: `PROFILE RETURN x ORDER BY x LIMIT 5` shows scanned_rows > output_rows and early_stop=true
   - **ISO**: 16.18–16.19
   - **Deps**: planner, executor
   - **Scope**: M
   - **DRI**: core

8. **Adaptive re-optimization checkpoints (REQ-GQL-ADAPT)**
   - **Why**: Correct misestimates without restart
   - **What**: Cardinality deviation triggers plan patch (≥4x) and emits additional_status AdaptiveReopt
   - **Acceptance**: Crafted stats-miss test triggers reopt; PROFILE includes reopt_events=1
   - **ISO**: 14.10 (execution semantics preserved)
   - **Deps**: src/planner.zig, src/server/main.zig
   - **Scope**: M
   - **DRI**: core

## Cutline

Excluded this milestone: full GPU operators, learned cost model integration, encryption implementation (beyond design), full distributed query shipping, advanced WCOJ attribute ordering heuristics, path cardinality estimation research prototypes. Rationale: focus on correctness, durability, and core planner features first.

## Recent Progress (Snapshot)

- ✅ **Memory governance** (REQ-GQL-037): Added memory limit tracking with spill triggers for HashAgg/Sort/Distinct
- ✅ **WAL skip ratio** (REQ-GQL-026): Exposed skip_ratio metric in WAL recovery; test validates ≥0.60 efficiency
- ✅ **Storage checksum diagnostics** (REQ-GQL-026): Added mapStorageError for PageChecksumMismatch → StoragePageChecksum diagnostic
- ✅ **GROUP BY HashAgg** (REQ-GQL-016): Execution already implemented in exec.runGroupedQuery; test scaffold added
- ✅ **Transaction baseline** (REQ-GQL-027): BEGIN/COMMIT/ROLLBACK with proper status_class responses (00000/25000)
- ✅ **WAL compaction automation** (REQ-GQL-026): Configurable via GEODE_WAL_COMPACT_INTERVAL (default 5 commits)
- Fixed planner test compilation issues (AST literal syntax, const qualifiers)
- WAL sparse pageLSN index & fast-seek redo path
- MVCC delete_ts & rollback semantics
- Index maintenance hooks & preliminary metadata op
- Diagnostics precedence folding (UA002) stabilized
- PROFILE peak contributor ordering accuracy tests
- WAL segment compaction tool (`wal_compact`) + tests

## Summary (Top Risks)

1. **Durability depth** (WAL fuzz scale & automated compaction) — impact: data loss if unhandled edge cases
2. **Transaction isolation completeness** — risk of anomalies
3. **Missing distributed scaffold** — scale-out blocked
4. **Index selectivity accuracy** — risk of misplans
5. **Lack of path execution** — limits expressiveness

First 11 tasks enumerated across Now+Next cover immediate correctness & observability improvements.