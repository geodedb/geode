const std = @import("std");
const logging = @import("logging");
const undo_log = logging.scoped("txn_undo_log");
const graph_store = @import("graph_store.zig");
const property_codec = @import("property_value_codec.zig");
const statement_undo = @import("statement_undo.zig");
// CANARY: REQ=REQ-TXN-UNDO-SERVER-014; FEATURE="TransactionUndoLog"; ASPECT=GraphCommonImport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
const graph_common = @import("types/graph_common.zig");

// CANARY: REQ=REQ-TXN-UNDO-001; FEATURE="TransactionUndoLog"; ASPECT=UndoLogCore; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
// Transaction undo log for proper ROLLBACK support in CLI mode
// This module tracks all data modifications during a transaction
// and can undo them in reverse order on ROLLBACK

pub const UndoOpType = enum(u8) {
    CreateNode = 1,
    CreateEdge = 2,
    SetNodeProperty = 3,
    RemoveNodeProperty = 4,
    SetEdgeProperty = 5,
    RemoveEdgeProperty = 6,
    DeleteNode = 7,
    DeleteEdge = 8,
    AddNodeLabel = 9,
    RemoveNodeLabel = 10,
};

/// Serializable property value for undo log
pub const SerializedProperty = struct {
    key: []const u8,
    value_type: u8, // 0=null, 1=string, 2=int, 3=float, 4=bool, 5=binary encoded property
    string_value: ?[]const u8 = null,
    binary_value: ?[]const u8 = null,
    int_value: i64 = 0,
    float_value: f64 = 0.0,
    bool_value: bool = false,

    pub fn fromPropertyValue(allocator: std.mem.Allocator, key: []const u8, pv: graph_store.PropertyValue) !SerializedProperty {
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);

        return switch (pv) {
            .Null => .{ .key = key_copy, .value_type = 0 },
            .String => |s| .{
                .key = key_copy,
                .value_type = 1,
                .string_value = try allocator.dupe(u8, s),
            },
            .Int => |i| .{ .key = key_copy, .value_type = 2, .int_value = i },
            .Float => |f| .{ .key = key_copy, .value_type = 3, .float_value = f },
            .Bool => |b| .{ .key = key_copy, .value_type = 4, .bool_value = b },
            .Decimal, .ExtValue => .{
                .key = key_copy,
                .value_type = 5,
                .binary_value = try property_codec.encodePropertyValue(allocator, pv),
            },
        };
    }

    pub fn toPropertyValue(self: SerializedProperty, allocator: std.mem.Allocator) !graph_store.PropertyValue {
        return switch (self.value_type) {
            0 => .Null,
            1 => .{ .String = self.string_value orelse "" },
            2 => .{ .Int = self.int_value },
            3 => .{ .Float = self.float_value },
            4 => .{ .Bool = self.bool_value },
            5 => try property_codec.decodePropertyValue(allocator, self.binary_value orelse return error.InvalidUndoLogProperty),
            else => .Null,
        };
    }

    pub fn deinit(self: SerializedProperty, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        if (self.string_value) |s| allocator.free(s);
        if (self.binary_value) |bytes| allocator.free(bytes);
    }
};

pub const UndoEntry = union(UndoOpType) {
    // On rollback: delete this node
    CreateNode: struct {
        node_id: u64,
        graph_name: []const u8, // Graph where node was created
    },

    // On rollback: delete this edge
    CreateEdge: struct {
        edge_id: u64,
        graph_name: []const u8, // Graph where edge was created
    },

    // On rollback: restore old value or remove property
    SetNodeProperty: struct {
        node_id: u64,
        key: []const u8,
        had_old_value: bool,
        old_value: SerializedProperty,
    },

    // On rollback: restore the removed property
    RemoveNodeProperty: struct {
        node_id: u64,
        old_value: SerializedProperty,
    },

    // On rollback: restore old value or remove property
    SetEdgeProperty: struct {
        edge_id: u64,
        key: []const u8,
        had_old_value: bool,
        old_value: SerializedProperty,
    },

    // On rollback: restore the removed property
    RemoveEdgeProperty: struct {
        edge_id: u64,
        old_value: SerializedProperty,
    },

    // On rollback: recreate the node with its data
    DeleteNode: struct {
        node_id: u64,
        labels: []const []const u8,
        properties: []const SerializedProperty,
        graph_name: []const u8,
        /// SONNY-3348 (round 18): the node's tenant, owned when non-empty;
        /// empty restores it to the default tenant. Not in the CLI file.
        tenant_id: []const u8 = "",
    },

    // On rollback: recreate the edge with its data
    DeleteEdge: struct {
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        label: []const u8,
        properties: []const SerializedProperty,
        graph_name: []const u8,
        /// SONNY-3348 (round 18): as `DeleteNode.tenant_id`.
        tenant_id: []const u8 = "",
    },

    // On rollback: remove the added label
    AddNodeLabel: struct {
        node_id: u64,
        label: []const u8,
    },

    // On rollback: add the removed label back
    RemoveNodeLabel: struct {
        node_id: u64,
        label: []const u8,
    },
};

// CANARY: REQ=REQ-TXN-SAVEPOINT-001; FEATURE="TransactionSavepoints"; ASPECT=UndoLogSavepoint; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-01
/// A savepoint records a named position in one transaction's changes so that
/// rollbackToSavepoint can undo the transaction's later changes without
/// aborting it.
///
/// SONNY-2799: a savepoint belongs to its transaction (`txn_id`), and its
/// position counts that transaction's changes only (`own_count`). It recorded
/// an index into the list every transaction shares: rolling back to it undid,
/// and freed, every later change of every transaction, and any transaction's
/// BEGIN or COMMIT dropped every savepoint.
pub const Savepoint = struct {
    name: []const u8,
    txn_id: u64,
    own_count: usize,
};

// ---------------------------------------------------------------------------
// R1 (2026-04-22): Per-transaction isolation on the process-global undo log.
//
// Before this fix `UndoLog` was a single `ArrayListUnmanaged` with no mutex
// and `begin()` unconditionally called `clear()`.  Under the 16-worker Go-
// client ingest workload that meant:
//
//   - Thread B's `BEGIN` silently wiped Thread A's in-flight entries.
//   - Concurrent `logCreateNode()` calls raced on the shared list → torn
//     writes, lost entries, and occasional double-free in the allocator.
//
// The fix below keeps the single shared list (to preserve the ~60 existing
// callers of `getGlobalUndoLog`) but:
//
//   1. Serialises every mutation of `entries` / `entry_txns` / `savepoints`
//      / `pending_advanced_index_rebuilds` behind `list_mutex`.
//   2. Tags each entry with the caller's `txn_id` (thread-local), so
//      `rollback()`/`commit()` only process entries belonging to the
//      caller's transaction, and `begin()` no longer wipes peers.
//
// The thread-local `t_txn_state` is allocated lazily from a module-level
// atomic counter on `begin()`; public `logXxx` helpers early-return when
// the caller's thread is not in an active transaction, matching the old
// contract.
// ---------------------------------------------------------------------------

const ThreadTxnState = struct {
    txn_id: u64 = 0,
    active: bool = false,
};

threadlocal var t_txn_state: ThreadTxnState = .{};

var g_next_txn_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

fn allocTxnId() u64 {
    return g_next_txn_id.fetchAdd(1, .monotonic);
}

/// Public accessor so `ServerState.tearDownForStreamClose` (R3) can stamp a
/// known txn_id onto the current thread before driving `rollback()`.
pub fn setThreadTxnId(txn_id: u64) void {
    t_txn_state.txn_id = txn_id;
    t_txn_state.active = txn_id != 0;
}

/// Peek at the current thread's undo-log txn_id (0 = none).
pub fn currentThreadTxnId() u64 {
    return t_txn_state.txn_id;
}

// CANARY: REQ=REQ-SONNY-2799-UNDO-PER-TXN; FEATURE="TransactionUndoLog"; ASPECT=ThreadTxn; STATUS=TESTED; TEST=tests/test_sonny2805_txn_sessions.zig; OWNER=engine; UPDATED=2026-09-26
/// SONNY-2799: the transaction open on the calling thread, or 0 for none. A
/// transport handler puts its session's transaction on the thread for one
/// request (`setThreadTxnId`, `ServerState.enterSessionTxn`); `begin` opens one.
/// Every change is recorded under it, and COMMIT and ROLLBACK end it. There
/// is no transaction 0: a thread with none records nothing and undoes nothing.
fn threadTxn() u64 {
    return if (t_txn_state.active) t_txn_state.txn_id else 0;
}

