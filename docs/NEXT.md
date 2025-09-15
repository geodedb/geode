<!-- NEXT.md — Execution‑Ready Backlog (manually curated; prior AUTOGEN tooling deprecated) -->

# NEXT — Execution‑Ready Backlog

Each task lists: Why • What • Acceptance • ISO Anchors • Deps • Scope (S/M/L) • DRI. Swimlanes: Now / Next / Later. All acceptance include concrete GQL plus expected result shape or diagnostic.

## Now (P0)

0. Finalize memory governance
   - Why: Enforce per-query soft memory limits to avoid OOMs
   - What: Add `soft_mem_limit_bytes` to SessionContext; read `GEODE_QUERY_MEM_LIMIT_BYTES` in server; wrap allocators to track bytes and trigger spill instead of OOM
   - Acceptance: `PROFILE RETURN` with very low `GEODE_QUERY_MEM_LIMIT_BYTES` sets `sort_spills` or `hashagg_spills` without crashing

1. Fix planner errant tests
   - Why: Ensure `planner.zig` tests compile and validate heuristic flag
   - What: Correct AST literal Expr syntax and use `std.mem.eql` for string compares
   - Acceptance: `zig test src/planner.zig` passes all tests

2. Document MVCC phantom gap
   - Why: Clarify SI allows phantoms, SSI needed for full phantom prevention
   - What: Add note in `tests/e2e_protocol_mvcc_phantom.zig` and gap doc
   - Acceptance: Tests still pass, documentation updated

3. Commit and polish
   - Why: Final cleanup, formatting, typechecks
   - What: Run `zig fmt .`, `zig build`, update CRUSH.md
   - Acceptance: All code is formatted, typechecked, and ready for commit

> Note: Planner tests and full enforcement in `evaluateSimpleQuery`/`runGroupedQuery` require larger refactors and will be tackled in a follow-up session.

## Now (P0)

<!-- NOTE: Former AUTOGEN marker removed; list is now manual. -->

1. NodeIndexScan inline metadata (REQ-GQL-039)

   - Why: Remove indirection (IndexMeta stub) and expose selectivity + index_name for PROFILE consumers.
   - What: Elide IndexMeta op; extend PROFILE op JSON with `index_name`,`selectivity_est` fields.
   - Acceptance: `PROFILE RETURN 1 AS x` (with synthetic index usage case) shows NodeIndexScan op having `index_name` and numeric `selectivity_est`; IndexMeta absent.
   - ISO: 14.10 (primitive result), 23.2 (diagnostics unaffected).
   - Deps: server/main.zig (profile emission), planner.zig.
   - Scope: S
   - DRI: core

2. WAL skip ratio exposure & synthetic test (REQ-GQL-026)

   - Why: Quantify redo pruning efficiency; drive compaction heuristic design.
   - What: Add `skip_ratio` field to PROFILE (recovery scenario) or expose via CLI flag; add `e2e_wal_skip_ratio.zig` ensuring ratio ≥0.60 on crafted log.
   - Acceptance: Test asserts JSON contains `"skip_ratio":0.` prefix and value ≥0.60.
   - ISO: §8 (durability impl-defined metrics).
   - Deps: wal/wal.zig, tests.
   - Scope: S
   - DRI: storage

3. StoragePageChecksum diagnostic propagation (REQ-GQL-026)

   - Why: Surface page corruption early & unify with diagnostics precedence.
   - What: Map page_manager checksum failure to new diagnostic subclass; ensure precedence folding stable.
   - Acceptance: Injected corrupt page test emits additional_status with code; base status_class 58000 (data error) and includes anchor comment.
   - ISO: 23.2 (diagnostics), §8 (recovery).
   - Deps: page_manager.zig, diagnostics.zig, server/main.zig.
   - Scope: S
   - DRI: storage

