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

An explicit transaction (BEGIN or START TRANSACTION ... COMMIT, over one
request or several) is atomic across a crash (kill -9, OOM kill, power
loss): after the restart either all of it is there (it committed) or none
of it (it was open, or rolled back).

How:

- **Write-through.** Each change is written to the storage engine as it
  runs. Within one request, the changes on the shard of the session's engine
  transaction commit together when the request's program ends; a change on
  any of the other 15 shards commits its own engine transaction when it
  runs. No engine transaction outlives a request (SONNY-2823). So the engine
  holds an open transaction's earlier requests, and some of its current one.
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
  ROLLBACK. Auto-commit statements write nothing to it.

Residuals:

- **Auto-commit statements** are not covered: a statement outside an
  explicit transaction that changes several shards and is cut by a crash
  keeps the changes already committed in the engine (one engine transaction
  on the statement's shard, one per change on the others). Run it inside
  BEGIN ... COMMIT to make it crash-atomic.
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