/// Transaction undo log that persists across CLI invocations
pub const UndoLog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(UndoEntry),
    /// Parallel to `entries` — entry_txns[i] is the txn_id that owns entries[i].
    /// Added in R1 so `rollback()`/`commit()` can filter by caller txn.
    entry_txns: std.ArrayListUnmanaged(u64) = .empty,
    active: bool,
    savepoints: std.ArrayListUnmanaged(Savepoint) = .empty,
    pending_advanced_index_rebuilds: std.StringHashMapUnmanaged(void) = .{},
    /// R1: serialises every mutation of `entries`, `entry_txns`,
    /// `savepoints`, and `pending_advanced_index_rebuilds`.
    list_mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(allocator: std.mem.Allocator) UndoLog {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .entry_txns = .empty,
            .active = false,
            .savepoints = .empty,
            .pending_advanced_index_rebuilds = .{},
            .list_mutex = std.Io.Mutex.init,
        };
    }

    pub fn queueAdvancedIndexRebuild(self: *UndoLog, index_name: []const u8) !void {
        if (!self.active) return;
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        // SONNY-3381: an index queued already keeps its key; the copy made
        // for a second write to it was dropped by `put` unfreed (a leak per
        // repeated write to an indexed property inside a transaction).
        const gop = try self.pending_advanced_index_rebuilds.getOrPut(self.allocator, index_name);
        if (gop.found_existing) return;
        gop.key_ptr.* = self.allocator.dupe(u8, index_name) catch |err| {
            self.pending_advanced_index_rebuilds.removeByPtr(gop.key_ptr);
            return err;
        };
    }

    pub fn flushPendingRebuilds(self: *UndoLog, store: *graph_store.GraphStore) void {
        const index_manager = @import("index/index_manager.zig").getGlobalIndexManager() orelse return;
        // Snapshot the pending-rebuild keys under the lock, then run the
        // actual rebuild work without holding it (index_manager has its own
        // locking and rebuilds can be long).
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys.deinit(self.allocator);
        keys.ensureTotalCapacity(self.allocator, self.pending_advanced_index_rebuilds.count()) catch {};
        var iter = self.pending_advanced_index_rebuilds.keyIterator();
        while (iter.next()) |key_ptr| {
            keys.append(self.allocator, key_ptr.*) catch {};
        }
        self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        for (keys.items) |name| {
            index_manager.rebuildAdvancedIndex(store, name) catch {};
        }
        self.clearPendingRebuilds();
    }

    pub fn clearPendingRebuilds(self: *UndoLog) void {
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.clearPendingRebuildsLocked();
    }

    fn clearPendingRebuildsLocked(self: *UndoLog) void {
        var iter = self.pending_advanced_index_rebuilds.keyIterator();
        while (iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.pending_advanced_index_rebuilds.clearRetainingCapacity();
    }

    pub fn deinit(self: *UndoLog) void {
        self.clear();
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        self.entries.deinit(self.allocator);
        self.entry_txns.deinit(self.allocator);
        self.clearSavepointsLocked();
        self.savepoints.deinit(self.allocator);
        self.clearPendingRebuildsLocked();
        self.pending_advanced_index_rebuilds.deinit(self.allocator);
        self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    /// Free the memory owned by a single undo entry.  Caller MUST hold
    /// `list_mutex` (or otherwise guarantee exclusive access).
    fn freeEntry(self: *UndoLog, entry: UndoEntry) void {
        freeEntryWith(self.allocator, entry);
    }

    pub fn clear(self: *UndoLog) void {
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.clearLocked();
    }

    fn clearLocked(self: *UndoLog) void {
        for (self.entries.items) |entry| {
            self.freeEntry(entry);
        }
        // Release backing buffers, not just the logical length: otherwise a
        // process-global log (see `getGlobalUndoLog`) keeps a pointer owned
        // by an allocator whose lifetime may end before the next caller
        // arrives (e.g. between unit tests sharing the global via a
        // re-initialising `std.testing.allocator`).
        self.entries.clearAndFree(self.allocator);
        self.entry_txns.clearAndFree(self.allocator);
    }

    pub fn clearSavepoints(self: *UndoLog) void {
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.clearSavepointsLocked();
    }

    fn clearSavepointsLocked(self: *UndoLog) void {
        for (self.savepoints.items) |sp| {
            self.allocator.free(sp.name);
        }
        self.savepoints.clearAndFree(self.allocator);
    }

    /// Begin a transaction.  Each caller thread gets its own `txn_id` so
    /// concurrent `BEGIN`s from different sessions no longer wipe each
    /// other's entries (R1).  A transport handler puts a session's
    /// transaction on whichever thread serves its request (SONNY-2799);
    /// every other caller drives `commit()`/`rollback()` on the thread that
    /// called `begin()`.
    pub fn begin(self: *UndoLog) void {
        // If this thread still claims an active txn, drop it silently —
        // the old contract was "begin wipes previous state"; we honour
        // that for this thread's own state only.
        self.discardTxn(threadTxn());

        t_txn_state.txn_id = allocTxnId();
        t_txn_state.active = true;

        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.active = true;
        // SONNY-2799: other transactions' savepoints and queued index
        // rebuilds are not this BEGIN's to drop. It cleared both, so a
        // session's BEGIN took another session's savepoints, and the index
        // rebuilds that session's COMMIT was to run.
    }

    pub fn commit(self: *UndoLog, store: ?*graph_store.GraphStore) void {
        if (store) |s| {
            self.flushPendingRebuilds(s);
        } else {
            self.clearPendingRebuilds();
        }

        // This thread's transaction only: its entries and its savepoints.
        self.discardTxn(threadTxn());

        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        t_txn_state = .{};
        if (self.entries.items.len == 0) self.active = false;
    }

    /// GAP-0511: Commit transaction state (clear entries, savepoints, deactivate)
    /// WITHOUT flushing pending index rebuilds. Caller is responsible for calling
    /// flushPendingRebuilds separately -- typically after releasing the write lock
    /// to avoid blocking other connections during the O(N) index population scan.
    pub fn commitDeferRebuilds(self: *UndoLog) void {
        self.discardTxn(threadTxn());
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        t_txn_state = .{};
        if (self.entries.items.len == 0) self.active = false;
    }

    /// SONNY-3028: has the calling thread's transaction recorded any change?
    pub fn threadTxnHasEntries(self: *UndoLog) bool {
        const txn = threadTxn();
        if (txn == 0) return false;
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        for (self.entry_txns.items) |t| {
            if (t == txn) return true;
        }
        return false;
    }

    /// SONNY-2799: forget transaction `txn_id` without undoing it: its
    /// entries and its savepoints. For a transaction that committed, or one
    /// whose session went away with no store to undo it on. 0 is none.
    pub fn discardTxn(self: *UndoLog, txn_id: u64) void {
        if (txn_id == 0) return;
        self.purgeEntriesForTxn(txn_id);
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.dropSavepointsLocked(txn_id, 0);
    }

    /// Drop transaction `txn_id`'s savepoints from position `from` on in
    /// `savepoints`. Caller MUST hold `list_mutex`.
    fn dropSavepointsLocked(self: *UndoLog, txn_id: u64, from: usize) void {
        var j: usize = self.savepoints.items.len;
        while (j > from) {
            j -= 1;
            if (self.savepoints.items[j].txn_id != txn_id) continue;
            self.allocator.free(self.savepoints.items[j].name);
            _ = self.savepoints.orderedRemove(j);
        }
    }

    /// How many entries transaction `txn_id` has. Caller MUST hold
    /// `list_mutex`.
    fn countOwnLocked(self: *const UndoLog, txn_id: u64) usize {
        var n: usize = 0;
        for (self.entry_txns.items) |t| {
            if (t == txn_id) n += 1;
        }
        return n;
    }

    /// Take transaction `txn_id`'s newest `count` entries out of the list,
    /// newest first. Caller MUST hold `list_mutex`; the caller owns the
    /// entries returned (undo, then free them). On OutOfMemory nothing is
    /// taken.
    fn takeNewestOwnLocked(self: *UndoLog, txn_id: u64, count: usize) !std.ArrayListUnmanaged(UndoEntry) {
        var taken: std.ArrayListUnmanaged(UndoEntry) = .empty;
        try taken.ensureTotalCapacity(self.allocator, count);
        var remaining = count;
        var i: usize = self.entries.items.len;
        while (remaining > 0 and i > 0) {
            i -= 1;
            if (self.entry_txns.items[i] != txn_id) continue;
            taken.appendAssumeCapacity(self.entries.items[i]);
            _ = self.entries.orderedRemove(i);
            _ = self.entry_txns.orderedRemove(i);
            remaining -= 1;
        }
        return taken;
    }

    /// Undo `entries` in order, freeing each.
    ///
    /// SONNY-3348 (round 19, m3): an entry that cannot be undone is logged,
    /// counted (`statement_undo.replay_failures_total`) and skipped, and the
    /// rest are still undone: it stopped at the first, and freed the rest
    /// undone, silently skipping the rest of the transaction. Afterwards
    /// `error.RollbackIncomplete` reports that the transaction is partly
    /// applied.
    fn undoAndFree(self: *UndoLog, store: *graph_store.GraphStore, entries: []const UndoEntry) error{RollbackIncomplete}!void {
        // SONNY-3348 (round 18, I1): the undo's own writes are neither
        // recorded in a statement's undo record nor refused by the write
        // fence a failed statement raised (a transaction body's rollback runs
        // inside that statement's scope, and the fence made it a no-op).
        statement_undo.suspendCapture();
        defer statement_undo.resumeCapture();
        // SONNY-3381: the indexes kept beside the store, after the undo.
        var repair = IndexRepair.init(self.allocator);
        defer repair.finish(store);
        var complete = true;
        for (entries) |entry| {
            (if (statement_undo.takeTestUndoFailure()) error.InjectedUndoFailure else self.undoEntry(store, entry, &repair)) catch |err| {
                complete = false;
                _ = statement_undo.replay_failures_total.fetchAdd(1, .monotonic);
                undo_log.err("transaction undo: an entry could not be undone; the transaction is partly applied", &.{logging.Attr.string("error", @errorName(err))});
            };
            self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            self.freeEntry(entry);
            self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        }
        if (!complete) return error.RollbackIncomplete;
    }

    /// Remove (and free) all entries whose tag matches `txn_id`.  Caller
    /// must NOT hold `list_mutex` — the helper takes it internally.
    fn purgeEntriesForTxn(self: *UndoLog, txn_id: u64) void {
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (self.entry_txns.items[i] == txn_id) {
                self.freeEntry(self.entries.items[i]);
                _ = self.entries.orderedRemove(i);
                _ = self.entry_txns.orderedRemove(i);
            }
        }
    }

    // CANARY: REQ=REQ-TXN-SAVEPOINT-002; FEATURE="TransactionSavepoints"; ASPECT=CreateSavepoint; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-01
    /// Create a named savepoint in the calling thread's transaction, after
    /// its changes so far. A savepoint of the same transaction with the same
    /// name is moved there.
    pub fn createSavepoint(self: *UndoLog, name: []const u8) !void {
        // SONNY-2799: a savepoint is its transaction's.
        const txn_id = threadTxn();
        if (txn_id == 0) return error.NoActiveTransaction;

        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const own = self.countOwnLocked(txn_id);
        for (self.savepoints.items) |*sp| {
            if (sp.txn_id == txn_id and std.mem.eql(u8, sp.name, name)) {
                sp.own_count = own;
                return;
            }
        }

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.savepoints.append(self.allocator, .{
            .name = name_copy,
            .txn_id = txn_id,
            .own_count = own,
        });
    }

    // CANARY: REQ=REQ-TXN-SAVEPOINT-003; FEATURE="TransactionSavepoints"; ASPECT=RollbackToSavepoint; STATUS=IMPL; OWNER=engine; UPDATED=2026-04-01
    /// Undo the calling thread's transaction's changes made after the named
    /// savepoint, newest first. The savepoint itself is kept (SQL semantics:
    /// ROLLBACK TO does not release the savepoint); the transaction's
    /// savepoints created after it are discarded.
    ///
    /// SONNY-2799: only this transaction's changes and savepoints. It undid
    /// every entry after the savepoint's index into the shared list, other
    /// sessions' included, and then cut the list there: an entry appended by
    /// another session while it undid was dropped unfreed.
    pub fn rollbackToSavepoint(self: *UndoLog, name: []const u8, store: *graph_store.GraphStore) !void {
        const txn_id = threadTxn();
        if (txn_id == 0) return error.NoActiveTransaction;

        // Take the changes to undo out of the list under the lock, then undo
        // them (which calls back into the store) without it.
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        var sp_idx: ?usize = null;
        for (self.savepoints.items, 0..) |sp, idx| {
            if (sp.txn_id == txn_id and std.mem.eql(u8, sp.name, name)) {
                sp_idx = idx;
                break;
            }
        }
        const idx = sp_idx orelse {
            self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return error.SavepointNotFound;
        };
        const later = self.countOwnLocked(txn_id) -| self.savepoints.items[idx].own_count;
        var undo_now = self.takeNewestOwnLocked(txn_id, later) catch |err| {
            self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return err;
        };
        defer undo_now.deinit(self.allocator);
        self.dropSavepointsLocked(txn_id, idx + 1);
        self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        try self.undoAndFree(store, undo_now.items);
    }

    /// Append an already-constructed undo entry under the list mutex and
    /// tag it with the caller thread's txn_id.  Caller MUST NOT hold the
    /// mutex.  If allocation fails, the entry is freed before bubbling
    /// the error up (caller must not touch it afterwards).
    fn appendEntryLocked(self: *UndoLog, entry: UndoEntry) !void {
        const txn_id = t_txn_state.txn_id;
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        errdefer self.freeEntry(entry);
        try self.entries.append(self.allocator, entry);
        errdefer _ = self.entries.pop();
        try self.entry_txns.append(self.allocator, txn_id);
    }

    /// Log creation of a node (undo = delete it)
    pub fn logCreateNode(self: *UndoLog, node_id: u64, graph_name: ?[]const u8) !void {
        if (threadTxn() == 0) return; // SONNY-2799: only inside a transaction
        const gname = graph_name orelse "default";
        const entry: UndoEntry = .{ .CreateNode = .{
            .node_id = node_id,
            .graph_name = try self.allocator.dupe(u8, gname),
        } };
        try self.appendEntryLocked(entry);
    }

    /// Log creation of an edge (undo = delete it)
    pub fn logCreateEdge(self: *UndoLog, edge_id: u64, graph_name: ?[]const u8) !void {
        if (threadTxn() == 0) return; // SONNY-2799: only inside a transaction
        const gname = graph_name orelse "default";
        const entry: UndoEntry = .{ .CreateEdge = .{
            .edge_id = edge_id,
            .graph_name = try self.allocator.dupe(u8, gname),
        } };
        try self.appendEntryLocked(entry);
    }

    /// Log setting a node property (undo = restore old value or remove)
    pub fn logSetNodeProperty(self: *UndoLog, node_id: u64, key: []const u8, old_value: ?graph_store.PropertyValue) !void {
        if (threadTxn() == 0) return; // SONNY-2799: only inside a transaction
        const key_copy = try self.allocator.dupe(u8, key);
        const serialized = if (old_value) |ov|
            try SerializedProperty.fromPropertyValue(self.allocator, key, ov)
        else
            SerializedProperty{ .key = try self.allocator.dupe(u8, key), .value_type = 0 };

        const entry: UndoEntry = .{ .SetNodeProperty = .{
            .node_id = node_id,
            .key = key_copy,
            .had_old_value = old_value != null,
            .old_value = serialized,
        } };
        try self.appendEntryLocked(entry);
    }

    /// Log removing a node property (undo = restore it)
    pub fn logRemoveNodeProperty(self: *UndoLog, node_id: u64, old_value: graph_store.PropertyValue, key: []const u8) !void {
        if (threadTxn() == 0) return; // SONNY-2799: only inside a transaction
        const sp = try SerializedProperty.fromPropertyValue(self.allocator, key, old_value);
        const entry: UndoEntry = .{ .RemoveNodeProperty = .{
            .node_id = node_id,
            .old_value = sp,
        } };
        try self.appendEntryLocked(entry);
    }

    /// Log deletion of a node (undo = recreate it)
    pub fn logDeleteNode(self: *UndoLog, node: graph_store.Node) !void {
        if (threadTxn() == 0) return; // SONNY-2799: only inside a transaction

        // Copy labels
        const labels = try self.allocator.alloc([]const u8, node.labels.len);
        for (node.labels, 0..) |label, i| {
            labels[i] = try self.allocator.dupe(u8, label);
        }

        // Copy properties
        var props: std.ArrayListUnmanaged(SerializedProperty) = .{};
        var prop_iter = node.properties.iterator();
        while (prop_iter.next()) |entry| {
            const sp = try SerializedProperty.fromPropertyValue(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            try props.append(self.allocator, sp);
        }

        const entry: UndoEntry = .{ .DeleteNode = .{
            .node_id = node.id,
            .labels = labels,
            .properties = try props.toOwnedSlice(self.allocator),
            .graph_name = try self.allocator.dupe(u8, node.graph_name),
        } };
        try self.appendEntryLocked(entry);
    }

    /// Log deletion of an edge (undo = recreate it)
    pub fn logDeleteEdge(self: *UndoLog, edge: graph_store.Edge) !void {
        if (threadTxn() == 0) return; // SONNY-2799: only inside a transaction

        // Copy properties
        var props: std.ArrayListUnmanaged(SerializedProperty) = .{};
        var prop_iter = edge.properties.iterator();
        while (prop_iter.next()) |entry| {
            const sp = try SerializedProperty.fromPropertyValue(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            try props.append(self.allocator, sp);
        }

        const entry: UndoEntry = .{ .DeleteEdge = .{
            .edge_id = edge.id,
            .from_id = edge.from_id,
            .to_id = edge.to_id,
            .label = try self.allocator.dupe(u8, edge.label),
            .properties = try props.toOwnedSlice(self.allocator),
            .graph_name = try self.allocator.dupe(u8, edge.graph_name),
        } };
        try self.appendEntryLocked(entry);
    }

    /// Log adding a label to a node (undo = remove it)
    pub fn logAddNodeLabel(self: *UndoLog, node_id: u64, label: []const u8) !void {
        if (threadTxn() == 0) return; // SONNY-2799: only inside a transaction
        const entry: UndoEntry = .{ .AddNodeLabel = .{
            .node_id = node_id,
            .label = try self.allocator.dupe(u8, label),
        } };
        try self.appendEntryLocked(entry);
    }

    /// Log removing a label from a node (undo = add it back)
    pub fn logRemoveNodeLabel(self: *UndoLog, node_id: u64, label: []const u8) !void {
        if (threadTxn() == 0) return; // SONNY-2799: only inside a transaction
        const entry: UndoEntry = .{ .RemoveNodeLabel = .{
            .node_id = node_id,
            .label = try self.allocator.dupe(u8, label),
        } };
        try self.appendEntryLocked(entry);
    }

    // CANARY: REQ=REQ-SONNY-2799-UNDO-PER-TXN; FEATURE="TransactionUndoLog"; ASPECT=NoMatchAll; STATUS=TESTED; TEST=tests/test_sonny2805_txn_sessions.zig; OWNER=engine; UPDATED=2026-09-26
    /// Rollback all changes belonging to the CALLING THREAD's transaction
    /// by replaying undo entries in reverse order.  Entries owned by other
    /// in-flight transactions are left untouched (R1).
    ///
    /// SONNY-2799: a thread with no transaction rolls back nothing. A
    /// txn_id of 0 used to match every entry of every session: a session
    /// whose transaction the executor had already ended (GAP-0917) undid
    /// another session's uncommitted changes with its ROLLBACK (review probe
    /// R8-C).
    pub fn rollback(self: *UndoLog, store: *graph_store.GraphStore) !void {
        const txn_id = threadTxn();
        if (txn_id == 0) return;

        // SONNY-3348 (round 18): the undo goes through the store's logged
        // write methods (`undoEntryLogged`), and the WAL mutation stream
        // sees it: it saw the changes being undone. (A process-wide inhibit
        // flag also dropped other sessions' changes while it was set.)

        // Take the entries we own out of the list under the lock (newest
        // first, the replay order), then drop the lock before calling back
        // into the store.
        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        var owned_entries = self.takeNewestOwnLocked(txn_id, self.countOwnLocked(txn_id)) catch |err| {
            self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return err;
        };
        defer owned_entries.deinit(self.allocator);
        self.dropSavepointsLocked(txn_id, 0);
        if (self.entries.items.len == 0) self.active = false;
        self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // SONNY-3348 (round 19, m3): the transaction is over either way.
        defer t_txn_state = .{};
        try self.undoAndFree(store, owned_entries.items);
    }

    // CANARY: REQ=REQ-TXN-UNDO-SERVER-015; FEATURE="TransactionUndoLog"; ASPECT=RollbackGraphStore; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
    /// Rollback all changes using GraphStore (for server-side execution)
    /// The storage parameter is kept for API compatibility but each entry looks up its own graph
    pub fn rollbackGraphStore(self: *UndoLog, storage: *graph_common.GraphStore) void {
        _ = storage; // Kept for API compatibility, but we look up per-entry graph
        // SONNY-2799: as `rollback`: this thread's transaction, and none for 0.
        const txn_id = threadTxn();
        if (txn_id == 0) return;
        // SONNY-3348 (round 18): see `rollback`.
        statement_undo.suspendCapture();
        defer statement_undo.resumeCapture();

        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        var owned_entries = self.takeNewestOwnLocked(txn_id, self.countOwnLocked(txn_id)) catch {
            self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            std.log.err("rollbackGraphStore: out of memory; the transaction is left as it was", .{});
            return;
        };
        defer owned_entries.deinit(self.allocator);
        self.dropSavepointsLocked(txn_id, 0);
        if (self.entries.items.len == 0) self.active = false;
        self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // SONNY-3381: the indexes kept beside the store, after the undo.
        const store = graph_store.getGlobalStore(self.allocator);
        var repair = IndexRepair.init(self.allocator);
        defer repair.finish(store);
        for (owned_entries.items) |entry| {
            self.undoEntryGraphStore(store, entry, &repair);
            self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            self.freeEntry(entry);
            self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        }

        t_txn_state = .{};
    }

    fn undoEntryGraphStore(self: *UndoLog, store: *graph_store.GraphStore, entry: UndoEntry, repair: *IndexRepair) void {
        self.undoEntry(store, entry, repair) catch |err| {
            std.log.err("rollbackGraphStore failed: {}", .{err});
        };
    }

    fn undoEntry(self: *UndoLog, store: *graph_store.GraphStore, entry: UndoEntry, repair: ?*IndexRepair) !void {
        _ = self;
        try undoEntryLogged(store, entry, repair);
    }

    // CANARY: REQ=REQ-SONNY-3059-UNDO-ALL-CHANGES; FEATURE="TransactionUndoLog"; ASPECT=AdoptStatementRecord; STATUS=TESTED; TEST=tests/test_sonny3348_statement_undo.zig; OWNER=engine; UPDATED=2026-09-29
    /// SONNY-3059 (round 18): append a statement's undo record
    /// (`statement_undo`) to the calling thread's transaction, oldest first,
    /// so ROLLBACK undoes the statement's every change: SET, REMOVE, DELETE,
    /// labels, MERGE ON MATCH, not only what it created. All or nothing: on
    /// OutOfMemory the transaction is left as it was.
    pub fn adoptStatementEntries(self: *UndoLog, entries: []const UndoEntry) error{OutOfMemory}!void {
        const txn_id = threadTxn();
        if (txn_id == 0 or entries.len == 0) return;
        var copies: std.ArrayListUnmanaged(UndoEntry) = .empty;
        defer copies.deinit(self.allocator);
        errdefer for (copies.items) |c| freeEntryWith(self.allocator, c);
        try copies.ensureTotalCapacity(self.allocator, entries.len);
        for (entries) |e| copies.appendAssumeCapacity(try cloneEntry(self.allocator, e));

        self.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try self.entries.ensureUnusedCapacity(self.allocator, copies.items.len);
        try self.entry_txns.ensureUnusedCapacity(self.allocator, copies.items.len);
        for (copies.items) |c| {
            self.entries.appendAssumeCapacity(c);
            self.entry_txns.appendAssumeCapacity(txn_id);
        }
        self.active = true;
        copies.clearRetainingCapacity();
    }
};

/// SONNY-2799: is a transaction open on the calling thread? (SONNY-3348:
/// a statement's undo record joins it when the statement succeeds.)
pub fn threadInTxn() bool {
    return threadTxn() != 0;
}

/// Free the memory `entry` owns, allocated with `allocator`.
pub fn freeEntryWith(allocator: std.mem.Allocator, entry: UndoEntry) void {
    switch (entry) {
        .SetNodeProperty => |e| {
            allocator.free(e.key);
            e.old_value.deinit(allocator);
        },
        .RemoveNodeProperty => |e| {
            e.old_value.deinit(allocator);
        },
        .SetEdgeProperty => |e| {
            allocator.free(e.key);
            e.old_value.deinit(allocator);
        },
        .RemoveEdgeProperty => |e| {
            e.old_value.deinit(allocator);
        },
        .DeleteNode => |e| {
            for (e.labels) |label| allocator.free(label);
            allocator.free(e.labels);
            for (e.properties) |prop| {
                prop.deinit(allocator);
            }
            allocator.free(e.properties);
            allocator.free(e.graph_name);
            allocator.free(e.tenant_id);
        },
        .DeleteEdge => |e| {
            allocator.free(e.label);
            for (e.properties) |prop| {
                prop.deinit(allocator);
            }
            allocator.free(e.properties);
            allocator.free(e.graph_name);
            allocator.free(e.tenant_id);
        },
        .AddNodeLabel => |e| {
            allocator.free(e.label);
        },
        .RemoveNodeLabel => |e| {
            allocator.free(e.label);
        },
        .CreateNode => |e| {
            allocator.free(e.graph_name);
        },
        .CreateEdge => |e| {
            allocator.free(e.graph_name);
        },
    }
}

fn cloneProperty(allocator: std.mem.Allocator, prop: SerializedProperty) !SerializedProperty {
    const key = try allocator.dupe(u8, prop.key);
    errdefer allocator.free(key);
    const string_value: ?[]const u8 = if (prop.string_value) |v| try allocator.dupe(u8, v) else null;
    errdefer if (string_value) |v| allocator.free(v);
    const binary_value: ?[]const u8 = if (prop.binary_value) |v| try allocator.dupe(u8, v) else null;
    var out = prop;
    out.key = key;
    out.string_value = string_value;
    out.binary_value = binary_value;
    return out;
}

fn cloneProperties(allocator: std.mem.Allocator, props: []const SerializedProperty) ![]const SerializedProperty {
    const out = try allocator.alloc(SerializedProperty, props.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |p| p.deinit(allocator);
        allocator.free(out);
    }
    for (props, 0..) |p, i| {
        out[i] = try cloneProperty(allocator, p);
        done += 1;
    }
    return out;
}

fn cloneLabels(allocator: std.mem.Allocator, labels: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, labels.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |l| allocator.free(l);
        allocator.free(out);
    }
    for (labels, 0..) |l, i| {
        out[i] = try allocator.dupe(u8, l);
        done += 1;
    }
    return out;
}

/// SONNY-3348 (round 18): a deep copy of `entry`, allocated with `allocator`.
pub fn cloneEntry(allocator: std.mem.Allocator, entry: UndoEntry) !UndoEntry {
    switch (entry) {
        .CreateNode => |e| return .{ .CreateNode = .{ .node_id = e.node_id, .graph_name = try allocator.dupe(u8, e.graph_name) } },
        .CreateEdge => |e| return .{ .CreateEdge = .{ .edge_id = e.edge_id, .graph_name = try allocator.dupe(u8, e.graph_name) } },
        .SetNodeProperty => |e| {
            const key = try allocator.dupe(u8, e.key);
            errdefer allocator.free(key);
            return .{ .SetNodeProperty = .{ .node_id = e.node_id, .key = key, .had_old_value = e.had_old_value, .old_value = try cloneProperty(allocator, e.old_value) } };
        },
        .RemoveNodeProperty => |e| return .{ .RemoveNodeProperty = .{ .node_id = e.node_id, .old_value = try cloneProperty(allocator, e.old_value) } },
        .SetEdgeProperty => |e| {
            const key = try allocator.dupe(u8, e.key);
            errdefer allocator.free(key);
            return .{ .SetEdgeProperty = .{ .edge_id = e.edge_id, .key = key, .had_old_value = e.had_old_value, .old_value = try cloneProperty(allocator, e.old_value) } };
        },
        .RemoveEdgeProperty => |e| return .{ .RemoveEdgeProperty = .{ .edge_id = e.edge_id, .old_value = try cloneProperty(allocator, e.old_value) } },
        .DeleteNode => |e| {
            const labels = try cloneLabels(allocator, e.labels);
            errdefer {
                for (labels) |l| allocator.free(l);
                allocator.free(labels);
            }
            const props = try cloneProperties(allocator, e.properties);
            errdefer {
                for (props) |p| p.deinit(allocator);
                allocator.free(props);
            }
            const graph_name = try allocator.dupe(u8, e.graph_name);
            errdefer allocator.free(graph_name);
            return .{ .DeleteNode = .{ .node_id = e.node_id, .labels = labels, .properties = props, .graph_name = graph_name, .tenant_id = try allocator.dupe(u8, e.tenant_id) } };
        },
        .DeleteEdge => |e| {
            const label = try allocator.dupe(u8, e.label);
            errdefer allocator.free(label);
            const props = try cloneProperties(allocator, e.properties);
            errdefer {
                for (props) |p| p.deinit(allocator);
                allocator.free(props);
            }
            const graph_name = try allocator.dupe(u8, e.graph_name);
            errdefer allocator.free(graph_name);
            return .{ .DeleteEdge = .{ .edge_id = e.edge_id, .from_id = e.from_id, .to_id = e.to_id, .label = label, .properties = props, .graph_name = graph_name, .tenant_id = try allocator.dupe(u8, e.tenant_id) } };
        },
        .AddNodeLabel => |e| return .{ .AddNodeLabel = .{ .node_id = e.node_id, .label = try allocator.dupe(u8, e.label) } },
        .RemoveNodeLabel => |e| return .{ .RemoveNodeLabel = .{ .node_id = e.node_id, .label = try allocator.dupe(u8, e.label) } },
    }
}

// CANARY: REQ=REQ-SONNY-3348-LIMIT-ATOMICITY; FEATURE="TransactionUndoLog"; ASPECT=LoggedUndo; STATUS=TESTED; TEST=tests/test_sonny3348_statement_undo.zig; OWNER=engine; UPDATED=2026-09-29
/// SONNY-3348 (round 18): undo one change through the store's normal write
/// methods, so the storage engine, the WAL mutation stream and the store's
/// indexes see the compensating change. (The rollback used the `*NoSave`
/// setters, which change the in-memory store only: the engine kept the
/// transaction's value, and the next start read it back.) An entity the
/// change was on that no longer exists (a node an earlier undo deleted) is
/// skipped, and so is a delete whose entity is still there (the delete
/// never happened). The caller suspends the statement record and the write
/// fence (`statement_undo.suspendCapture`).
///
/// SONNY-3381: `repair` (when given) is told which indexed (graph, label,
/// property) each undone node change touches, so the indexes the executor
/// keeps beside the store can be rebuilt once the undo is done
/// (`IndexRepair.finish`).
pub fn undoEntryLogged(store: *graph_store.GraphStore, entry: UndoEntry, repair: ?*IndexRepair) !void {
    if (repair) |r| r.noteBefore(store, entry);
    switch (entry) {
        .CreateNode => |e| {
            if (store.nodeExistsForUndo(e.node_id)) try store.deleteNodeChecked(e.node_id);
        },
        .CreateEdge => |e| {
            if (store.edgeExistsForUndo(e.edge_id)) try store.deleteEdgeChecked(e.edge_id);
        },
        .SetNodeProperty => |e| {
            if (!store.nodeExistsForUndo(e.node_id)) return;
            if (e.had_old_value) {
                const pv = try e.old_value.toPropertyValue(store.allocator);
                defer if (e.old_value.value_type == 5) property_codec.freePropertyValue(store.allocator, pv);
                try store.setNodeProperty(e.node_id, e.key, pv);
            } else {
                store.removeNodeProperty(e.node_id, e.key);
            }
        },
        .RemoveNodeProperty => |e| {
            if (!store.nodeExistsForUndo(e.node_id)) return;
            const pv = try e.old_value.toPropertyValue(store.allocator);
            defer if (e.old_value.value_type == 5) property_codec.freePropertyValue(store.allocator, pv);
            try store.setNodeProperty(e.node_id, e.old_value.key, pv);
        },
        .SetEdgeProperty => |e| {
            if (!store.edgeExistsForUndo(e.edge_id)) return;
            if (e.had_old_value) {
                const pv = try e.old_value.toPropertyValue(store.allocator);
                defer if (e.old_value.value_type == 5) property_codec.freePropertyValue(store.allocator, pv);
                try store.setEdgeProperty(e.edge_id, e.key, pv);
            } else {
                store.removeEdgeProperty(e.edge_id, e.key);
            }
        },
        .RemoveEdgeProperty => |e| {
            if (!store.edgeExistsForUndo(e.edge_id)) return;
            const pv = try e.old_value.toPropertyValue(store.allocator);
            defer if (e.old_value.value_type == 5) property_codec.freePropertyValue(store.allocator, pv);
            try store.setEdgeProperty(e.edge_id, e.old_value.key, pv);
        },
        .DeleteNode => |e| {
            if (store.nodeExistsForUndo(e.node_id)) return;
            const tenant = if (e.tenant_id.len > 0) e.tenant_id else graph_store.DEFAULT_TENANT_ID;
            try store.createNodeWithReservedIdGraphAndTenant(e.node_id, e.labels, e.graph_name, tenant);
            for (e.properties) |prop| {
                const pv = try prop.toPropertyValue(store.allocator);
                defer if (prop.value_type == 5) property_codec.freePropertyValue(store.allocator, pv);
                try store.setNodeProperty(e.node_id, prop.key, pv);
            }
        },
        .DeleteEdge => |e| {
            if (store.edgeExistsForUndo(e.edge_id)) return;
            const tenant = if (e.tenant_id.len > 0) e.tenant_id else graph_store.DEFAULT_TENANT_ID;
            try store.restoreDeletedEdge(e.edge_id, e.from_id, e.to_id, e.label, e.graph_name, tenant);
            for (e.properties) |prop| {
                const pv = try prop.toPropertyValue(store.allocator);
                defer if (prop.value_type == 5) property_codec.freePropertyValue(store.allocator, pv);
                try store.setEdgeProperty(e.edge_id, prop.key, pv);
            }
        },
        .AddNodeLabel => |e| {
            if (!store.nodeExistsForUndo(e.node_id)) return;
            try store.removeNodeLabel(e.node_id, e.label);
        },
        .RemoveNodeLabel => |e| {
            if (!store.nodeExistsForUndo(e.node_id)) return;
            try store.addNodeLabel(e.node_id, e.label);
        },
    }
}

// CANARY: REQ=REQ-SONNY-3381-UNDO-INDEX-REPAIR; FEATURE="TransactionUndoLog"; ASPECT=IndexRepairCollector; STATUS=TESTED; TEST=tests/test_sonny3381_undo_index_entries.zig; OWNER=engine; UPDATED=2026-11-12
/// SONNY-3381: the indexes an undo leaves stale, and their repair.
///
/// The executor keeps the full-text indexes and the advanced (vector,
/// spatial, ...) indexes current beside the graph store's write methods
/// (`property_mutation.setNodePropertyFromValue`, the CREATE and DELETE
/// paths), but an undo replays through the store's write methods only. The
/// full-text engine is append-only with permanent per-document tombstones
/// and HNSW cannot remove an entry, so neither can take back the one change
/// an undo reverts: after the undo an index held the undone value (a word an
/// undone SET wrote, a vector an undone SET added) or lacked the restored one
/// (a node whose DELETE was undone stays tombstoned) until it was rebuilt.
///
/// So every undo (a failed statement's replay, ROLLBACK, ROLLBACK TO
/// SAVEPOINT) collects the (graph, label, property) of each node change it
/// reverts, and when it is done (`finish`) hands them to the executor's hook
/// (`execution/undo_index_repair.zig`), which rebuilds, from the store as the
/// undo left it, every full-text and advanced index covering one of them
/// (edge properties too: an advanced index can cover an edge type's). An
/// undone CREATE is not collected: the node or edge is gone, and the searches
/// drop a hit whose entity does not exist.
pub const IndexRepair = struct {
    allocator: std.mem.Allocator,
    targets: std.ArrayListUnmanaged(Target) = .empty,
    /// A change could not be collected (out of memory): repair every index.
    everything: bool = false,

    /// One indexed node change: `property` null for a change of the whole
    /// node (a restored node, a label added or removed).
    pub const Target = struct {
        graph: []const u8,
        label: []const u8,
        property: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) IndexRepair {
        return .{ .allocator = allocator };
    }

    /// Collect what undoing `entry` changes, before it is undone.
    pub fn noteBefore(self: *IndexRepair, store: *graph_store.GraphStore, entry: UndoEntry) void {
        switch (entry) {
            .SetNodeProperty => |e| self.noteNode(store, e.node_id, e.key, null),
            .RemoveNodeProperty => |e| self.noteNode(store, e.node_id, e.old_value.key, null),
            .AddNodeLabel => |e| self.noteNode(store, e.node_id, null, e.label),
            .RemoveNodeLabel => |e| self.noteNode(store, e.node_id, null, e.label),
            .DeleteNode => |e| {
                const graph = if (e.graph_name.len > 0) e.graph_name else graph_store.DEFAULT_GRAPH_NAME;
                for (e.labels) |label| self.note(graph, label, null);
            },
            // An advanced index can cover an edge type's property too.
            .SetEdgeProperty => |e| self.noteEdge(store, e.edge_id, e.key),
            .RemoveEdgeProperty => |e| self.noteEdge(store, e.edge_id, e.old_value.key),
            .DeleteEdge => |e| self.note(if (e.graph_name.len > 0) e.graph_name else graph_store.DEFAULT_GRAPH_NAME, e.label, null),
            .CreateNode, .CreateEdge => {},
        }
    }

    /// Edge `edge_id`'s graph and type, with `property`.
    fn noteEdge(self: *IndexRepair, store: *graph_store.GraphStore, edge_id: u64, property: []const u8) void {
        if (!store.edgeExistsForUndo(edge_id)) return;
        const edge = store.getEdgeHydrated(edge_id) orelse return;
        self.note(edge.graph_name, edge.label, property);
    }

    /// Node `node_id`'s graph and labels (or only `label`, for a label
    /// change), with `property`.
    fn noteNode(self: *IndexRepair, store: *graph_store.GraphStore, node_id: u64, property: ?[]const u8, label: ?[]const u8) void {
        if (!store.nodeExistsForUndo(node_id)) return;
        const node = store.getNodePtrHydrated(node_id) orelse return;
        if (label) |l| return self.note(node.graph_name, l, property);
        for (node.labels) |l| self.note(node.graph_name, l, property);
    }

    fn note(self: *IndexRepair, graph: []const u8, label: []const u8, property: ?[]const u8) void {
        if (self.everything) return;
        for (self.targets.items) |t| {
            if (!std.mem.eql(u8, t.graph, graph) or !std.mem.eql(u8, t.label, label)) continue;
            // A whole-node target covers every property of the label.
            if (t.property == null) return;
            if (property) |p| if (std.mem.eql(u8, t.property.?, p)) return;
        }
        self.append(graph, label, property) catch {
            self.everything = true;
        };
    }

    fn append(self: *IndexRepair, graph: []const u8, label: []const u8, property: ?[]const u8) !void {
        const a = self.allocator;
        const g = try a.dupe(u8, graph);
        errdefer a.free(g);
        const l = try a.dupe(u8, label);
        errdefer a.free(l);
        const p: ?[]const u8 = if (property) |x| try a.dupe(u8, x) else null;
        errdefer if (p) |x| a.free(x);
        try self.targets.append(a, .{ .graph = g, .label = l, .property = p });
    }

    /// The undo is done: repair the indexes it left stale, then free.
    pub fn finish(self: *IndexRepair, store: *graph_store.GraphStore) void {
        defer self.deinit();
        if (self.targets.items.len == 0 and !self.everything) return;
        const hook = index_repair_hook.load(.acquire) orelse {
            // No executor in this process: nothing maintains these indexes
            // beside the store either.
            return;
        };
        hook(store, self.targets.items, self.everything);
    }

    fn deinit(self: *IndexRepair) void {
        for (self.targets.items) |t| {
            self.allocator.free(t.graph);
            self.allocator.free(t.label);
            if (t.property) |p| self.allocator.free(p);
        }
        self.targets.deinit(self.allocator);
    }
};

/// SONNY-3381: rebuilds the indexes covering `targets` (every index when
/// `everything`) from the store. Installed by the executor
/// (`execution/undo_index_repair.zig`); never fails the undo.
pub const IndexRepairHook = *const fn (store: *graph_store.GraphStore, targets: []const IndexRepair.Target, everything: bool) void;

var index_repair_hook: std.atomic.Value(?IndexRepairHook) = .init(null);

pub fn setIndexRepairHook(hook: ?IndexRepairHook) void {
    index_repair_hook.store(hook, .release);
}

// Global undo log instance for CLI mode
var global_undo_log: ?UndoLog = null;

/// SONNY-6429: the process-global undo log outlives every request, so in the
/// server it allocates from the process allocator, never from the caller's
/// (often a per-request or per-statement arena, freed while the log still
/// holds entries and allocates through it: the next transaction statement's
/// `adoptStatementEntries` then called through a freed arena and the server
/// died with a segfault). Test binaries keep the first caller's allocator,
/// which their harnesses pick deliberately (the testing allocator for leak
/// checks, or `page_allocator` for a log that outlives a test).
pub fn getGlobalUndoLog(allocator: std.mem.Allocator) *UndoLog {
    if (global_undo_log == null) {
        global_undo_log = UndoLog.init(if (@import("builtin").is_test) allocator else std.heap.smp_allocator);
    }
    return &global_undo_log.?;
}

/// Tear down the process-global undo log. MUST be called when the global store
/// is deinitialized, because the undo log's accumulated entries — and the
/// per-thread txn state — reference store nodes/graphs that the teardown frees.
/// Left dangling, the NEXT store's transaction rollback (or teardown) reads that
/// freed memory: a cross-test use-after-free that surfaces as a ReleaseSafe
/// general-protection fault (the crash behind GAP-0917's ReleaseSafe failures,
/// where the harness deinits the global store between tests but the global undo
/// log — lazily created once and never reset — kept the prior test's entries).
/// Idempotent (no-op if never initialized). The undo log is logically coupled to
/// the store's lifetime.
/// SONNY-3381: the advanced index `index_name` is about to be rebuilt from
/// the store (`execution/undo_index_repair.zig`), so a rebuild a transaction
/// queued for it (`UndoLog.queueAdvancedIndexRebuild`) is done by that one.
/// Dropped BEFORE the rebuild reads the store: a write queued after this is
/// queued again. ROLLBACK left its transaction's queued rebuilds behind for
/// the next COMMIT of any session to run.
pub fn dropPendingAdvancedIndexRebuild(index_name: []const u8) void {
    const log = if (global_undo_log) |*l| l else return;
    log.list_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer log.list_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (log.pending_advanced_index_rebuilds.fetchRemove(index_name)) |kv| log.allocator.free(kv.key);
}

pub fn deinitGlobalUndoLog() void {
    if (global_undo_log) |*log| {
        log.deinit();
        global_undo_log = null;
    }
    t_txn_state = .{};
}

// SONNY-6325: the undo log's file persistence (saveUndoLog, loadUndoLog,
// clearUndoLogFile) was removed: nothing called it, it no longer compiled
// against Zig 0.16 (std.process.getEnvMap, an Io-less deleteFile), and
// without GEODE_DATA_DIR it used the fixed /tmp/geode_undo_log.bin. The
// entry encoders below remain (round-trip tested).

fn writeU32(file: *std.Io.Writer, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try file.writeAll(&buf);
}

fn writeU64(file: *std.Io.Writer, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try file.writeAll(&buf);
}

fn writeI64(file: *std.Io.Writer, value: i64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, value, .little);
    try file.writeAll(&buf);
}

