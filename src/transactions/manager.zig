const std = @import("std");
const mvcc_adv = @import("mvcc_adv");
const range_tracker = @import("range_tracker");
// CANARY: REQ=REQ-OTEL-METRICS-006; FEATURE="OTel Instrumentation"; ASPECT=TransactionLifecycle; STATUS=TESTED; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
const otel_metrics = @import("otel_metrics");
// CANARY: REQ=REQ-GQL-013; FEATURE="Transactions/MVCC"; ASPECT=Engine; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_013_TxnCommit; OWNER=engine; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-013; FEATURE="Transactions/MVCC"; ASPECT=SSIPhantomPrevention; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_013_SSIPhantomPrevention; OWNER=engine; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=PredictiveSkewFilter; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_073_PredictiveSkewFilter; OWNER=txn; UPDATED=2025-09-21
// CANARY: REQ=REQ-GQL-023; FEATURE="MVCC Phantom Prevention"; ASPECT=PredicateRangeDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_023_PhantomDetection; BENCH=BenchmarkCANARY_REQ_GQL_023_PhantomOverheadVarianceEnvelope; OWNER=txn; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-025; FEATURE="Transactions/MVCC"; ASPECT=WriteSkewDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_025_WriteSkewDetection; BENCH=BenchmarkCANARY_REQ_GQL_025_WriteSkewVarianceEnvelope; OWNER=txn; UPDATED=2025-09-26

pub const TxnId = u64;

pub const TxnState = enum { Active, Committed, Aborted };

pub const Timestamp = u64;

pub const Txn = struct {
    id: TxnId,
    state: TxnState = .Active,
    start_ts: Timestamp,
    commit_ts: Timestamp = 0,
};

pub const LockMode = enum { Shared, Exclusive };

pub const LockEntry = struct {
    txn_id: TxnId,
    mode: LockMode,
    count: u32 = 1, // for lock escalation
};

pub const ConflictType = enum { ReadWrite, WriteWrite, WriteRead };

pub const ConflictMatrix = struct {
    conflicts: std.AutoHashMap(struct { TxnId, TxnId }, ConflictType),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConflictMatrix {
        return .{
            .conflicts = std.AutoHashMap(struct { TxnId, TxnId }, ConflictType).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConflictMatrix) void {
        self.conflicts.deinit();
    }

    pub fn addConflict(self: *ConflictMatrix, t1: TxnId, t2: TxnId, conflict_type: ConflictType) !void {
        try self.conflicts.put(.{ t1, t2 }, conflict_type);
    }

    pub fn hasConflict(self: *ConflictMatrix, t1: TxnId, t2: TxnId) bool {
        return self.conflicts.contains(.{ t1, t2 }) or self.conflicts.contains(.{ t2, t1 });
    }

    pub fn getConflictType(self: *ConflictMatrix, t1: TxnId, t2: TxnId) ?ConflictType {
        if (self.conflicts.get(.{ t1, t2 })) |ct| return ct;
        if (self.conflicts.get(.{ t2, t1 })) |ct| return ct;
        return null;
    }

    pub fn removeConflicts(self: *ConflictMatrix, txn_id: TxnId) void {
        var to_remove = std.ArrayList(struct { TxnId, TxnId }).empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.conflicts.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            if (key[0] == txn_id or key[1] == txn_id) {
                to_remove.append(self.allocator, key) catch continue;
            }
        }

        for (to_remove.items) |key| {
            _ = self.conflicts.remove(key);
        }
    }
};

