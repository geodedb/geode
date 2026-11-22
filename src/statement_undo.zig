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
//! the compensating changes, before the error is returned. SONNY-3381: the
//! full-text and advanced (vector, ...) indexes the executor maintains beside
//! the store cannot take back one change; every one covering a change the
//! replay reverted is rebuilt from the store once it is done
//! (`txn_undo_log.IndexRepair`, `execution/undo_index_repair.zig`), and so on
//! ROLLBACK. The round 17
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
//! SONNY-6362: the record is the statement's, not the thread's. A thread
//! that works for the statement joins it (`current` on the statement's
//! thread, `attach` / `detach` on the worker; the parallel UNION arms,
//! `set_operations.tryParallelUnion`, do), and its writes are recorded, and
//! undone, and checked at the statement's end (`unique_constraints`), with the
//! statement's own. Every change to the record takes its mutex. Only the
//! statement's thread finishes it, after its workers have joined. (The record
//! was per thread: a write another thread made for the statement was neither
//! undone nor seen by the end-of-statement constraint checks.)
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
const update_counts = @import("update_counts.zig");
const txn_durable_undo = @import("txn_durable_undo.zig");
const logging = @import("logging");
const log = logging.scoped("statement_undo");
const Attr = logging.Attr;

pub const UndoEntry = txn_undo_log.UndoEntry;

/// The record's allocator: the testing allocator under test, so the leak
/// checker sees the record. Entries adopted by a transaction are copied into
/// the undo log's own allocator.
pub const allocator: std.mem.Allocator = if (builtin.is_test) std.testing.allocator else std.heap.smp_allocator;

// CANARY: REQ=REQ-SONNY-6362-STATEMENT-RECORD; FEATURE="Execution"; ASPECT=StatementScopedRecord; STATUS=TESTED; TEST=tests/test_sonny6362_statement_undo_threads.zig; OWNER=execution; UPDATED=2026-11-12
/// SONNY-6362: one statement's undo record, shared by the threads that work
/// for it. Every field is guarded by `mutex`; the statement's own thread
/// reads it unlocked only once its workers have joined (`entries`,
/// `pendingCount`, `recordStore`, the finish).
pub const Record = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    entries: std.ArrayListUnmanaged(UndoEntry) = .empty,
    /// The store the record's changes were made on (the first one recorded).
    store: ?*graph_store.GraphStore = null,
    /// SONNY-3348 (round 19): the record's bytes (`entryBytes`), and whether
    /// a write was refused because the record would not fit the budget.
    bytes: u64 = 0,
    budget_exceeded: bool = false,
    /// Slots `reserve` promised to creates that have not recorded themselves
    /// yet: with several threads one free slot is not one per create. A
    /// create that fails after its `reserve` leaves its slot reserved, which
    /// only keeps the record's capacity one entry larger.
    reserved: usize = 0,
    /// SONNY-6658: the statement runs outside an explicit transaction (set
    /// when it opens).
    auto_commit: bool = false,
    /// SONNY-6658: its id in the durable undo log once a change of it
    /// committed an engine transaction of its own (`beforeOwnEngineCommit`),
    /// else 0; `entries[0..logged]` are on disk.
    durable_id: u64 = 0,
    logged: usize = 0,
    /// SONNY-6658: create intents (`noteCreateIntents`) not on disk yet. They
    /// own no memory (the graph's name is not kept).
    intents: std.ArrayListUnmanaged(UndoEntry) = .empty,
    /// SONNY-2822: the changes recorded so far, for the statement's update
    /// counts once it succeeds (`finishSucceeded`).
    counts: update_counts.UpdateCounts = .{},

    fn lock(self: *Record) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    fn unlock(self: *Record) void {
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }
};

/// The record of the statement open on this thread.
threadlocal var t_own: Record = .{};
/// The record this thread's writes go to: `t_own` while its statement is
/// open, the joined statement's while it works for one (`attach`), else null.
threadlocal var t_record: ?*Record = null;
/// This thread works for another thread's statement (`attach`): a statement
/// scope it opens is nested in that one.
threadlocal var t_attached: bool = false;
threadlocal var t_suspended: u32 = 0;

/// SONNY-3348: counters for tests and diagnostics (exported as
/// `statement_undo_*` by the metrics registry, `registerAll`).
pub var replayed_statements_total: std.atomic.Value(u64) = .init(0);
pub var replay_failures_total: std.atomic.Value(u64) = .init(0);
pub var budget_refusals_total: std.atomic.Value(u64) = .init(0);
/// SONNY-6362: threads that joined a statement's record (tests).
pub var attached_threads_total: std.atomic.Value(u64) = .init(0);