fn writeI128(file: *std.Io.Writer, value: i128) !void {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(i128, &buf, value, .little);
    try file.writeAll(&buf);
}

fn writeF64(file: *std.Io.Writer, value: f64) !void {
    const bits: u64 = @bitCast(value);
    try writeU64(file, bits);
}

fn writeBool(file: *std.Io.Writer, value: bool) !void {
    const byte: u8 = if (value) 1 else 0;
    try file.writeAll(&[_]u8{byte});
}

fn writeString(file: *std.Io.Writer, value: []const u8) !void {
    try writeU32(file, @intCast(value.len));
    try file.writeAll(value);
}

fn writeSerializedProperty(file: *std.Io.Writer, prop: SerializedProperty) !void {
    try writeString(file, prop.key);
    try file.writeAll(&[_]u8{prop.value_type});
    switch (prop.value_type) {
        0 => {},
        1 => try writeString(file, prop.string_value orelse ""),
        2 => try writeI64(file, prop.int_value),
        3 => try writeF64(file, prop.float_value),
        4 => try writeBool(file, prop.bool_value),
        5 => try writeString(file, prop.binary_value orelse ""),
        else => {},
    }
}

fn writeUndoEntry(file: *std.Io.Writer, entry: UndoEntry) !void {
    // Write entry type
    const entry_type: u8 = @intFromEnum(std.meta.activeTag(entry));
    try file.writeAll(&[_]u8{entry_type});

    switch (entry) {
        .CreateNode => |e| {
            try writeU64(file, e.node_id);
            try writeString(file, e.graph_name);
        },
        .CreateEdge => |e| {
            try writeU64(file, e.edge_id);
            try writeString(file, e.graph_name);
        },
        .SetNodeProperty => |e| {
            try writeU64(file, e.node_id);
            try writeString(file, e.key);
            try writeBool(file, e.had_old_value);
            try writeSerializedProperty(file, e.old_value);
        },
        .RemoveNodeProperty => |e| {
            try writeU64(file, e.node_id);
            try writeSerializedProperty(file, e.old_value);
        },
        .SetEdgeProperty => |e| {
            try writeU64(file, e.edge_id);
            try writeString(file, e.key);
            try writeBool(file, e.had_old_value);
            try writeSerializedProperty(file, e.old_value);
        },
        .RemoveEdgeProperty => |e| {
            try writeU64(file, e.edge_id);
            try writeSerializedProperty(file, e.old_value);
        },
        .DeleteNode => |e| {
            try writeU64(file, e.node_id);
            try writeU32(file, @intCast(e.labels.len));
            for (e.labels) |label| {
                try writeString(file, label);
            }
            try writeU32(file, @intCast(e.properties.len));
            for (e.properties) |prop| {
                try writeSerializedProperty(file, prop);
            }
            try writeString(file, e.graph_name);
        },
        .DeleteEdge => |e| {
            try writeU64(file, e.edge_id);
            try writeU64(file, e.from_id);
            try writeU64(file, e.to_id);
            try writeString(file, e.label);
            try writeU32(file, @intCast(e.properties.len));
            for (e.properties) |prop| {
                try writeSerializedProperty(file, prop);
            }
            try writeString(file, e.graph_name);
        },
        .AddNodeLabel => |e| {
            try writeU64(file, e.node_id);
            try writeString(file, e.label);
        },
        .RemoveNodeLabel => |e| {
            try writeU64(file, e.node_id);
            try writeString(file, e.label);
        },
    }
}

