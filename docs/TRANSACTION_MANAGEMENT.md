# Transaction Management

This document describes transaction management in Geode, including START TRANSACTION, COMMIT, and ROLLBACK commands.

## Overview

Geode supports explicit transaction control through SQL-style transaction commands. Transactions allow you to group multiple operations together and either commit them all at once or roll them back.

## Transaction Commands

### START TRANSACTION

Begins a new transaction.

**Syntax:**

```gql
START TRANSACTION
```

**Example:**

```gql
START TRANSACTION;
CREATE (p:Person {name: 'Alice'});
CREATE (c:Company {name: 'Acme'});
CREATE (p)-[:WORKS_FOR]->(c);
COMMIT;
```

**Behavior:**

- Initiates a new transaction context
- Subsequent operations execute within the transaction
- Transaction state persists across separate CLI invocations within a session
- Returns error if a transaction is already active

### COMMIT

Commits the current transaction, making all changes permanent.

**Syntax:**

```gql
COMMIT
```

**Example:**

```gql
START TRANSACTION;
CREATE (n:Node {value: 123});
COMMIT;
```

**Behavior:**

- Persists all changes made during the transaction
- Clears transaction state
- Returns error if no transaction is active

### ROLLBACK

Rolls back the current transaction, discarding all changes.

**Syntax:**

```gql
ROLLBACK
```

**Example:**

```gql
START TRANSACTION;
CREATE (n:TempNode {data: 'temporary'});
-- Decide to discard
ROLLBACK;
```

**Behavior:**

- Discards all changes made during the transaction: every statement's
  creates, property SETs and REMOVEs, label changes and deletes are undone
  through the store's write methods (SONNY-3059, SONNY-3348)