pub const Manager = struct {
    next_id: TxnId = 1,
    next_ts: Timestamp = 1,
    locks: std.StringHashMap(std.ArrayList(LockEntry)) = undefined, // key -> list of lock holders
    active_txns: std.AutoHashMap(TxnId, Txn) = undefined,
    wait_for_graph: std.AutoHashMap(TxnId, std.ArrayList(TxnId)) = undefined, // deadlock detection
    conflict_matrix: ConflictMatrix = undefined, // write-write conflict detection
    allocator: std.mem.Allocator,
    advanced: ?mvcc_adv.Aggregator = null, // advanced MVCC instrumentation (optional)
    phantom_enabled: bool = false,
    // Predicated range reads tracked per txn (simple prefix-based predicates for demo)
    predicates: std.AutoHashMap(TxnId, std.ArrayList([]u8)) = undefined,
    // Global committed & uncommitted writes (key + owning txn + commit ts (0 while active))
    writes: std.ArrayListUnmanaged(struct { key: []u8, txn_id: TxnId, commit_ts: Timestamp }) = .empty,
    // Explicit range tracker (optional until phantom prevention enabled)
    rtracker: ?range_tracker.RangeTracker = null,

    pub fn init(self: *Manager, allocator: std.mem.Allocator) void {
        self.* = .{
            .next_id = 1,
            .next_ts = 1,
            .locks = std.StringHashMap(std.ArrayList(LockEntry)).init(allocator),
            .active_txns = std.AutoHashMap(TxnId, Txn).init(allocator),
            .wait_for_graph = std.AutoHashMap(TxnId, std.ArrayList(TxnId)).init(allocator),
            .conflict_matrix = ConflictMatrix.init(allocator),
            .allocator = allocator,
            .phantom_enabled = false,
            .predicates = std.AutoHashMap(TxnId, std.ArrayList([]u8)).init(allocator),
            .writes = .empty,
            .rtracker = null,
        };
    }

    pub fn deinit(self: *Manager) void {
        if (self.advanced) |*adv| adv.deinit();
        if (self.rtracker) |*rt| rt.deinit();
        // Clean up lock lists and keys
        var lock_iter = self.locks.iterator();
        while (lock_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.locks.deinit();

        // Clean up wait-for graph
        var wait_iter = self.wait_for_graph.iterator();
        while (wait_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.wait_for_graph.deinit();

        self.conflict_matrix.deinit();
        self.active_txns.deinit();
        // free predicate prefixes
        var pit = self.predicates.iterator();
        while (pit.next()) |entry| {
            var list = entry.value_ptr;
            for (list.items) |p| self.allocator.free(p);
            list.deinit(self.allocator);
        }
        self.predicates.deinit();
        for (self.writes.items) |w| self.allocator.free(w.key);
        self.writes.deinit(self.allocator);
    }

    pub fn enableAdvanced(self: *Manager) !void {
        if (self.advanced == null) {
            self.advanced = try mvcc_adv.Aggregator.init(self.allocator);
        }
    }

    pub fn enablePredictiveSkew(self: *Manager) !void {
        try self.enableAdvanced();
        if (self.advanced) |*adv| adv.enableSkew();
    }

    pub fn enablePhantomPrevention(self: *Manager) void {
        self.phantom_enabled = true;
        if (self.rtracker == null) self.rtracker = range_tracker.RangeTracker.init(self.allocator);
    }

    pub fn begin(self: *Manager) Txn {
        const id = self.next_id;
        self.next_id += 1;
        const ts = self.next_ts;
        self.next_ts += 1;
        const txn = Txn{ .id = id, .start_ts = ts };
        self.active_txns.put(id, txn) catch {};
        otel_metrics.incTransactionActive(.snapshot);
        otel_metrics.recordTransactionBegin(.snapshot);
        return txn;
    }

    // Represents a consistent read view (snapshot) capturing the current timestamp frontier
    // and a list of active (in-progress) transaction ids for future phantom / conflict checks.
    pub const Snapshot = struct {
        ts: Timestamp,
        active: []TxnId,
    };

    pub fn captureSnapshot(self: *Manager, allocator: std.mem.Allocator) !Snapshot {
        const snap_ts = self.next_ts - 1; // last issued timestamp is visible frontier
        var count: usize = 0;
        var iter_count = self.active_txns.iterator();
        while (iter_count.next()) |_| count += 1;
        const arr = try allocator.alloc(TxnId, count);
        var iter = self.active_txns.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) arr[i] = entry.value_ptr.id;
        return .{ .ts = snap_ts, .active = arr };
    }

    pub fn releaseSnapshot(_: *Manager, allocator: std.mem.Allocator, snap: Snapshot) void {
        allocator.free(snap.active);
    }

    pub fn commit(self: *Manager, txn: *Txn) !void {
        if (self.advanced) |*adv| {
            var iter = self.active_txns.iterator();
            while (iter.next()) |entry| {
                const other = entry.value_ptr.*;
                if (other.id == txn.id) continue;
                if (adv.predictOverlap(txn.id, other.id)) {
                    if (txn.id > other.id and other.state == .Active) {
                        // Phase C2: SSI dangerous-structure early abort (rw-antidependency).
                        otel_metrics.recordSerializationConflict("rw_antidependency");
                        return error.EarlyConflict;
                    }
                }
            }
        }
        // Check for write-write conflicts before committing
        if (try self.hasWriteWriteConflicts(txn.id)) {
            if (@import("builtin").mode == .Debug) {
                const shard_worker_tls = @import("shard_worker_tls");
                if (shard_worker_tls.t_is_shard_worker) {
                    std.debug.panic(
                        "write-write conflict under ShardedCoordinator routing — " ++
                            "the routing contract (same source_id → same shard → same thread) " ++
                            "has been violated. See " ++
                            "docs/superpowers/specs/2026-04-25-sharded-coordinator-restoration-design.md",
                        .{},
                    );
                }
            }
            // Phase C2: real SSI write-write serialization conflict at commit.
            otel_metrics.recordSerializationConflict("write_write");
            return error.SerializationFailure;
        }

        // Phantom detection before commit stamping
        if (self.phantom_enabled) {
            try self.detectPhantoms(txn);
        }

        // Assign commit timestamp
        txn.state = .Committed;
        txn.commit_ts = self.next_ts;
        self.next_ts += 1;

        // Stamp commit_ts on this txn's writes
        for (self.writes.items) |*w| {
            if (w.txn_id == txn.id) {
                w.commit_ts = txn.commit_ts;
            }
        }

        // Release all locks held by this transaction
        self.releaseAllLocks(txn.id);

        // Remove from conflict matrix
        self.conflict_matrix.removeConflicts(txn.id);

        self.cleanupTxnTracking(txn.id);
        _ = self.active_txns.remove(txn.id);
        self.pruneWrites();
        otel_metrics.recordTransactionCommit(.snapshot, 0.0, .success);
        otel_metrics.decTransactionActive(.snapshot);
    }

    pub fn rollback(self: *Manager, txn: *Txn) void {
        txn.state = .Aborted;

        // Release all locks held by this transaction
        self.releaseAllLocks(txn.id);

        // Remove from conflict matrix
        self.conflict_matrix.removeConflicts(txn.id);

        self.cleanupTxnTracking(txn.id);
        self.removeWritesForTxn(txn.id);
        _ = self.active_txns.remove(txn.id);
        self.pruneWrites();
        otel_metrics.recordTransactionAbort(.user, null);
        otel_metrics.decTransactionActive(.snapshot);
    }

    fn hasWriteWriteConflicts(self: *Manager, txn_id: TxnId) !bool {
        var iter = self.conflict_matrix.conflicts.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const conflict_type = entry.value_ptr.*;

            if ((key[0] == txn_id or key[1] == txn_id) and conflict_type == .WriteWrite) {
                // Check if the conflicting transaction is still active
                const other_txn = if (key[0] == txn_id) key[1] else key[0];
                if (self.active_txns.contains(other_txn)) {
                    return true;
                }
            }
        }
        return false;
    }

    fn releaseAllLocks(self: *Manager, txn_id: TxnId) void {
        var lock_iter = self.locks.iterator();
        while (lock_iter.next()) |entry| {
            var lock_list = entry.value_ptr;
            var i: usize = 0;
            while (i < lock_list.items.len) {
                if (lock_list.items[i].txn_id == txn_id) {
                    _ = lock_list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Remove from wait-for graph
        _ = self.wait_for_graph.remove(txn_id);
        var wait_iter = self.wait_for_graph.iterator();
        while (wait_iter.next()) |entry| {
            var wait_list = entry.value_ptr;
            var i: usize = 0;
            while (i < wait_list.items.len) {
                if (wait_list.items[i] == txn_id) {
                    _ = wait_list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    // Enhanced lock acquisition with conflict detection
    pub fn acquireLock(self: *Manager, key: []const u8, txn: *Txn, mode: LockMode, allocator: std.mem.Allocator) !void {
        if (mode == .Exclusive) {
            if (self.advanced) |*adv| if (adv.skew) |*f| {
                if (f.isHot(key)) return error.HotSkew;
            };
        }
        const entry = try self.locks.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try allocator.dupe(u8, key);
            entry.value_ptr.* = std.ArrayList(LockEntry).empty;
        }

        const lock_list = entry.value_ptr;

        // Check if transaction already holds a lock on this resource
        for (lock_list.items) |*lock_entry| {
            if (lock_entry.txn_id == txn.id) {
                // Lock escalation: upgrade shared to exclusive if needed
                if (lock_entry.mode == .Shared and mode == .Exclusive) {
                    // Check if other transactions hold shared locks
                    var other_shared = false;
                    for (lock_list.items) |other_lock| {
                        if (other_lock.txn_id != txn.id and other_lock.mode == .Shared) {
                            other_shared = true;
                            break;
                        }
                    }
                    if (other_shared) {
                        return error.LockConflict;
                    }
                    lock_entry.mode = .Exclusive;
                }
                lock_entry.count += 1;
                return;
            }
        }

        // Check for conflicts with existing locks
        for (lock_list.items) |existing_lock| {
            if (existing_lock.txn_id != txn.id) {
                // Record write-write conflicts for serialization failure detection
                if (existing_lock.mode == .Exclusive and mode == .Exclusive) {
                    try self.conflict_matrix.addConflict(txn.id, existing_lock.txn_id, .WriteWrite);
                } else if (existing_lock.mode == .Exclusive and mode == .Shared) {
                    try self.conflict_matrix.addConflict(txn.id, existing_lock.txn_id, .WriteRead);
                } else if (existing_lock.mode == .Shared and mode == .Exclusive) {
                    try self.conflict_matrix.addConflict(txn.id, existing_lock.txn_id, .ReadWrite);
                }

                // Conflict matrix: Exclusive conflicts with everything, Shared conflicts with Exclusive
                if (existing_lock.mode == .Exclusive or mode == .Exclusive) {
                    // Add to wait-for graph for deadlock detection
                    try self.addWaitFor(txn.id, existing_lock.txn_id);

                    // Check for deadlock
                    if (try self.detectDeadlock(txn.id)) {
                        // Phase C2: real wait-for-graph cycle detected. The
                        // requesting (waiting) txn is the victim — it receives
                        // error.Deadlock and must abort.
                        otel_metrics.recordDeadlock("requester_aborts");
                        return error.Deadlock;
                    }

                    return error.LockConflict;
                }
            }
        }

        // Grant the lock
        try lock_list.append(self.allocator, LockEntry{ .txn_id = txn.id, .mode = mode });
        if (self.advanced) |*adv| {
            if (mode == .Exclusive) {
                adv.noteWrite(txn.id, key, txn.start_ts) catch {};
            } else {
                adv.noteRead(txn.id, key) catch {};
            }
        }
    }

    // existing enableAdvanced relocated above

    pub fn recordRead(self: *Manager, key: []const u8, txn: *Txn) void {
        if (self.advanced) |*adv| adv.noteRead(txn.id, key) catch {};
    }

    pub fn recordWrite(self: *Manager, key: []const u8, txn: *Txn) void {
        if (self.advanced) |*adv| adv.noteWrite(txn.id, key, txn.start_ts) catch {};
        // Track write for phantom detection (duplicate key copy)
        const dup = self.allocator.dupe(u8, key) catch return;
        self.writes.append(self.allocator, .{ .key = dup, .txn_id = txn.id, .commit_ts = 0 }) catch {
            self.allocator.free(dup);
            return;
        };
    }

    fn detectPhantoms(self: *Manager, txn: *Txn) !void {
        if (self.predicates.get(txn.id)) |plist| {
            for (plist.items) |prefix| {
                for (self.writes.items) |w| {
                    if (w.txn_id == txn.id) continue;
                    if (w.commit_ts == 0) continue;
                    if (w.commit_ts <= txn.start_ts) continue;
                    if (std.mem.startsWith(u8, w.key, prefix)) {
                        // Phase C2: phantom write under a tracked predicate prefix.
                        otel_metrics.recordSerializationConflict("phantom_predicate");
                        return error.SerializationFailure;
                    }
                }
            }
        }
        if (self.rtracker) |*rt| {
            for (self.writes.items) |w| {
                if (w.txn_id == txn.id) continue;
                if (w.commit_ts == 0) continue;
                if (w.commit_ts <= txn.start_ts) continue;
                if (rt.keyInRanges(txn.id, w.key)) {
                    // Phase C2: phantom write inside a tracked range scan.
                    otel_metrics.recordSerializationConflict("phantom_range");
                    return error.SerializationFailure;
                }
            }
        }
    }

    pub fn checkPhantoms(self: *Manager, txn: *Txn) !void {
        if (!self.phantom_enabled) return;
        return self.detectPhantoms(txn);
    }

    fn addWaitFor(self: *Manager, waiter: TxnId, holder: TxnId) !void {
        const entry = try self.wait_for_graph.getOrPut(waiter);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(TxnId).empty;
        }

        // Avoid duplicates
        for (entry.value_ptr.items) |existing| {
            if (existing == holder) return;
        }

        try entry.value_ptr.append(self.allocator, holder);
    }

    pub fn detectDeadlock(self: *Manager, start_txn: TxnId) !bool {
        var visited = std.AutoHashMap(TxnId, void).init(self.allocator);
        defer visited.deinit();

        var path = std.AutoHashMap(TxnId, void).init(self.allocator);
        defer path.deinit();

        return self.dfsDeadlock(start_txn, start_txn, &visited, &path);
    }

    fn dfsDeadlock(self: *Manager, current: TxnId, target: TxnId, visited: *std.AutoHashMap(TxnId, void), path: *std.AutoHashMap(TxnId, void)) bool {
        if (path.contains(current)) {
            return current == target; // Found cycle back to target
        }

        if (visited.contains(current)) {
            return false;
        }

        visited.put(current, {}) catch return false;
        path.put(current, {}) catch return false;

        if (self.wait_for_graph.get(current)) |wait_list| {
            for (wait_list.items) |next_txn| {
                if (self.dfsDeadlock(next_txn, target, visited, path)) {
                    return true;
                }
            }
        }

        _ = path.remove(current);
        return false;
    }

    // Acquire exclusive write lock; conflict if different txn holds it.
    pub fn acquireWrite(self: *Manager, key: []const u8, txn: *Txn, allocator: std.mem.Allocator) !void {
        return self.acquireLock(key, txn, .Exclusive, allocator);
    }

    // Acquire shared read lock
    pub fn acquireRead(self: *Manager, key: []const u8, txn: *Txn, allocator: std.mem.Allocator) !void {
        return self.acquireLock(key, txn, .Shared, allocator);
    }

    pub fn releaseWrite(self: *Manager, key: []const u8, txn: *Txn) void {
        self.releaseLock(key, txn.id);
    }

    // Record a predicate range read (prefix) for phantom detection under SSI
    pub fn predicateRead(self: *Manager, txn: *Txn, prefix: []const u8) !void {
        if (!self.phantom_enabled) return; // no-op if disabled
        const entry = try self.predicates.getOrPut(txn.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList([]u8).empty;
        }
        // avoid duplicates
        for (entry.value_ptr.items) |p| if (std.mem.eql(u8, p, prefix)) return;
        const dup = try self.allocator.dupe(u8, prefix);
        try entry.value_ptr.append(self.allocator, dup);
    }

    // Register an explicit key range [low, high] for phantom detection.
    // CANARY: REQ=REQ-GQL-023; FEATURE="MVCC Phantom Prevention"; ASPECT=RangeTracker; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_023_PhantomPreventionRangeDetection; BENCH=BenchmarkCANARY_REQ_GQL_023_PhantomPreventionOverheadVarianceEnvelope; OWNER=txn; UPDATED=2025-09-26
    pub fn rangeRead(self: *Manager, txn: *Txn, low: []const u8, high: []const u8) !void {
        if (!self.phantom_enabled) return;
        if (self.rtracker) |*rt| try rt.register(txn.id, low, high);
    }

    pub fn releaseRead(self: *Manager, key: []const u8, txn: *Txn) void {
        self.releaseLock(key, txn.id);
    }

    pub fn unlock(self: *Manager, key: []const u8, txn_id: TxnId) void {
        self.releaseLock(key, txn_id);
    }

    pub fn unlockAll(self: *Manager, txn_id: TxnId) void {
        self.releaseAllLocks(txn_id);
    }

    fn releaseLock(self: *Manager, key: []const u8, txn_id: TxnId) void {
        if (self.locks.getPtr(key)) |lock_list| {
            var i: usize = 0;
            while (i < lock_list.items.len) {
                if (lock_list.items[i].txn_id == txn_id) {
                    lock_list.items[i].count -= 1;
                    if (lock_list.items[i].count == 0) {
                        _ = lock_list.swapRemove(i);
                    } else {
                        i += 1;
                    }
                } else {
                    i += 1;
                }
            }
        }
    }

    fn cleanupTxnTracking(self: *Manager, txn_id: TxnId) void {
        if (self.predicates.getPtr(txn_id)) |plist| {
            for (plist.items) |p| self.allocator.free(p);
            plist.deinit(self.allocator);
            _ = self.predicates.remove(txn_id);
        }
        if (self.rtracker) |*rt| {
            rt.clearTxn(txn_id);
        }
    }

    fn removeWritesForTxn(self: *Manager, txn_id: TxnId) void {
        var i: usize = 0;
        while (i < self.writes.items.len) {
            if (self.writes.items[i].txn_id == txn_id) {
                self.allocator.free(self.writes.items[i].key);
                _ = self.writes.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn pruneWrites(self: *Manager) void {
        if (self.writes.items.len == 0) return;
        var min_start: Timestamp = self.next_ts;
        var has_active = false;
        var iter = self.active_txns.iterator();
        while (iter.next()) |entry| {
            has_active = true;
            if (entry.value_ptr.start_ts < min_start) {
                min_start = entry.value_ptr.start_ts;
            }
        }
        var i: usize = 0;
        while (i < self.writes.items.len) {
            const w = self.writes.items[i];
            const inactive_uncommitted = (w.commit_ts == 0) and !self.active_txns.contains(w.txn_id);
            const eligible_committed = w.commit_ts != 0 and (!has_active or w.commit_ts <= min_start);
            if (inactive_uncommitted or eligible_committed) {
                self.allocator.free(w.key);
                _ = self.writes.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

pub const Version = struct {
    create_ts: Timestamp,
    delete_ts: Timestamp = 0,
    prev: ?*Version = null,
    payload: []const u8,
};

pub const RowChain = struct { head: ?*Version = null };

pub fn visible(chain: *const RowChain, snap: Timestamp) ?*Version {
    var v = chain.head;
    while (v) |cur| {
        if (cur.create_ts <= snap and (cur.delete_ts == 0 or snap < cur.delete_ts)) return cur;
        v = cur.prev;
    }
    return null;
}

pub fn mvccInsert(allocator: std.mem.Allocator, chain: *RowChain, create_ts: Timestamp, payload: []const u8) !void {
    const v = try allocator.create(Version);
    v.* = .{ .create_ts = create_ts, .payload = payload, .prev = chain.head };
    chain.head = v;
}

pub fn mvccDelete(chain: *RowChain, delete_ts: Timestamp) void {
    if (chain.head) |h| {
        if (h.delete_ts == 0) h.delete_ts = delete_ts;
    }
}

// Rollback: undo versions created after snapshot_ts by marking logically discarded (set delete_ts=create_ts for those versions)
pub fn mvccRollback(chain: *RowChain, snapshot_ts: Timestamp) void {
    var v = chain.head;
    while (v) |cur| {
        if (cur.create_ts >= snapshot_ts and cur.delete_ts == 0) {
            cur.delete_ts = cur.create_ts; // self-invalidating
        }
        v = cur.prev;
    }
}

test "mvcc visibility with delete_ts and rollback" {
    var chain: RowChain = .{};
    const allocator = std.testing.allocator;
    try mvccInsert(allocator, &chain, 5, "a");
    try mvccInsert(allocator, &chain, 7, "b");
    // snapshot at ts=6 should see version create_ts=5
    try std.testing.expect(visible(&chain, 6).?.create_ts == 5);
    // delete latest at ts=8
    mvccDelete(&chain, 8);
    try std.testing.expect(visible(&chain, 9).?.create_ts == 5); // b deleted
    // rollback changes >=7 (simulate abort of version b before commit) snapshot_ts=7
    mvccRollback(&chain, 7);
    // now b is self-invalidated for any snapshot >=7; visibility at 10 still 5
    try std.testing.expect(visible(&chain, 10).?.create_ts == 5);

    // Cleanup
    var v = chain.head;
    while (v) |cur| {
        const next = cur.prev;
        allocator.destroy(cur);
        v = next;
    }
}

test "txn manager: enhanced lock conflict detection" {
    var mgr: Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();

    var t1 = mgr.begin();
    var t2 = mgr.begin();

    // T1 acquires shared lock
    try mgr.acquireRead("row:1", &t1, std.testing.allocator);

    // T2 can also acquire shared lock
    try mgr.acquireRead("row:1", &t2, std.testing.allocator);

    // T1 tries to upgrade to exclusive - should conflict
    try std.testing.expectError(error.LockConflict, mgr.acquireWrite("row:1", &t1, std.testing.allocator));

    mgr.releaseRead("row:1", &t2);

    // Now T1 should be able to upgrade
    try mgr.acquireWrite("row:1", &t1, std.testing.allocator);

    mgr.releaseWrite("row:1", &t1);
}

test "txn manager: deadlock detection" {
    var mgr: Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();

    var t1 = mgr.begin();
    var t2 = mgr.begin();

    // T1 locks resource A
    try mgr.acquireWrite("A", &t1, std.testing.allocator);

    // T2 locks resource B
    try mgr.acquireWrite("B", &t2, std.testing.allocator);

    // T1 tries to lock B (will wait for T2)
    try std.testing.expectError(error.LockConflict, mgr.acquireWrite("B", &t1, std.testing.allocator));

    // T2 tries to lock A (would create deadlock)
    try std.testing.expectError(error.Deadlock, mgr.acquireWrite("A", &t2, std.testing.allocator));
}

test "txn manager: write-write conflict detection" {
    var mgr: Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();

    var t1 = mgr.begin();
    var t2 = mgr.begin();

    // T1 acquires exclusive lock on resource
    try mgr.acquireWrite("row:1", &t1, std.testing.allocator);

    // T2 tries to acquire exclusive lock on same resource (conflict)
    try std.testing.expectError(error.LockConflict, mgr.acquireWrite("row:1", &t2, std.testing.allocator));

    // Verify conflict is recorded
    try std.testing.expect(mgr.conflict_matrix.hasConflict(t1.id, t2.id));
    try std.testing.expect(mgr.conflict_matrix.getConflictType(t1.id, t2.id) == .WriteWrite);

    // T1 commits successfully
    try mgr.commit(&t1);

    // T2 should now be able to acquire the lock
    try mgr.acquireWrite("row:1", &t2, std.testing.allocator);
    try mgr.commit(&t2);
}

test "txn manager: serialization failure on commit" {
    var mgr: Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();

    var t1 = mgr.begin();
    var t2 = mgr.begin();

    // Simulate write-write conflict by manually adding to conflict matrix
    try mgr.conflict_matrix.addConflict(t1.id, t2.id, .WriteWrite);

    // T1 tries to commit but should fail due to active conflicting transaction
    try std.testing.expectError(error.SerializationFailure, mgr.commit(&t1));

    // After T2 commits, conflicts should be cleaned up
    try mgr.commit(&t2);

    // Now T1 should be able to commit (if it were still active)
    // But since T1 already failed, we'll test with a new transaction
    var t3 = mgr.begin();
    try mgr.commit(&t3);
}

test "txn manager: rollback cleans writes and ranges" {
    var mgr: Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();
    mgr.enablePhantomPrevention();

    var t1 = mgr.begin();
    try mgr.predicateRead(&t1, "user:");
    try mgr.rangeRead(&t1, "a", "z");
    mgr.recordWrite("user:1", &t1);

    try std.testing.expectEqual(@as(usize, 1), mgr.writes.items.len);
    mgr.rollback(&t1);
    try std.testing.expectEqual(@as(usize, 0), mgr.writes.items.len);
    try std.testing.expect(!mgr.predicates.contains(t1.id));
    if (mgr.rtracker) |*rt| {
        try std.testing.expect(!rt.keyInRanges(t1.id, "m"));
    }
}

test "txn manager: phantom conflict does not commit writes" {
    var mgr: Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();
    mgr.enablePhantomPrevention();

    var t1 = mgr.begin();
    try mgr.predicateRead(&t1, "k");
    mgr.recordWrite("k-local", &t1);

    var t2 = mgr.begin();
    mgr.recordWrite("k-other", &t2);
    try mgr.commit(&t2);

    try std.testing.expectError(error.SerializationFailure, mgr.commit(&t1));
    mgr.rollback(&t1);

    for (mgr.writes.items) |w| {
        try std.testing.expect(w.txn_id != t1.id);
    }
}

test "txn manager: commit prunes writes when no active transactions" {
    var mgr: Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();

    var t1 = mgr.begin();
    mgr.recordWrite("k1", &t1);
    try mgr.commit(&t1);
    try std.testing.expectEqual(@as(usize, 0), mgr.writes.items.len);
}