fn readU32(file: *std.Io.Reader) !u32 {
    return try file.takeInt(u32, .little);
}

fn readU64(file: *std.Io.Reader) !u64 {
    return try file.takeInt(u64, .little);
}

fn readI64(file: *std.Io.Reader) !i64 {
    return try file.takeInt(i64, .little);
}

fn readI128(file: *std.Io.Reader) !i128 {
    return try file.takeInt(i128, .little);
}

fn readF64(file: *std.Io.Reader) !f64 {
    const bits = try readU64(file);
    return @bitCast(bits);
}

fn readBool(file: *std.Io.Reader) !bool {
    return (try file.takeByte()) != 0;
}

fn readString(allocator: std.mem.Allocator, file: *std.Io.Reader) ![]u8 {
    const len = try readU32(file);
    const buf = try allocator.alloc(u8, len);
    try file.readSliceAll(buf);
    return buf;
}

fn readSerializedProperty(allocator: std.mem.Allocator, file: *std.Io.Reader) !SerializedProperty {
    const key = try readString(allocator, file);
    const value_type = try file.takeByte();
    var prop = SerializedProperty{ .key = key, .value_type = value_type };
    switch (value_type) {
        0 => {},
        1 => {
            prop.string_value = try readString(allocator, file);
        },
        2 => {
            prop.int_value = try readI64(file);
        },
        3 => {
            prop.float_value = try readF64(file);
        },
        4 => {
            prop.bool_value = try readBool(file);
        },
        5 => {
            prop.binary_value = try readString(allocator, file);
        },
        else => {},
    }
    return prop;
}