/// Test seam (test builds only): the next this many undo entries, of a
/// statement's replay or a transaction's rollback, fail as an engine error
/// would.
pub var test_fail_undo_entries: std.atomic.Value(u32) = .init(0);

// CANARY: REQ=REQ-SONNY-6658-STATEMENT-KILL-HOOK; FEATURE="TransactionManagement"; ASPECT=CrashPointHook; STATUS=TESTED; TEST=tests/test_sonny6658_autocommit_crash_atomicity.zig; OWNER=storage; UPDATED=2026-11-16
/// SONNY-6658: a crash point for tests, compiled only into test and Debug
/// builds (release builds are ReleaseSafe or ReleaseFast and have none of
/// it). Armed with a property key and a count `n` (`armTestKill`): the
/// process kills itself (SIGKILL) when a statement is about to set that key
/// on a node for the (n+1)th time, so exactly `n` such changes were made
/// before it. A spawned Debug `geode serve` arms it from
/// GEODE_TEST_STATEMENT_KILL_KEY and GEODE_TEST_STATEMENT_KILL_AFTER.
pub const kill_hook_available = builtin.is_test or builtin.mode == .Debug;
var kill_key_buf: [64]u8 = undefined;
var kill_key_len: usize = 0;
var kill_after: std.atomic.Value(u32) = .init(0);
var kill_seen: std.atomic.Value(u32) = .init(0);

pub fn armTestKill(key: []const u8, after: u32) error{ KillHookUnavailable, NameTooLong }!void {
    if (comptime !kill_hook_available) return error.KillHookUnavailable;
    if (key.len > kill_key_buf.len) return error.NameTooLong;
    kill_after.store(0, .release);
    @memcpy(kill_key_buf[0..key.len], key);
    kill_key_len = key.len;
    kill_seen.store(0, .release);
    kill_after.store(after, .release);
}

fn testKillPoint(entry: UndoEntry) void {
    if (comptime !kill_hook_available) return;
    const after = kill_after.load(.acquire);
    if (after == 0) return;
    const key = switch (entry) {
        .SetNodeProperty => |e| e.key,
        else => return,
    };
    if (!std.mem.eql(u8, key, kill_key_buf[0..kill_key_len])) return;
    if (kill_seen.fetchAdd(1, .acq_rel) < after) return;
    log.warn("TEST HOOK: killing the process at a statement's change (Debug build only)", &.{Attr.uint("changes_made", after)});
    std.posix.raise(.KILL) catch {};
}

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
    t_own.lock();
    defer t_own.unlock();
    return t_own.budget_exceeded;
}

