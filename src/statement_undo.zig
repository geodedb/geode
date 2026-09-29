// CANARY: REQ=REQ-SONNY-3348-LIMIT-ATOMICITY; FEATURE="Execution"; ASPECT=StatementUndoRecord; STATUS=TESTED; TEST=tests/test_sonny3348_statement_undo.zig; OWNER=storage; UPDATED=2026-09-28
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
//!
//! SONNY-3348 (round 19): the record's memory counts against the statement's
//! write budget (`write_budget`, `GEODE_WRITE_EXECUTOR_BUDGET_MB`, 8192 MB by
//! default, 0 for none): the record and the write executor's working set
//! together stay under it. A write whose record would not fit is not made;
//! the statement fails with the write budget's error (53200,
//! `error.WriteQueryBudgetExceeded`, `budgetExceeded`) and undoes what it
//! recorded. `MATCH (n) DETACH DELETE n` over a graph whose images do not fit
//! so answers 53200 and leaves the graph as it was.
//!
//! An entry that cannot be undone is logged, counted
//! (`statement_undo_replay_failures_total`), and reported: the statement fails
//! with `error.StatementUndoIncomplete` (40003, "statement completion
//! unknown"), not its own error, so a client does not retry a statement that
//! is partly applied.

const std = @import("std");
const builtin = @import("builtin");
const graph_store = @import("graph_store.zig");
const txn_undo_log = @import("txn_undo_log.zig");
const write_budget = @import("write_budget.zig");
const logging = @import("logging");
const log = logging.scoped("statement_undo");
const Attr = logging.Attr;

pub const UndoEntry = txn_undo_log.UndoEntry;

/// The record's allocator: the testing allocator under test, so the leak
/// checker sees the record. Entries adopted by a transaction are copied into
/// the undo log's own allocator.
pub const allocator: std.mem.Allocator = if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;

threadlocal var t_active: bool = false;
threadlocal var t_suspended: u32 = 0;
threadlocal var t_entries: std.ArrayListUnmanaged(UndoEntry) = .empty;
/// The store the record's changes were made on (the first one recorded).
threadlocal var t_store: ?*graph_store.GraphStore = null;
/// SONNY-3348 (round 19): the record's bytes (`entryBytes`), and whether a
/// write was refused because the record would not fit the budget.
threadlocal var t_bytes: u64 = 0;
threadlocal var t_budget_exceeded: bool = false;

/// SONNY-3348: counters for tests and diagnostics (exported as
/// `statement_undo_*` by the metrics registry, `registerAll`).
pub var replayed_statements_total: std.atomic.Value(u64) = .init(0);
pub var replay_failures_total: std.atomic.Value(u64) = .init(0);
pub var budget_refusals_total: std.atomic.Value(u64) = .init(0);

/// Test seam (test builds only): the next this many undo entries, of a
/// statement's replay or a transaction's rollback, fail as an engine error
/// would.
pub var test_fail_undo_entries: std.atomic.Value(u32) = .init(0);

/// SONNY-3348 (round 19, m3): should this undo entry fail (the test seam)?
pub fn takeTestUndoFailure() bool {
    if (!builtin.is_test) return false;
    var n = test_fail_undo_entries.load(.acquire);
    while (n > 0) {
        n = test_fail_undo_entries.cmpxchgWeak(n, n - 1, .acq_rel, .acquire) orelse return true;
    }
    return false;
}

/// Called from main.zig after the metrics registry is created.
pub fn registerAll(registry: anytype) !void {
    try registry.register("statement_undo_replayed_statements_total", &replayed_statements_total);
    try registry.register("statement_undo_replay_failures_total", &replay_failures_total);
    try registry.register("statement_undo_budget_refusals_total", &budget_refusals_total);
}

/// Did the open (or last) statement refuse a write because its record would
/// not fit the write budget? Its relay then fails it with 53200.
pub fn budgetExceeded() bool {
    return t_budget_exceeded;
}

/// The record's bytes so far (tests).
pub fn recordBytes() u64 {
    return t_bytes;
}

fn propertyBytes(p: txn_undo_log.SerializedProperty) u64 {
    var n: u64 = @sizeOf(txn_undo_log.SerializedProperty) + p.key.len;
    if (p.string_value) |v| n += v.len;
    if (p.binary_value) |v| n += v.len;
    return n;
}

/// The memory `entry` holds, its slot in the record included.
fn entryBytes(entry: UndoEntry) u64 {
    var n: u64 = @sizeOf(UndoEntry);
    switch (entry) {
        .CreateNode => |e| n += e.graph_name.len,
        .CreateEdge => |e| n += e.graph_name.len,
        .SetNodeProperty => |e| n += e.key.len + propertyBytes(e.old_value),
        .SetEdgeProperty => |e| n += e.key.len + propertyBytes(e.old_value),
        .RemoveNodeProperty => |e| n += propertyBytes(e.old_value),
        .RemoveEdgeProperty => |e| n += propertyBytes(e.old_value),
        .DeleteNode => |e| {
            n += e.graph_name.len + e.tenant_id.len + e.labels.len * @sizeOf([]const u8);
            for (e.labels) |l| n += l.len;
            for (e.properties) |p| n += propertyBytes(p);
        },
        .DeleteEdge => |e| {
            n += e.graph_name.len + e.tenant_id.len + e.label.len;
            for (e.properties) |p| n += propertyBytes(p);
        },
        .AddNodeLabel => |e| n += e.label.len,
        .RemoveNodeLabel => |e| n += e.label.len,
    }
    return n;
}