4. GROUP BY execution (HashAgg) (REQ-GQL-016)

   - Why: Move from legality-only to actual aggregation output.
   - What: Implement HashAgg physical op; add aggregation evaluation + PROFILE rows reduction.
   - Acceptance: `PROFILE RETURN a, SUM(b) GROUP BY a ORDER BY a` with params a:[1,1,2], b:[10,1,5] yields rows: (a=1,sum=11),(a=2,sum=5); PROFILE shows HashAgg with input_rows=3, rows=2.
   - ISO: 14.10 (group semantics), 16.x (expressions).
   - Deps: eval.zig, planner.zig, server/main.zig.
   - Scope: M
   - DRI: core

5. Transactions baseline (BEGIN/COMMIT/ROLLBACK) (REQ-GQL-027 subset)
   - Why: Provide user-visible atomicity semantics for sequential statements.
   - What: Implement txn manager with state, simple write set placeholder, status codes; protocol frames carry txn outcome.
   - Acceptance: Script: HELLO; BEGIN; RUN_GQL `RETURN 1 AS x`; COMMIT -> both frames status_class 00000. Second BEGIN before COMMIT returns error status_class 25000 (active txn) with additional_status TxnState.
   - ISO: §8 (transactions), 23.2 (diagnostics), 7 (sessions).
   - Deps: txn/manager.zig, protocol.zig, server/main.zig.
   - Scope: M
   - DRI: core

## Next (P1)

<!-- NOTE: Former AUTOGEN marker removed; list is now manual. -->

1. Result formatting parity TXT (EXPLAIN/PROFILE) (REQ-GQL-023/019/020)

   - Why: Ensure consistent multi-format outputs for automation.
   - What: Add text serializer; tests diff-stable.
   - Acceptance: `PROFILE RETURN 1` with `--format=txt` matches golden file; mismatch fails test.
   - ISO: 24.x (conformance disclosure), 14.10.
   - Deps: client/main.zig, server/main.zig.
   - Scope: S
   - DRI: core

1. Conformance auto-regeneration script (REQ-GQL-018/034/045)

   - Why: Prevent drift between source annotations and GAP ledger.
   - What: Script enumerates REQ-GQL-### & features, rewrites tables; CI check ensures no manual divergence.
   - Acceptance: `zig run scripts/doc_sync.zig --regen` produces zero git diff.
   - ISO: 24.x.
   - Deps: docs/\*.md, scripts.
   - Scope: M
   - DRI: docs

1. Numeric promotion matrix & div/0 subclass (REQ-GQL-013/012)

   - Why: Clarify coercion + stable diagnostics for analysis.
   - What: Add promotion table to README or dedicated doc; introduce TypeMismatch.DivZero subclass code.
   - Acceptance: `RETURN 1/0` emits TypeMismatch.DivZero; mixed int+decimal operations match table.
   - ISO: 16.x, 23.2.
   - Deps: eval.zig, diagnostics.zig.
   - Scope: S
   - DRI: core

1. WAL compaction cadence & rotation choreography (REQ-GQL-026)

   - Why: Automate segment reclamation after checkpoint.
   - What: Server option triggers rotate + compact if reclaim ratio > threshold.
   - Acceptance: Integration test forces segment rollover; after checkpoint auto compaction removes ≥1 old segment.
   - ISO: §8.
   - Deps: wal/wal.zig, server/main.zig.
   - Scope: M
   - DRI: storage

1. Index selectivity estimator (reservoir/HLL++) (REQ-GQL-039)
   - Why: Enable cost-based index vs scan decisions.
   - What: Maintain per-label/property HLL++ distinct + sample; expose in EXPLAIN estimates.
   - Acceptance: Selective label query picks index; non-selective chooses scan; EXPLAIN shows selectivity <0.10.
   - ISO: 14.4 (MATCH), 14.10 (planning semantics).
   - Deps: planner.zig, estimator stats.
   - Scope: M
   - DRI: core

## Later (P2+)

<!-- NOTE: Former AUTOGEN marker removed; list is now manual. -->

1. MVCC Snapshot Isolation full (REQ-GQL-027)

   - Why: Provide consistent reads & write-write conflict handling.
   - What: Version chains, snapshot visibility rules, write lock detection.
   - Acceptance: Concurrent conflicting updates produce abort; snapshot sees pre-commit values.
   - ISO: §8.
   - Deps: txn/manager.zig, wal integration.
   - Scope: L
   - DRI: core