fn readUndoEntry(allocator: std.mem.Allocator, file: *std.Io.Reader) !?UndoEntry {
    const type_byte = file.takeByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };

    const entry_type: UndoOpType = @enumFromInt(type_byte);

    switch (entry_type) {
        .CreateNode => {
            const node_id = try readU64(file);
            const graph_name = try readString(allocator, file);
            return .{ .CreateNode = .{ .node_id = node_id, .graph_name = graph_name } };
        },
        .CreateEdge => {
            const edge_id = try readU64(file);
            const graph_name = try readString(allocator, file);
            return .{ .CreateEdge = .{ .edge_id = edge_id, .graph_name = graph_name } };
        },
        .SetNodeProperty => {
            const node_id = try readU64(file);
            const key = try readString(allocator, file);
            const had_old_value = try readBool(file);
            const old_value = try readSerializedProperty(allocator, file);
            return .{ .SetNodeProperty = .{
                .node_id = node_id,
                .key = key,
                .had_old_value = had_old_value,
                .old_value = old_value,
            } };
        },
        .RemoveNodeProperty => {
            const node_id = try readU64(file);
            const old_value = try readSerializedProperty(allocator, file);
            return .{ .RemoveNodeProperty = .{
                .node_id = node_id,
                .old_value = old_value,
            } };
        },
        .SetEdgeProperty => {
            const edge_id = try readU64(file);
            const key = try readString(allocator, file);
            const had_old_value = try readBool(file);
            const old_value = try readSerializedProperty(allocator, file);
            return .{ .SetEdgeProperty = .{
                .edge_id = edge_id,
                .key = key,
                .had_old_value = had_old_value,
                .old_value = old_value,
            } };
        },
        .RemoveEdgeProperty => {
            const edge_id = try readU64(file);
            const old_value = try readSerializedProperty(allocator, file);
            return .{ .RemoveEdgeProperty = .{
                .edge_id = edge_id,
                .old_value = old_value,
            } };
        },
        .DeleteNode => {
            const node_id = try readU64(file);
            const label_count = try readU32(file);
            const labels = try allocator.alloc([]const u8, label_count);
            for (labels, 0..) |*slot, idx| {
                _ = idx;
                slot.* = try readString(allocator, file);
            }
            const prop_count = try readU32(file);
            const props = try allocator.alloc(SerializedProperty, prop_count);
            for (props, 0..) |*slot, idx| {
                _ = idx;
                slot.* = try readSerializedProperty(allocator, file);
            }
            const graph_name = try readString(allocator, file);
            return .{ .DeleteNode = .{
                .node_id = node_id,
                .labels = labels,
                .properties = props,
                .graph_name = graph_name,
            } };
        },
        .DeleteEdge => {
            const edge_id = try readU64(file);
            const from_id = try readU64(file);
            const to_id = try readU64(file);
            const label = try readString(allocator, file);
            const prop_count = try readU32(file);
            const props = try allocator.alloc(SerializedProperty, prop_count);
            for (props, 0..) |*slot, idx| {
                _ = idx;
                slot.* = try readSerializedProperty(allocator, file);
            }
            const graph_name = try readString(allocator, file);
            return .{ .DeleteEdge = .{
                .edge_id = edge_id,
                .from_id = from_id,
                .to_id = to_id,
                .label = label,
                .properties = props,
                .graph_name = graph_name,
            } };
        },
        .AddNodeLabel => {
            const node_id = try readU64(file);
            const label = try readString(allocator, file);
            return .{ .AddNodeLabel = .{ .node_id = node_id, .label = label } };
        },
        .RemoveNodeLabel => {
            const node_id = try readU64(file);
            const label = try readString(allocator, file);
            return .{ .RemoveNodeLabel = .{ .node_id = node_id, .label = label } };
        },
    }
}