/// Would `extra` more bytes of record take the statement past its write
/// budget (the record plus the write executor's working set)?
fn overBudget(extra: u64) bool {
    const budget = write_budget.budgetBytes();
    if (budget == write_budget.unlimited) return false;
    const live: u64 = if (write_budget.activeScope()) |scope| scope.live_bytes else 0;
    return t_bytes +| extra +| live > budget;
}

/// The write the record could not take is not made, and the statement
/// fails at its relay with the write budget's error (the fence refuses its
/// other writes meanwhile).
fn refuseOverBudget() error{OutOfMemory}!void {
    if (!t_budget_exceeded) _ = budget_refusals_total.fetchAdd(1, .monotonic);
    t_budget_exceeded = true;
    @import("eval.zig").recordLimitError(error.OutOfMemory);
    return error.OutOfMemory;
}

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
    t_budget_exceeded = false;
    t_active = true;
}

/// The statement that opened the scope `owns` failed: undo its changes.
/// False when an entry could not be undone (the statement is then partly
/// applied, and fails with `error.StatementUndoIncomplete`).
pub fn finishFailed(owns: bool) bool {
    if (!owns) return true;
    t_active = false;
    return replay();
}

/// The statement that opened the scope `owns` succeeded. Inside an explicit
/// transaction its record joins the transaction's undo log; if that fails
/// (out of memory), the statement's changes are undone and the error
/// returned, so the transaction never keeps a change ROLLBACK cannot undo.
pub fn finishSucceeded(owns: bool) error{ OutOfMemory, StatementUndoIncomplete }!void {
    if (!owns) return;
    t_active = false;
    if (t_entries.items.len == 0 or !txn_undo_log.threadInTxn()) {
        discardAll();
        return;
    }
    txn_undo_log.getGlobalUndoLog(allocator).adoptStatementEntries(t_entries.items) catch |err| {
        if (!replay()) return error.StatementUndoIncomplete;
        return err;
    };
    discardAll();
}

/// Room for `n` more entries, so a create can record itself after it
/// succeeded without an allocation that could fail.
pub fn reserve(n: usize) error{OutOfMemory}!void {
    if (!capturing()) return;
    if (overBudget(@as(u64, n) * @sizeOf(UndoEntry))) return refuseOverBudget();
    try t_entries.ensureUnusedCapacity(allocator, n);
}

/// Record `entry` for `store`. The entry's memory is `allocator`'s and is
/// owned by the record from here on, also when this fails.
pub fn append(store: *graph_store.GraphStore, entry: UndoEntry) error{OutOfMemory}!void {
    if (!capturing()) {
        txn_undo_log.freeEntryWith(allocator, entry);
        return;
    }
    const bytes = entryBytes(entry);
    if (overBudget(bytes)) {
        txn_undo_log.freeEntryWith(allocator, entry);
        return refuseOverBudget();
    }
    t_entries.append(allocator, entry) catch |err| {
        txn_undo_log.freeEntryWith(allocator, entry);
        return err;
    };
    t_bytes += bytes;
    if (t_store == null) t_store = store;
}

/// Record a created node or edge, in room `reserve` made. Owns no memory
/// (the graph's name is not kept: the undo deletes by id).
pub fn appendCreated(store: *graph_store.GraphStore, entry: UndoEntry) void {
    if (!capturing()) return;
    // The create happened: it is recorded, so it can be undone, and past
    // the budget the statement fails.
    const bytes = entryBytes(entry);
    if (overBudget(bytes)) refuseOverBudget() catch {};
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
    t_bytes += bytes;
    if (t_store == null) t_store = store;
}

/// Undo the record newest first, through the store's logged write methods,
/// then empty it. An entry that cannot be undone is logged, counted and
/// skipped, and the rest are undone; false when one could not be.
fn replay() bool {
    defer discardAll();
    if (t_entries.items.len == 0) return true;
    const store = t_store orelse return true;
    suspendCapture();
    defer resumeCapture();
    _ = replayed_statements_total.fetchAdd(1, .monotonic);
    var complete = true;
    var i: usize = t_entries.items.len;
    while (i > 0) {
        i -= 1;
        (if (takeTestUndoFailure()) error.InjectedUndoFailure else txn_undo_log.undoEntryLogged(store, t_entries.items[i])) catch |err| {
            complete = false;
            _ = replay_failures_total.fetchAdd(1, .monotonic);
            log.err("statement undo: an entry could not be undone; the failed statement is partly applied", &.{Attr.string("error", @errorName(err))});
        };
    }
    return complete;
}

fn discardAll() void {
    for (t_entries.items) |entry| txn_undo_log.freeEntryWith(allocator, entry);
    t_entries.clearAndFree(allocator);
    t_store = null;
    t_bytes = 0;
}

/// Entries the open record holds (tests).
pub fn pendingCount() usize {
    return t_entries.items.len;
}