1. Path patterns & deterministic tie-break (REQ-GQL-017)

   - Why: Enable pattern queries with bounded paths & reproducible ordering.
   - What: PathExpand operator BFS; tie-break (length, start_id, end_id) docs + flags.
   - Acceptance: Bounded path query returns stable ordering across runs; flag UA005/UA006 present.
   - ISO: 22.4, UA005/UA006.
   - Deps: planner.zig, storage adjacency.
   - Scope: L
   - DRI: core

1. Distributed scaffold + 2PC coordinator (REQ-GQL-028/042)

   - Why: Foundation for future scale-out.
   - What: Raft leader stub; 2PC interfaces; feature flag build.
   - Acceptance: Feature-flag e2e test simulates prepare/commit phases; state machine transitions logged.
   - ISO: impl-defined distribution semantics.
   - Deps: dist/, txn/.
   - Scope: L
   - DRI: dist

1. Encryption at rest design (REQ-GQL-038)

   - Why: Prepare for compliance & data protection.
   - What: Design doc with key hierarchy, KMS placeholders, threat model.
   - Acceptance: Doc merged; GAP ledger evidence row updated to Implemented (design phase).
   - ISO: impl-defined security.
   - Deps: docs/, research.md.
   - Scope: M
   - DRI: security

1. Page compaction & free space vacuum (REQ-GQL-040)

   - Why: Mitigate space amplification in slotted pages.
   - What: Background vacuum scanning pages with fragmentation > threshold.
   - Acceptance: Synthetic fragmentation test reduces waste <15% with metrics reported.
   - ISO: impl-defined storage mgmt.
   - Deps: storage/page_manager.zig.
   - Scope: M
   - DRI: storage

1. Recovery harness expansion (REQ-GQL-041)

   - Why: Validate crash safety & log correctness.
   - What: Deterministic crash injection mid-append + replay verification scripts.
   - Acceptance: Harness passes 100 randomized seeds <30s; zero mismatches.
   - ISO: §8.
   - Deps: wal/, tests/.
   - Scope: M
   - DRI: storage

1. Ranked enumeration / early top-k (REQ-GQL-ORDER-OPT)

   - Why: Reduce work for ORDER BY LIMIT queries.
   - What: TopK physical + ranked join order; early-stop metrics in PROFILE.
   - Acceptance: `PROFILE RETURN x ORDER BY x LIMIT 5` shows scanned_rows > output_rows and early_stop=true.
   - ISO: 16.18–16.19.
   - Deps: planner, executor.
   - Scope: M
   - DRI: core

1. Adaptive re-optimization checkpoints (REQ-GQL-ADAPT)
   - Why: Correct misestimates without restart.
   - What: Cardinality deviation triggers plan patch (≥4x) and emits additional_status AdaptiveReopt.
   - Acceptance: Crafted stats-miss test triggers reopt; PROFILE includes reopt_events=1.
   - ISO: 14.10 (execution semantics preserved).
   - Deps: planner.zig, server/main.zig.
   - Scope: M
   - DRI: core

## Cutline

Excluded this milestone: full GPU operators, learned cost model integration, encryption implementation (beyond design), full distributed query shipping, advanced WCOJ attribute ordering heuristics, path cardinality estimation research prototypes. Rationale: focus on correctness, durability, and core planner features first.

## Recent Progress (Snapshot)

- WAL sparse pageLSN index & fast-seek redo path.
- MVCC delete_ts & rollback semantics.
- Index maintenance hooks & preliminary metadata op.
- Diagnostics precedence folding (UA002) stabilized.
- PROFILE peak contributor ordering accuracy tests.
- WAL segment compaction tool (`wal_compact`) + tests.

## Summary (Top Risks)

1. Durability depth (WAL fuzz scale & automated compaction) — impact: data loss if unhandled edge cases.
2. Transaction isolation completeness — risk of anomalies.
3. Missing distributed scaffold — scale-out blocked.
4. Index selectivity accuracy — risk of misplans.
5. Lack of path execution — limits expressiveness.

First 10 tasks enumerated across Now+Next cover immediate correctness & observability improvements.
