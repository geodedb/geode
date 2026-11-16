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

## Crash Durability and Atomicity (SONNY-2979, SONNY-6658)

An explicit transaction (BEGIN or START TRANSACTION ... COMMIT, over one
request or several) is atomic across a crash (kill -9, OOM kill, power
loss): after the restart either all of it is there (it committed) or none
of it (it was open, or rolled back). So is an auto-commit statement (one
statement outside BEGIN ... COMMIT), SONNY-6658: below.

How:

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
  changes to the engine. Inside an explicit transaction each entry is
  also written ahead to the durable undo log (below).
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
- **Durable undo log, `<data dir>/txn_undo.wal`** (`src/txn_durable_undo.zig`).
  Inside an explicit transaction every change's undo entry (the
  `txn_undo_log.UndoEntry` ROLLBACK uses: a created node or relationship, a
  property's old value or its absence, a deleted node or relationship with
  its labels, properties and tenant, a label added or removed) is appended
  and fsynced **before** the change is made: `statement_undo.append` records
  the state a write is about to change, and a create first logs an intent
  naming the public id it is about to create (node creates, batch creates
  and relationship creates; a relationship is written on shard(from), which
  commits it at once when that is not the session's shard). So no engine
  commit ever carries a change whose undo is not on disk.
- **COMMIT** commits the request's engine transaction, then appends and
  fsyncs a COMMITTED record. That record is the transaction's commit point:
  COMMIT is acknowledged only after it, and if it cannot be written COMMIT
  fails and the transaction is rolled back.
- **ROLLBACK** (a ROLLBACK, a failed transaction body, a failed COMMIT, a
  session's teardown) undoes the transaction through the in-memory undo log,
  commits the undo's engine transaction, then writes a ROLLED_BACK record, so
  a restart never undoes it again (a later committed change to the same value
  survives).
- **Recovery.** At startup, after the stores open and before anything else
  reads or writes them (`server_init.openTxnUndoLog`), every transaction in
  the log with entries and neither record is undone, newest entry first
  across all of them, through the store's logged write methods (the ROLLBACK
  path). Each entry checks what is there (a node never created is not
  deleted, a property is set back to its old value), so a change whose entry
  was written but which was never made, or never committed, costs nothing,
  and a crash during recovery repeats it. Then the file is emptied. A torn
  last record (its write never finished, so its change was never made) is
  dropped. A log that cannot be opened, or a record that frames but does not
  decode or authenticate, refuses startup. An entry that cannot be undone is
  logged and counted (`txn_undo_wal_recovery_failures_total`) and the rest
  are undone, as ROLLBACK does (where it answers 40003).
- **At-rest encryption.** With `GEODE_TDE_KEY` each record is sealed with
  graph-storage's side-file envelope (AES-256-GCM, kind consumer 3): an entry
  holds property values. A sealed log without the key, a plaintext log with
  one, or a record that fails authentication refuses startup.
- **The file** is emptied whenever no transaction of the running server has
  an open entry. Records carry a random per-start `boot` id beside the
  transaction id, which restarts at 1 in every process.
- **Cost.** One fsync of `txn_undo.wal` per change inside an explicit
  transaction (one per batch of creates), plus one at COMMIT and one at
  ROLLBACK. For auto-commit statements, below.
- **COMMIT is durable.** Once COMMIT returns, every change of the
  transaction has been fsynced to the engine WAL (per-commit fsync), and a
  committed change made inside the transaction is never undone by recovery
  (SONNY-2978: the session's engine transaction no longer batches its WAL
  page images past other transactions' commits on its shard).

Auto-commit statements (SONNY-6658), with the durable undo log installed
(every `geode serve`):

- **One engine transaction, committed at the statement's end.** The
  statement's engine transaction (the one CREATE, MERGE and the batch
  create open, or, for a statement that has none, such as `MATCH ... SET`,
  `MATCH ... DELETE` or `MATCH ... REMOVE`, one opened by its first write
  on that write's shard) is committed when the statement ends, after its
  UNIQUE checks, not when the executor that opened it returns
  (`graph_storage_adapter.commitAutoStatementTxn`). Every change of the
  statement on that shard joins it, so they reach the WAL as one commit,
  last. A change of `MATCH ... SET` used to commit an engine transaction of
  its own each, so a one-node `SET n.a = 1, n.b = 2` now commits once
  instead of twice.
- **The undo goes to disk only when the statement spans engine
  transactions.** A change that commits an engine transaction of its own
  (one on another shard, a relationship between two shards, a batch create,
  a change the engine commits itself) is not the statement's last commit.
  Before it, every entry of the statement's undo record (`statement_undo`)
  not yet on disk, and the intents of the creates it is about to make, are
  appended to `txn_undo.wal` under the statement's own id (top bit set, so
  it never meets a transaction's) with one fsync
  (`statement_undo.beforeOwnEngineCommit`). When the statement ends, the
  rest is written, its engine transaction commits, and a COMMITTED record
  seals it: its commit point (the statement fails, and is undone, if it
  cannot be written). A statement whose changes all join its engine
  transaction writes nothing to the log: no extra fsync.
- **A failed statement** is undone through its record, as before; its
  engine transaction, which the undo joined, commits; then, if it went to
  the log, ROLLED_BACK is written.
- **Recovery** is the transactions': a statement with entries and neither
  record is undone at startup.
- **Cost.** Nothing for a statement whose changes are on one shard. For one
  that spans shards: one fsync of the log before each change that commits
  on its own (that change's own engine commit was already an fsync), one
  before the statement's engine commit and one for COMMITTED.
- **Errors.** A write whose undo cannot be put on disk is refused and the
  statement undone: 40000 ("The statement's undo could not be written to
  the durable undo log"). An engine commit of the statement that fails:
  40000 ("The statement's changes could not be committed to storage"), and
  the graph is quarantined as for any failed commit (SONNY-6529).

Residuals:

- **Auto-commit statements outside the log or the statement scope.** An
  embedding caller with no durable undo log installed, and the write paths
  that run outside an executor statement (the bulk MERGE fast path, the
  group-commit node path), commit as before; a program of several
  auto-commit statements is atomic per statement, not as a whole. A
  statement's write made on a worker thread that joined it (SONNY-6362)
  commits on its own, after the statement's undo is on disk.
- **Isolation is unchanged.** As at ROLLBACK, the undo at recovery restores
  the values the transaction found; a change another session committed on
  top of an uncommitted change of the transaction is overwritten by it.
- **Write paths outside the statement undo record** (the bulk MERGE fast
  path, the group-commit node path that allocates the engine slot before
  the store records the create) log a create after it, not before; those
  paths are not used inside an explicit transaction today.
- **Why not one commit record in graph-storage (SONNY-2979 option B).** The
  engine's WAL holds full page after-images, and transactions on one shard
  share pages, so another transaction's committed image of a page carries an
  open transaction's bytes: recovery that skips the open transaction's own
  records still restores them (shown with a real crash: an open
  transaction's node is resurrected by a second transaction's commit of the
  same node page). Rolling them back inside the engine needs a complete,
  durable logical undo there, and the engine refuses one for writes geode
  makes (a label on an existing node, an edge-property page geode images
  itself, a legacy property chain: `AbortNotUndone`). geode's own undo
  entries are complete and logical, so the log lives in geode.

`zig build test-sonny2979-txn-crash-atomicity` kills a real server with two
transactions open and finds nothing of them after the restart;
`zig build test-sonny2979-txn-commit-durable` checks that committed
transactions survive whole, that a rolled-back one is not undone again, and
the sealed log under `GEODE_TDE_KEY`; `zig build
test-sonny2979-undo-wal-format` covers the record format, torn tails, the
choice of transactions to undo, and the file's lifecycle.

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