- Rebuilds, from the store as the undo left it, every full-text and advanced
  (vector, spatial, ...) index covering a property, label or node the undo
  reverted, so a search after ROLLBACK answers for what the store holds
  (SONNY-3381). The same holds for a statement that fails: its changes are
  undone before its error is returned, and the same indexes are rebuilt. A
  rebuild costs O(nodes of the index's label)
- Clears transaction state
- Returns error if no transaction is active

## Transaction State Management

### State Lifecycle

1. **None**: No active transaction
2. **Active**: Transaction started, operations in progress
3. **Committed**: Transaction committed successfully
4. **RolledBack**: Transaction rolled back

### State Persistence

Transaction state is held by the server for the connection, not in a file:
the QUIC handler keeps a per-connection `in_txn` flag
(`src/server/quic_connection_handler.zig`) and passes it to the executor as
`ExecutionContext.transaction_state` (`src/execution.zig`). A transaction
therefore spans the statements sent on one connection, for example in
`geode shell` or in one multi-statement `geode query` call. Separate
`geode query` invocations open separate connections and do not share a
transaction.

## Error Handling

### TransactionAlreadyActive

Returned when attempting to start a transaction while one is already active.

```gql
START TRANSACTION;
-- ERROR: Transaction already active
START TRANSACTION;
```

**Status Class**: `0A000` (Feature Not Supported)

### NoActiveTransaction

Returned when attempting to COMMIT or ROLLBACK without an active transaction.

```gql
-- No START TRANSACTION
COMMIT  -- ERROR: No active transaction
```

**Status Class**: `0A000` (Feature Not Supported)

## Multi-Operation Transactions

Transactions can include multiple graph operations:

```gql
START TRANSACTION

-- Create nodes
CREATE (p:Person {name: 'Bob', age: 30});
CREATE (c:Company {name: 'TechCorp'});

-- Create relationship
MATCH (p:Person {name: 'Bob'}), (c:Company {name: 'TechCorp'})
CREATE (p)-[:WORKS_FOR {since: 2024}]->(c)

-- Update properties
MATCH (p:Person {name: 'Bob'})
SET p.status = 'employed'

COMMIT
```

## Combining with Other Features

### Transactions with MERGE

```gql
START TRANSACTION

MERGE (u:User {email: 'user@example.com'})
ON CREATE SET u.created = datetime()
ON MATCH SET u.updated = datetime()

COMMIT
```

### Transactions with Session Parameters

```gql
-- Set session parameter
SESSION SET VALUE $user_id = 123

START TRANSACTION

-- Use parameter in transaction
CREATE (u:User {id: $user_id, name: 'Alice'})

COMMIT
```

## Implementation Details

### AST Structures

```zig
pub const Statement = union(enum) {
    StartTransaction,
    Commit,
    Rollback,
    // ... other statements
};
```

### Execution Context

```zig
pub const ExecutionContext = struct {
    user: ?[]const u8 = null,
    token: ?[]const u8 = null,
    strict_offset_validation: bool = false,
    session_state: *SessionState,
    transaction_state: TransactionState,  // Current transaction state
};

pub const TransactionState = enum {
    None,
    Active,
    Committed,
    RolledBack,
};
```

### Session Persistence

There is no on-disk transaction session. See
[State Persistence](#state-persistence).

**Files:**

- `src/server/quic_connection_handler.zig`: per-connection transaction flag
- `src/execution.zig`: transaction command execution and undo log

## Testing

Comprehensive unit tests are available in:

- `geodetestlab/specs/transaction_state_unit_tests.yml`
- `geodetestlab/specs/session_transaction_fixes.yml`

Test coverage includes:

- START TRANSACTION, COMMIT, ROLLBACK lifecycle
- Multiple operations within transactions
- Error handling (no active transaction, already active)
- State cleanup after COMMIT/ROLLBACK
- Transaction state persistence across CLI invocations
- Combining transactions with MERGE, DELETE, UPDATE operations

## GQL Compliance

These features implement ISO/IEC 39075:2024 GQL standard:

- START TRANSACTION statement (§19.1)
- COMMIT statement (§19.2)
- ROLLBACK statement (§19.3)
- Transaction lifecycle management

## Limitations (Current Implementation)

1. **Auto-commit Mode**: Changes are currently visible immediately (no true isolation)
2. **Single User**: No multi-user concurrency control yet
3. **No Isolation Levels**: Default isolation only
4. **Savepoints on the wire only**: the client protocol's savepoint and
   rollback-to-savepoint requests are implemented; GQL has no SAVEPOINT
   statement here

## Crash Durability and Atomicity (SONNY-2979)

A transaction is atomic in the running server, NOT across a crash (kill -9,
OOM kill, power loss). What holds, as of the SONNY-738 sweep:

- **Write-through.** Each change is written to the storage engine as it
  runs. Within one request, the changes on the shard of the session's engine
  transaction (opened by the request's first change; the request's new nodes
  are allocated there, SONNY-6425) commit together, with one WAL fsync, when
  the request's program ends. A change on any of the other 15 shards commits
  its own engine transaction when it runs; so do a REMOVE of a property, a
  DELETE of a node and a REMOVE of a relationship property, wherever they
  are.
- **No engine transaction outlives a request** (SONNY-2823). A transaction
  over several requests is committed in the engine request by request.
- **ROLLBACK, a failed statement and a session's teardown** undo the
  transaction through the in-memory undo log (`txn_undo_log`, and a
  statement's own record, `statement_undo`), which writes compensating
  changes to the engine. The undo log is memory-only.
- **The undo joins the open engine transaction** (SONNY-6529). A failed
  statement's engine transaction, a transaction body's and the session's
  are ended AFTER the undo replays, by a commit: the replay's compensating
  writes join them, so the failed writes and their undo reach the WAL as
  one unit, and a crash before that commit loses both. Where the undo runs
  after the request (the handler's rollback of a request that failed in an
  explicit transaction), the request's engine transaction is committed at
  its end and the undo commits its compensations on its own, as for every
  committed request of an open transaction (the window above). geode used to
  abort the engine transaction first (SONNY-2823, SONNY-3135); graph-storage
  0.4.16 makes `abortTxn` undo the transaction's writes, and the replay then
  undid them a second time (a node it created was gone, its delete failed
  with 40003, and the server kept the node in memory).
- **The engine's own undo** is used for a transaction the adapter opened
  for one write call that failed before the server's in-memory copy took
  the write: graph-storage 0.4.16 `abortTxn` undoes it (node record, slot,
  count and id, properties, labels, relationships). An abort it cannot undo
  exactly (`AbortNotUndone`: a page the caller imaged itself, a property
  change on a legacy chain, a chain pointer of an existing node moved, more
  than 1,048,576 writes) leaves the writes in the shard's pages and makes the
  shard refuse every write, commit and checkpoint; geode then refuses the
  graph's reads and writes with 58000 `AbortNotUndone` until the server
  restarts, which reopens the graph at its committed state (nothing
  uncommitted reached disk). The same holds for a write graph-storage
  commits on its own (a label add or remove, a relationship create or
  delete, a relationship property remove outside a statement transaction on
  its shard): graph-storage aborts it when it fails and returns the write's
  error, and geode reads the shard's `abort_not_undone` after the failure
  and quarantines the graph (SONNY-6601 (3)). A commit that fails after
  the in-memory copy took the writes aborts the transaction and refuses the
  graph the same way
  (58000 `CommitFailed`). Neither is reopened in place: geode keeps the
  graph's nodes, relationships, label counts and indexes in memory beside
  the engine and has no path that rebuilds them for one graph while the
  server runs. Counters: `geode.runtime.storage_txn_aborts_undone_total`,
  `geode.runtime.storage_txn_aborts_not_undone_total`.
- **COMMIT is durable.** Once COMMIT returns, every change of the
  transaction has been fsynced to the engine WAL (per-commit fsync), and a
  committed change made inside the transaction is never undone by recovery
  (SONNY-2978: the session's engine transaction no longer batches its WAL
  page images past other transactions' commits on its shard).

What does NOT hold: after a crash with a transaction open, recovery keeps
every change the transaction's requests already committed in the engine.
Nothing on disk records that the transaction was open, so nothing undoes
them. `zig build test-sonny2979-txn-crash-atomicity` (intentionally red,
[KNOWN_TEST_ISSUES.md](KNOWN_TEST_ISSUES.md)) kills a real server with two
transactions open and finds all their nodes, and a property one of them
SET, after the restart.

Making a transaction crash-atomic needs one durable commit decision for the
whole transaction, across requests and shards: either a durable undo log
(write an entry, fsynced, before each change reaches the engine; at
recovery, undo every transaction with no durable commit record), or a
transaction-wide redo buffer applied at COMMIT through a cross-shard commit
record in graph-storage, whose 16 per-shard WALs have no shared commit
record today.

## Future Enhancements

- True MVCC (Multi-Version Concurrency Control)
- Isolation level support (READ COMMITTED, REPEATABLE READ, SERIALIZABLE)
- Savepoints for partial rollback
- Deadlock detection
- Transaction timeouts
- Read-only transactions

## See Also

- [Session Management](SESSION_MANAGEMENT.md)
- [MERGE Operations](MERGE_AND_LABEL_TESTS.md)
- [Enhanced Transaction Isolation](ENHANCED_TRANSACTION_ISOLATION.md) - Status note: not implemented
- [GQL Compliance](GQL_COMPLIANCE.md)
