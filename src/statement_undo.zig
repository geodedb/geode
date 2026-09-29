// CANARY: REQ=REQ-SONNY-3348-LIMIT-ATOMICITY; FEATURE="Execution"; ASPECT=StatementUndoRecord; STATUS=TESTED; TEST=tests/test_sonny3348_limit_atomicity.zig; OWNER=storage; UPDATED=2026-09-28
//! SONNY-3348 (round 18): the statement undo record.
//!
//! A statement that fails leaves nothing behind. While the outermost
//! statement scope on a thread is open (`execution.executeStatementWithContext`,
//! `planned_read_runtime.executeProfiledIfSupported`), every graph-store
//! write method records the state it is about to change, before it changes
//! it, as a `txn_undo_log.UndoEntry` (all 10 kinds: created node or edge,
//! deleted node or edge with its labels, properties and tenant, a property's
//! old value or its absence, a label added or removed). Every executor
//! changes data through those methods (the legacy MATCH executor, the write
//! step, the point-write fast path, CREATE, MERGE, FOR, DELETE, PROFILE,
//! procedures), so the record covers them all.
//!
//! When the statement fails, for any reason (the relay's 54001, out of
//! memory, read budget or IN type error, or any other error), the record is
//! replayed newest first through the store's normal, logged write methods,
//! so the storage engine, the WAL mutation stream and the store's indexes see
//! the compensating changes, before the error is returned. The round 17
//! write fence (`graph_store.statementWriteFence`) only stopped the writes
//! after the limit was recorded: earlier rows, a SET before a RETURN or a WITH
//! evaluated late, and the point-write fast path kept theirs.
//!
//! When the statement succeeds inside an explicit transaction, its record is
//! appended to the transaction's undo log (`UndoLog.adoptStatementEntries`),
//! so ROLLBACK undoes every statement's changes, not only its CREATEs
//! (SONNY-3059). Outside a transaction the record is dropped.
//!
//! The replay, and the transaction undo (`UndoLog.rollback`), run with
//! capture and the write fence suspended (`suspendCapture`): their writes are
//! not recorded, and a limit the failed statement recorded does not refuse
//! them (round 17 I1: the fence turned a transaction body's rollback into a
//! no-op).
//!
//! The record is per thread: a write another thread makes for the statement
//! is not in it.

const std = @import("std");
const graph_store = @import("graph_store.zig");
const txn_undo_log = @import("txn_undo_log.zig");

pub const UndoEntry = txn_undo_log.UndoEntry;

/// The record's allocator. Entries adopted by a transaction are copied into
/// the undo log's own allocator.
pub const allocator: std.mem.Allocator = std.heap.smp_allocator;

threadlocal var t_active: bool = false;
threadlocal var t_suspended: u32 = 0;
threadlocal var t_entries: std.ArrayListUnmanaged(UndoEntry) = .empty;
/// The store the record's changes were made on (the first one recorded).
threadlocal var t_store: ?*graph_store.GraphStore = null;

/// SONNY-3348: counters for tests and diagnostics.
pub var replayed_statements_total: std.atomic.Value(u64) = .init(0);
pub var replay_failures_total: std.atomic.Value(u64) = .init(0);

/// Is a statement's record open on this thread, and not suspended? The store
/// records a change only then.
pub fn capturing() bool {
    return t_active and t_suspended == 0;
}

/// A replay or a transaction undo is running on this thread: nothing is
/// recorded, and the statement write fence is down.
pub fn suspended() bool {
    return t_suspended != 0;
}

pub fn suspendCapture() void {
    t_suspended += 1;
}

pub fn resumeCapture() void {
    if (t_suspended > 0) t_suspended -= 1;
}

/// Open the record for the statement scope `owns` opened. A nested scope
/// (`owns` false) adds to its enclosing statement's record.
pub fn begin(owns: bool) void {
    if (!owns) return;
    discardAll();
    t_active = true;
}

/// The statement that opened the scope `owns` failed: undo its changes.
pub fn finishFailed(owns: bool) void {
    if (!owns) return;
    t_active = false;
    replay();
}

/// The statement that opened the scope `owns` succeeded. Inside an explicit
/// transaction its record joins the transaction's undo log; if that fails
/// (out of memory), the statement's changes are undone and the error
/// returned, so the transaction never keeps a change ROLLBACK cannot undo.
pub fn finishSucceeded(owns: bool) error{OutOfMemory}!void {
    if (!owns) return;
    t_active = false;
    if (t_entries.items.len == 0 or !txn_undo_log.threadInTxn()) {
        discardAll();
        return;
    }
    txn_undo_log.getGlobalUndoLog(allocator).adoptStatementEntries(t_entries.items) catch |err| {
        replay();
        return err;
    };
    discardAll();
}

/// Room for `n` more entries, so a create can record itself after it
/// succeeded without an allocation that could fail.
pub fn reserve(n: usize) error{OutOfMemory}!void {
    if (!capturing()) return;
    try t_entries.ensureUnusedCapacity(allocator, n);
}

/// Record `entry` for `store`. The entry's memory is `allocator`'s and is
/// owned by the record from here on, also when this fails.
pub fn append(store: *graph_store.GraphStore, entry: UndoEntry) error{OutOfMemory}!void {
    if (!capturing()) {
        txn_undo_log.freeEntryWith(allocator, entry);
        return;
    }
    t_entries.append(allocator, entry) catch |err| {
        txn_undo_log.freeEntryWith(allocator, entry);
        return err;
    };
    if (t_store == null) t_store = store;
}

/// Record a created node or edge, in room `reserve` made. Owns no memory
/// (the graph's name is not kept: the undo deletes by id).
pub fn appendCreated(store: *graph_store.GraphStore, entry: UndoEntry) void {
    if (!capturing()) return;
    if (t_entries.unusedCapacitySlice().len > 0) {
        t_entries.appendAssumeCapacity(entry);
    } else {
        // No room reserved (a create path this module does not know):
        // record it if memory allows; otherwise the statement fails with
        // out of memory, and what was recorded is undone.
        t_entries.append(allocator, entry) catch {
            @import("eval.zig").recordLimitError(error.OutOfMemory);
            return;
        };
    }
    if (t_store == null) t_store = store;
}

/// Undo the record newest first, through the store's logged write methods,
/// then empty it. An entry that cannot be undone is logged and skipped: the
/// statement fails with its own error either way.
fn replay() void {
    defer discardAll();
    if (t_entries.items.len == 0) return;
    const store = t_store orelse return;
    suspendCapture();
    defer resumeCapture();
    _ = replayed_statements_total.fetchAdd(1, .monotonic);
    var i: usize = t_entries.items.len;
    while (i > 0) {
        i -= 1;
        txn_undo_log.undoEntryLogged(store, t_entries.items[i]) catch |err| {
            _ = replay_failures_total.fetchAdd(1, .monotonic);
            std.log.warn("statement undo: an entry could not be undone: {s}", .{@errorName(err)});
        };
    }
}

fn discardAll() void {
    for (t_entries.items) |entry| txn_undo_log.freeEntryWith(allocator, entry);
    t_entries.clearAndFree(allocator);
    t_store = null;
}

/// Entries the open record holds (tests).
pub fn pendingCount() usize {
    return t_entries.items.len;
}