test "basic undo log operations" {
    const allocator = std.testing.allocator;
    var log = UndoLog.init(allocator);
    defer log.deinit();

    // Not active, should not log
    try log.logCreateNode(1, null);
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);

    // Begin transaction
    log.begin();
    try std.testing.expect(log.active);

    // Log operations
    try log.logCreateNode(1, null);
    try log.logCreateNode(2, null);
    try log.logCreateEdge(100, null);

    try std.testing.expectEqual(@as(usize, 3), log.entries.items.len);

    // Commit clears the log
    log.commit(null);
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);
    try std.testing.expect(!log.active);
}

test "undo log persistence roundtrip for complex entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io_fs = std.Io.Threaded.global_single_threaded.io();
    const file = try tmp.dir.createFile(io_fs, "undo.bin", .{ .read = true, .truncate = true });
    defer file.close(io_fs);

    var file_writer_buf: [4096]u8 = undefined;
    var file_writer_obj = file.writer(io_fs, &file_writer_buf);
    const w = &file_writer_obj.interface;

    const labels = [_][]const u8{ "Person", "Active" };
    const props = [_]SerializedProperty{
        .{ .key = "name", .value_type = 1, .string_value = "Ada" },
        .{ .key = "age", .value_type = 2, .int_value = 42 },
    };

    const entry1 = UndoEntry{ .SetNodeProperty = .{
        .node_id = 1,
        .key = "name",
        .had_old_value = true,
        .old_value = props[0],
    } };
    const entry2 = UndoEntry{ .DeleteNode = .{
        .node_id = 7,
        .labels = labels[0..],
        .properties = props[0..],
        .graph_name = "g",
    } };
    const entry3 = UndoEntry{ .DeleteEdge = .{
        .edge_id = 9,
        .from_id = 1,
        .to_id = 2,
        .label = "KNOWS",
        .properties = props[1..2],
        .graph_name = "g",
    } };
    const entry4 = UndoEntry{ .AddNodeLabel = .{
        .node_id = 3,
        .label = "VIP",
    } };

    try writeUndoEntry(w, entry1);
    try writeUndoEntry(w, entry2);
    try writeUndoEntry(w, entry3);
    try writeUndoEntry(w, entry4);
    try w.flush();

    var file_reader_buf: [4096]u8 = undefined;
    var file_reader_obj = file.reader(io_fs, &file_reader_buf);
    const r = &file_reader_obj.interface;

    var log = UndoLog.init(allocator);
    defer log.deinit();

    const r1 = (try readUndoEntry(allocator, r)).?;
    try log.entries.append(allocator, r1);
    switch (r1) {
        .SetNodeProperty => |e| {
            try std.testing.expectEqual(@as(u64, 1), e.node_id);
            try std.testing.expectEqualStrings("name", e.key);
            try std.testing.expect(e.had_old_value);
            try std.testing.expectEqual(@as(u8, 1), e.old_value.value_type);
            try std.testing.expectEqualStrings("Ada", e.old_value.string_value.?);
        },
        else => try std.testing.expect(false),
    }

    const r2 = (try readUndoEntry(allocator, r)).?;
    try log.entries.append(allocator, r2);
    switch (r2) {
        .DeleteNode => |e| {
            try std.testing.expectEqual(@as(u64, 7), e.node_id);
            try std.testing.expectEqual(@as(usize, 2), e.labels.len);
            try std.testing.expectEqualStrings("Person", e.labels[0]);
            try std.testing.expectEqualStrings("Active", e.labels[1]);
            try std.testing.expectEqual(@as(usize, 2), e.properties.len);
            try std.testing.expectEqualStrings("name", e.properties[0].key);
            try std.testing.expectEqualStrings("g", e.graph_name);
        },
        else => try std.testing.expect(false),
    }

    const r3 = (try readUndoEntry(allocator, r)).?;
    try log.entries.append(allocator, r3);
    switch (r3) {
        .DeleteEdge => |e| {
            try std.testing.expectEqual(@as(u64, 9), e.edge_id);
            try std.testing.expectEqualStrings("KNOWS", e.label);
            try std.testing.expectEqual(@as(usize, 1), e.properties.len);
        },
        else => try std.testing.expect(false),
    }

    const r4 = (try readUndoEntry(allocator, r)).?;
    try log.entries.append(allocator, r4);
    switch (r4) {
        .AddNodeLabel => |e| {
            try std.testing.expectEqual(@as(u64, 3), e.node_id);
            try std.testing.expectEqualStrings("VIP", e.label);
        },
        else => try std.testing.expect(false),
    }
}

