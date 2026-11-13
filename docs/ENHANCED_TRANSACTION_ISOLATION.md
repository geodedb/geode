# Enhanced Transaction Isolation — Status: Not Implemented

**Status (2026-11-11, SONNY-6298):** Geode has no selectable transaction
isolation levels, no Serializable Snapshot Isolation (SSI), no predicate-lock
phantom-read prevention and no deadlock detector in the server. This document
used to describe an "Enhanced Isolation Manager" in
`src/server/txn/enhanced_isolation.zig` and an integration layer in
`src/server/txn/isolation_integration.zig`. Neither file was reachable from any
executable or test in `build.zig`; they were never compiled and were removed,
together with the two uncompiled tests that exercised them
(`tests/test_enhanced_transaction_isolation.zig`,
`tests/test_enhanced_transaction_isolation_integration.zig`).

## What the server does

- **No isolation clause.** `START TRANSACTION` takes no isolation level:
  `StartTransactionStatement` in `src/gql/ast.zig` carries only an optional
  body. `REPEATABLE` exists as a lexer keyword only.
- **Writes are serialized per graph.** Mutating statements run while the
  connection handler holds the graph's write lock
  (`graph_store.acquireGraphWriteLock`, held through execution). The bulk-MERGE
  fast paths use striped tuple locks under a shared hold instead (see the lock
  ordering table in `CLAUDE.md`).
- **Reads see one snapshot per query.** A read statement runs against a copy
  taken under the graph's shared lock (`graph_store.snapshotUnderReadLock` /
  `snapshotUnderReadLocks`), or on a storage-native path that reads the storage
  adapter directly.
- **Explicit transactions roll back through an undo log.** `START TRANSACTION`
  opens the thread's undo log (`src/txn_undo_log.zig`); `ROLLBACK` replays it.
  See [TRANSACTION_MANAGEMENT.md](TRANSACTION_MANAGEMENT.md).

## Code that exists but no server path calls

- `src/transactions/manager.zig` (lock manager, `range_tracker.zig` phantom
  range tracking, write-skew detection, `mvcc_adv/`) is compiled only by its
  tests: `zig build test-canary-txn-phantom-anomaly`,
  `test-canary-txn-phantom-range`, `test-canary-txn-write-skew`,
  `test-canary-mvcc-adv-integration`, `test-sonny6484-inline` (its inline
  tests), plus a fuzz target (`mvcc_adv/` alone is also compiled by
  `test-canary-mvcc-advanced`). Until SONNY-6484 every QUIC and gRPC
  connection state (`ServerState.txn_manager`, `active_txn`) carried a
  `Manager` that was initialised and freed but never called; the fields
  were removed. SONNY-6484 also fixed two defects its inline tests found:
  `commit` aborted a lock holder whose refused waiter was still active
  (the write-write check was symmetric; only the refused requester is
  doomed now), and a transaction's wait-for list leaked at commit and
  rollback.
- `src/server/txn/mvcc.zig` and `src/server/txn/phantom_read_prevention.zig`
  are named only by an export in `src/lib.zig` and by two fields in
  `src/server/server_state.zig` (`mvcc_manager`, `current_mvcc_txn`) that
  nothing sets or reads. Compile-error probes placed inside their functions do
  not fire in `zig build`: none of their functions is compiled into the
  server.
- The `geode.transaction.isolation_level` metric label
  (`otel_metrics.IsolationLevel`, six values) is recorded only by
  `src/transactions/manager.zig`, so the server never emits it.

## Phantom prevention overhead

`src/transactions/manager.zig` phantom prevention (prefix predicates and the
`range_tracker.zig` ranges, checked at commit) is not cheap relative to the
synthetic transactions its benchmarks run, and no server path pays it (see
above). The benchmarks used to claim an overhead of at most 5% per
transaction; corrected for methodology (SONNY-2439: batched samples,
interleaved arms, medians, the production allocator) they measure, on a
shared dev host (SONNY-6386):

| Benchmark | ReleaseFast | Debug | Bound (ReleaseFast / Debug) |
| --- | --- | --- | --- |
| `zig build test-canary-txn-phantom-anomaly` (5 predicate reads, 10 writes, commit; prevention on vs off) | 27-36% (349-361 ns vs 457-474 ns) | 61-63% | 50% / 90% |
| `zig build test-canary-txn-phantom-range` (predicate plus two range reads vs two predicate reads, prevention on in both) | 84-96% (116-123 ns vs 224-231 ns) | 54-61% | 125% / 80% |

The cost is the tracking itself: for each transaction a hash-map entry and a
list allocation per tracking structure and a heap copy of every prefix and
range bound, released at commit, plus the commit-time scan of the
transaction's writes (about 100-125 ns in ReleaseFast). The baseline
transactions do no storage work, so the ratio is large; it is not an
accidental scan or lock. The bounds are about 1.3-1.4x the highest median
measured (ten ReleaseFast and three Debug runs), per build mode, because the thresholds are not yet calibrated on the
quiet CI runner (SONNY-2439); a change that doubled the tracking cost would
still exceed them. The scheduled `test-perf-gates-enforced` job enforces them
in ReleaseFast. Regression: `zig build test-sonny6386-phantom-overhead-claims`.