/// The record's bytes so far (tests).
pub fn recordBytes() u64 {
    t_own.lock();
    defer t_own.unlock();
    return t_own.bytes;
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

/// Would `extra` more bytes of `rec` take the statement past its write
/// budget (the record plus the write executor's working set)? `rec` locked.
fn overBudget(rec: *const Record, extra: u64) bool {
    const budget = write_budget.budgetBytes();
    if (budget == write_budget.unlimited) return false;
    const live: u64 = if (write_budget.activeScope()) |scope| scope.live_bytes else 0;
    return rec.bytes +| extra +| live > budget;
}

/// The write the record could not take is not made, and the statement
/// fails at its relay with the write budget's error (the fence refuses its
/// other writes meanwhile). `rec` locked.
fn refuseOverBudget(rec: *Record) error{OutOfMemory}!void {
    if (!rec.budget_exceeded) _ = budget_refusals_total.fetchAdd(1, .monotonic);
    rec.budget_exceeded = true;
    @import("eval.zig").recordLimitError(error.OutOfMemory);
    return error.OutOfMemory;
}

/// Is a statement's record open on this thread (its own, or one it joined),
/// and not suspended? The store records a change only then.
pub fn capturing() bool {
    return t_record != null and t_suspended == 0;
}

/// SONNY-6362: the record of the statement this thread works for, for a
/// thread it hands part of the statement to (`attach`); null outside one.
pub fn current() ?*Record {
    return t_record;
}

/// SONNY-6362: this thread works for the statement `rec` is the record of,
/// until `detach`: its writes are recorded there, undone if the statement
/// fails and checked when it ends. Null (no statement) records nothing. The
/// statement's thread must not finish the statement before `detach`.
pub fn attach(rec: ?*Record) void {
    const r = rec orelse return;
    if (r == &t_own) return;
    t_record = r;
    t_attached = true;
    _ = attached_threads_total.fetchAdd(1, .monotonic);
}

/// SONNY-6362: this thread no longer works for the statement it joined.
pub fn detach() void {
    if (!t_attached) return;
    t_record = null;
    t_attached = false;
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
/// (`owns` false), or one a thread working for another thread's statement
/// opens, adds to its enclosing statement's record.
pub fn begin(owns: bool) void {
    if (!owns or t_attached) return;
    discardAll();
    t_own.budget_exceeded = false;
    t_own.auto_commit = !txn_undo_log.threadInTxn();
    t_record = &t_own;
}

// CANARY: REQ=REQ-SONNY-6658-AUTOCOMMIT-ATOMIC; FEATURE="TransactionManagement"; ASPECT=StatementDurableUndo; STATUS=TESTED; TEST=tests/test_sonny6658_autocommit_crash_atomicity.zig; OWNER=storage; UPDATED=2026-11-16
// SONNY-6658: an auto-commit statement is crash-atomic. Its changes on the
// shard of its engine transaction commit together when it ends
// (`graph_storage_adapter.commitAutoStatementTxn`); a change that commits an
// engine transaction of its own (another shard, or a write the engine
// commits itself) is not the statement's last commit, so before it the
// statement's record is written to the durable undo log (`txn_durable_undo`,
// one fsync for every entry not on disk yet, create intents included), under
// an id of its own. When the statement ends it writes what is left, commits
// its engine transaction, and seals itself with COMMITTED; a failed one,
// once its undo committed, with ROLLED_BACK. A restart undoes a statement
// with neither, as a transaction. A statement whose changes all join its
// engine transaction writes nothing to the log.

/// The record of an auto-commit statement this thread changes data for
/// (its own, or one it joined), with the durable undo log installed; null
/// otherwise (an explicit transaction logs every entry itself).
fn autoCommitRecord() ?*Record {
    if (!capturing()) return null;
    const rec = t_record.?;
    if (!rec.auto_commit or txn_durable_undo.current() == null) return null;
    return rec;
}

/// Is an auto-commit statement of this thread's own open (the thread that
/// ends it), with the durable undo log installed?
pub fn autoCommitStatementOpen() bool {
    return t_record == &t_own and t_suspended == 0 and t_own.auto_commit and txn_durable_undo.current() != null;
}

/// Does a create about to be made need its intent noted
/// (`noteCreateIntents`)?
pub fn wantsCreateIntents() bool {
    return autoCommitRecord() != null;
}

/// Creates are about to make the ids of `intents` (CreateNode or CreateEdge,
/// owning no memory): kept in memory, written by the next flush.
pub fn noteCreateIntents(intents: []const UndoEntry) error{OutOfMemory}!void {
    const rec = autoCommitRecord() orelse return;
    rec.lock();
    defer rec.unlock();
    try rec.intents.appendSlice(allocator, intents);
}

/// What a write is refused with when its statement's undo cannot be put on
/// disk before it.
pub const DurableError = error{StatementUndoNotDurable};

/// Write the entries and intents of `rec` not on disk yet, with one fsync,
/// under its durable id (given now if it has none). `rec` locked.
fn flushLocked(rec: *Record) DurableError!void {
    if (rec.durable_id == 0) rec.durable_id = txn_durable_undo.newStatementId();
    const pending = rec.entries.items[rec.logged..];
    if (pending.len == 0 and rec.intents.items.len == 0) return;
    const batch = allocator.alloc(UndoEntry, rec.intents.items.len + pending.len) catch return refuseNotDurable(error.OutOfMemory);
    defer allocator.free(batch);
    @memcpy(batch[0..rec.intents.items.len], rec.intents.items);
    @memcpy(batch[rec.intents.items.len..], pending);
    txn_durable_undo.logStatementEntries(rec.durable_id, batch) catch |err| return refuseNotDurable(err);
    rec.logged = rec.entries.items.len;
    rec.intents.clearRetainingCapacity();
}

fn refuseNotDurable(err: anyerror) DurableError {
    log.err("could not write an auto-commit statement's undo to the durable undo log; the change is refused and the statement fails", &.{Attr.string("error", @errorName(err))});
    return error.StatementUndoNotDurable;
}

/// A change of the statement this thread works for is about to commit an
/// engine transaction that is not the statement's last: its undo, and every
/// other change's, goes to disk first. No-op outside an auto-commit
/// statement or without the durable undo log.
pub fn beforeOwnEngineCommit() DurableError!void {
    const rec = autoCommitRecord() orelse return;
    rec.lock();
    defer rec.unlock();
    try flushLocked(rec);
}

/// The open auto-commit statement of this thread succeeded: when it went
/// durable, what is not on disk yet is written, before its engine
/// transaction commits. Its workers have joined.
pub fn flushBeforeStatementCommit() DurableError!void {
    if (t_own.durable_id == 0) return;
    t_own.lock();
    defer t_own.unlock();
    try flushLocked(&t_own);
}

/// The durable id of this thread's statement, 0 when it never went durable.
pub fn durableId() u64 {
    return t_own.durable_id;
}

/// The durable id of this thread's statement, which is no longer its
/// (sealed, or handed to the failed statement's end).
pub fn takeDurableId() u64 {
    const id = t_own.durable_id;
    t_own.durable_id = 0;
    return id;
}

/// The statement that opened the scope `owns` failed: undo its changes.
/// False when an entry could not be undone (the statement is then partly
/// applied, and fails with `error.StatementUndoIncomplete`).
pub fn finishFailed(owns: bool) bool {
    if (!owns or t_attached) return true;
    t_record = null;
    return replay();
}

/// The statement that opened the scope `owns` succeeded. Inside an explicit
/// transaction its record joins the transaction's undo log; if that fails
/// (out of memory), the statement's changes are undone and the error
/// returned, so the transaction never keeps a change ROLLBACK cannot undo.
pub fn finishSucceeded(owns: bool) error{ OutOfMemory, StatementUndoIncomplete }!void {
    if (!owns or t_attached) return;
    t_record = null;
    // SONNY-2822: its counts are the program's once it is done (not when
    // its record cannot join the transaction and it is undone instead).
    const counts = t_own.counts;
    if (t_own.entries.items.len == 0 or !txn_undo_log.threadInTxn()) {
        discardAll();
        update_counts.noteCommitted(counts);
        return;
    }
    txn_undo_log.getGlobalUndoLog(allocator).adoptStatementEntries(t_own.entries.items) catch |err| {
        if (!replay()) return error.StatementUndoIncomplete;
        return err;
    };
    discardAll();
    update_counts.noteCommitted(counts);
}

/// Room for `n` more entries, so a create can record itself after it
/// succeeded without an allocation that could fail.
pub fn reserve(n: usize) error{OutOfMemory}!void {
    if (!capturing()) return;
    const rec = t_record.?;
    rec.lock();
    defer rec.unlock();
    if (overBudget(rec, @as(u64, n) * @sizeOf(UndoEntry))) return refuseOverBudget(rec);
    try rec.entries.ensureUnusedCapacity(allocator, rec.reserved + n);
    rec.reserved += n;
}

/// Record `entry` for `store`. The entry's memory is `allocator`'s and is
/// owned by the record from here on, also when this fails.
pub fn append(store: *graph_store.GraphStore, entry: UndoEntry) error{OutOfMemory}!void {
    if (!capturing()) {
        txn_undo_log.freeEntryWith(allocator, entry);
        return;
    }
    testKillPoint(entry); // SONNY-6658
    // SONNY-2979: inside an explicit transaction the entry is on disk
    // before the change it undoes is made (write-ahead), so a crash cannot
    // leave a change no restart can undo. A failure refuses the write.
    txn_durable_undo.logForThread(&.{entry}) catch |err| {
        txn_undo_log.freeEntryWith(allocator, entry);
        log.err("could not write a transaction's undo entry to the durable undo log; the change is refused", &.{Attr.string("error", @errorName(err))});
        return error.OutOfMemory;
    };
    const rec = t_record.?;
    rec.lock();
    defer rec.unlock();
    const bytes = entryBytes(entry);
    if (overBudget(rec, bytes)) {
        txn_undo_log.freeEntryWith(allocator, entry);
        return refuseOverBudget(rec);
    }
    // Room promised to a create (`reserve`) stays free for it.
    rec.entries.ensureUnusedCapacity(allocator, rec.reserved + 1) catch |err| {
        txn_undo_log.freeEntryWith(allocator, entry);
        return err;
    };
    rec.entries.appendAssumeCapacity(entry);
    rec.bytes += bytes;
    rec.counts.countEntry(entry); // SONNY-2822
    if (rec.store == null) rec.store = store;
}

/// Record a created node or edge, in room `reserve` made. Owns no memory
/// (the graph's name is not kept: the undo deletes by id).
pub fn appendCreated(store: *graph_store.GraphStore, entry: UndoEntry) void {
    if (!capturing()) return;
    // SONNY-2979: a create path that logged no intent before the create
    // (`txn_durable_undo.noteCreateIntent`) logs the create now.
    txn_durable_undo.noteCreated(entry) catch |err| {
        log.err("could not write a created entity to the durable undo log; the statement fails and is undone", &.{Attr.string("error", @errorName(err))});
        @import("eval.zig").recordLimitError(error.OutOfMemory);
    };
    const rec = t_record.?;
    rec.lock();
    defer rec.unlock();
    // The create happened: it is recorded, so it can be undone, and past
    // the budget the statement fails.
    // SONNY-6658: the creates whose intents were noted are done: each one's
    // own entry is recorded now, so the intents are no longer needed.
    rec.intents.clearRetainingCapacity();
    const bytes = entryBytes(entry);
    if (overBudget(rec, bytes)) refuseOverBudget(rec) catch {};
    if (rec.reserved > 0 and rec.entries.unusedCapacitySlice().len > 0) {
        rec.reserved -= 1;
        rec.entries.appendAssumeCapacity(entry);
    } else {
        // No room reserved (a create path this module does not know):
        // record it if memory allows; otherwise the statement fails with
        // out of memory, and what was recorded is undone.
        rec.entries.append(allocator, entry) catch {
            @import("eval.zig").recordLimitError(error.OutOfMemory);
            return;
        };
    }
    rec.bytes += bytes;
    rec.counts.countEntry(entry); // SONNY-2822
    if (rec.store == null) rec.store = store;
}

// CANARY: REQ=REQ-SONNY-2822-UPDATE-COUNTS; FEATURE="WireProtocol"; ASPECT=CreatedNodeLabels; STATUS=TESTED; TEST=tests/test_sonny2822_update_counts.zig; OWNER=storage; UPDATED=2026-11-22
/// SONNY-2822: a node the open statement created carries `n` labels: they
/// count as labels added (its properties count as they are set). Recorded
/// with the node's `appendCreated`; nothing outside a statement's record.
pub fn noteCreatedNodeLabels(n: usize) void {
    if (!capturing() or n == 0) return;
    const rec = t_record.?;
    rec.lock();
    defer rec.unlock();
    rec.counts.labels_added +|= n;
}

/// Undo the record newest first, through the store's logged write methods,
/// then empty it. An entry that cannot be undone is logged, counted and
/// skipped, and the rest are undone; false when one could not be.
fn replay() bool {
    defer discardAll();
    if (t_own.entries.items.len == 0) return true;
    const store = t_own.store orelse return true;
    suspendCapture();
    defer resumeCapture();
    // SONNY-6716: the failed statement may have filled the buffer pool; its undo
    // pins pages too and may use the frames the pool keeps back for it.
    graph_store.enterStatementUndo();
    defer graph_store.leaveStatementUndo();
    _ = replayed_statements_total.fetchAdd(1, .monotonic);
    // SONNY-3381: the full-text and vector indexes the executor keeps beside
    // the store are rebuilt for what the replay reverted, once it is done.
    var repair = txn_undo_log.IndexRepair.init(allocator);
    defer repair.finish(store);
    var complete = true;
    var i: usize = t_own.entries.items.len;
    while (i > 0) {
        i -= 1;
        (if (takeTestUndoFailure()) error.InjectedUndoFailure else txn_undo_log.undoEntryLogged(store, t_own.entries.items[i], &repair)) catch |err| {
            complete = false;
            _ = replay_failures_total.fetchAdd(1, .monotonic);
            log.err("statement undo: an entry could not be undone; the failed statement is partly applied", &.{Attr.string("error", @errorName(err))});
        };
    }
    return complete;
}

fn discardAll() void {
    for (t_own.entries.items) |entry| txn_undo_log.freeEntryWith(allocator, entry);
    t_own.entries.clearAndFree(allocator);
    t_own.store = null;
    t_own.bytes = 0;
    t_own.reserved = 0;
    t_own.intents.clearAndFree(allocator); // SONNY-6658
    t_own.durable_id = 0;
    t_own.logged = 0;
    t_own.counts = .{}; // SONNY-2822
}

/// Entries the open record holds (tests).
pub fn pendingCount() usize {
    return t_own.entries.items.len;
}

/// SONNY-2846: the open record's entries, oldest first, for the UNIQUE
/// check at the end of the statement (`execution/unique_constraints.zig`):
/// every node the statement created, changed a property of, or added a
/// label to is in it. Borrowed; valid until the record is finished.
pub fn entries() []const UndoEntry {
    return t_own.entries.items;
}

/// SONNY-2846: the store the open record's changes were made on, if any.
pub fn recordStore() ?*graph_store.GraphStore {
    return t_own.store;
}