test "savepoint create and rollback to savepoint" {
    const allocator = std.testing.allocator;
    var undo = UndoLog.init(allocator);
    defer undo.deinit();

    // Cannot create savepoint outside transaction
    try std.testing.expectError(error.NoActiveTransaction, undo.createSavepoint("sp1"));

    undo.begin();
    try std.testing.expect(undo.active);

    // Log two operations, then create a savepoint
    try undo.logCreateNode(1, null);
    try undo.logCreateNode(2, null);
    try std.testing.expectEqual(@as(usize, 2), undo.entries.items.len);

    try undo.createSavepoint("sp1");
    try std.testing.expectEqual(@as(usize, 1), undo.savepoints.items.len);
    try std.testing.expectEqual(@as(usize, 2), undo.savepoints.items[0].own_count);

    // Log two more operations after the savepoint
    try undo.logCreateNode(3, null);
    try undo.logCreateNode(4, null);
    try std.testing.expectEqual(@as(usize, 4), undo.entries.items.len);

    // Rollback to savepoint should undo entries after sp1 (entries 3 and 4)
    // Note: rollbackToSavepoint needs a store, but the CreateNode undo (delete)
    // will fail because there is no actual store. For unit testing purposes
    // we test the entry/savepoint bookkeeping by using a second savepoint.
    try undo.createSavepoint("sp2");
    try std.testing.expectEqual(@as(usize, 2), undo.savepoints.items.len);
    try std.testing.expectEqual(@as(usize, 4), undo.savepoints.items[1].own_count);

    // Replacing an existing savepoint updates its index
    try undo.logCreateNode(5, null);
    try undo.createSavepoint("sp2");
    try std.testing.expectEqual(@as(usize, 2), undo.savepoints.items.len);
    try std.testing.expectEqual(@as(usize, 5), undo.savepoints.items[1].own_count);

    // Commit clears savepoints
    undo.commit(null);
    try std.testing.expectEqual(@as(usize, 0), undo.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), undo.savepoints.items.len);
    try std.testing.expect(!undo.active);
}

