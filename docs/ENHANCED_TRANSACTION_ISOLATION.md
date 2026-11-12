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
  `test-canary-mvcc-adv-integration`, plus a fuzz target (`mvcc_adv/` alone is
  also compiled by `test-canary-mvcc-advanced`).
- `src/server/txn/mvcc.zig` and `src/server/txn/phantom_read_prevention.zig`
  are named only by an export in `src/lib.zig` and by two fields in
  `src/server/server_state.zig` (`mvcc_manager`, `current_mvcc_txn`) that
  nothing sets or reads. Compile-error probes placed inside their functions do
  not fire in `zig build`: none of their functions is compiled into the
  server.
- The `geode.transaction.isolation_level` metric label
  (`otel_metrics.IsolationLevel`, six values) is recorded only by
  `src/transactions/manager.zig`, so the server never emits it.