test "savepoint not found error" {
    const allocator = std.testing.allocator;
    var undo = UndoLog.init(allocator);
    defer undo.deinit();

    undo.begin();
    try undo.createSavepoint("sp1");

    // Rollback to non-existent savepoint should fail
    // We need a dummy store for the API; since no entries exist after the
    // savepoint, no actual undo work is done.
    // However rollbackToSavepoint requires a *GraphStore which we cannot
    // easily construct in a unit test without initializing the full engine.
    // Instead we test that the error is returned for a missing name.
    try std.testing.expectError(error.SavepointNotFound, undo.rollbackToSavepoint("nonexistent", dummy_store_ptr));
    undo.commit(null);
}

const dummy_store_ptr = @as(*graph_store.GraphStore, @ptrFromInt(std.mem.alignForward(usize, 0xdeadbeef, @alignOf(graph_store.GraphStore))));

test "begin clears savepoints from previous transaction" {
    const allocator = std.testing.allocator;
    var undo = UndoLog.init(allocator);
    defer undo.deinit();

    undo.begin();
    try undo.createSavepoint("sp1");
    try std.testing.expectEqual(@as(usize, 1), undo.savepoints.items.len);

    // Begin a new transaction — should clear previous savepoints
    undo.begin();
    try std.testing.expectEqual(@as(usize, 0), undo.savepoints.items.len);
    undo.commit(null);
}

test "SerializedProperty round-trips decimal and ext values" {
    const allocator = std.testing.allocator;

    const decimal = try SerializedProperty.fromPropertyValue(
        allocator,
        "price",
        .{ .Decimal = .{ .coeff = 123456, .scale = 3 } },
    );
    defer decimal.deinit(allocator);

    const decimal_value = try decimal.toPropertyValue(allocator);
    try std.testing.expect(decimal_value == .Decimal);
    try std.testing.expectEqual(@as(i128, 123456), decimal_value.Decimal.coeff);
    try std.testing.expectEqual(@as(u8, 3), decimal_value.Decimal.scale);

    const nested = try allocator.dupe(u8, "ext");
    const list_slice = try allocator.dupe(@import("eval_extended.zig").ExtValue, &.{
        .{ .Int = 9 },
        .{ .Str = nested },
    });
    const ext_prop = SerializedProperty.fromPropertyValue(
        allocator,
        "payload",
        .{ .ExtValue = .{ .List = list_slice } },
    ) catch |err| {
        allocator.free(nested);
        allocator.free(list_slice);
        return err;
    };
    defer ext_prop.deinit(allocator);
    // Free input allocations — fromPropertyValue copies what it needs
    allocator.free(nested);
    allocator.free(list_slice);

    const ext_value = try ext_prop.toPropertyValue(allocator);
    defer graph_store.freeDetachedPropertyValue(allocator, ext_value);
    try std.testing.expect(ext_value == .ExtValue);
    try std.testing.expectEqual(@as(usize, 2), ext_value.ExtValue.List.len);
    try std.testing.expectEqual(@as(i64, 9), ext_value.ExtValue.List[0].Int);
    try std.testing.expectEqualStrings("ext", ext_value.ExtValue.List[1].Str);
}
