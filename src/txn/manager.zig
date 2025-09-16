const std = @import("std");

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

pub const Manager = struct {
    next_id: TxnId = 1,
    next_ts: Timestamp = 1,
    locks: std.StringHashMap(std.ArrayList(LockEntry)) = undefined, // key -> list of lock holders
    active_txns: std.AutoHashMap(TxnId, Txn) = undefined,
    wait_for_graph: std.AutoHashMap(TxnId, std.ArrayList(TxnId)) = undefined, // deadlock detection
    allocator: std.mem.Allocator,

    pub fn init(self: *Manager, ally: std.mem.Allocator) void {
        self.* = .{
            .next_id = 1,
            .next_ts = 1,
            .locks = std.StringHashMap(std.ArrayList(LockEntry)).init(ally),
            .active_txns = std.AutoHashMap(TxnId, Txn).init(ally),
            .wait_for_graph = std.AutoHashMap(TxnId, std.ArrayList(TxnId)).init(ally),
            .allocator = ally,
        };
    }

    pub fn deinit(self: *Manager) void {
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

        self.active_txns.deinit();
    }

    pub fn begin(self: *Manager) Txn {
        const id = self.next_id;
        self.next_id += 1;
        const ts = self.next_ts;
        self.next_ts += 1;
        const txn = Txn{ .id = id, .start_ts = ts };
        self.active_txns.put(id, txn) catch {};
        return txn;
    }

    pub fn commit(self: *Manager, txn: *Txn) void {
        txn.state = .Committed;
        txn.commit_ts = self.next_ts;
        self.next_ts += 1;

        // Release all locks held by this transaction
        self.releaseAllLocks(txn.id);
        _ = self.active_txns.remove(txn.id);
    }

    pub fn rollback(self: *Manager, txn: *Txn) void {
        txn.state = .Aborted;

        // Release all locks held by this transaction
        self.releaseAllLocks(txn.id);
        _ = self.active_txns.remove(txn.id);
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
    pub fn acquireLock(self: *Manager, key: []const u8, txn: *Txn, mode: LockMode, ally: std.mem.Allocator) !void {
        const entry = try self.locks.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try ally.dupe(u8, key);
            entry.value_ptr.* = std.ArrayList(LockEntry).initCapacity(self.allocator, 0) catch @panic("OOM");
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
                // Conflict matrix: Exclusive conflicts with everything, Shared conflicts with Exclusive
                if (existing_lock.mode == .Exclusive or mode == .Exclusive) {
                    // Add to wait-for graph for deadlock detection
                    try self.addWaitFor(txn.id, existing_lock.txn_id);

                    // Check for deadlock
                    if (try self.detectDeadlock(txn.id)) {
                        return error.Deadlock;
                    }

                    return error.LockConflict;
                }
            }
        }

        // Grant the lock
        try lock_list.append(self.allocator, LockEntry{ .txn_id = txn.id, .mode = mode });
    }

    fn addWaitFor(self: *Manager, waiter: TxnId, holder: TxnId) !void {
        const entry = try self.wait_for_graph.getOrPut(waiter);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(TxnId).initCapacity(self.allocator, 0) catch @panic("OOM");
        }

        // Avoid duplicates
        for (entry.value_ptr.items) |existing| {
            if (existing == holder) return;
        }

        try entry.value_ptr.append(self.allocator, holder);
    }

    fn detectDeadlock(self: *Manager, start_txn: TxnId) !bool {
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
    pub fn acquireWrite(self: *Manager, key: []const u8, txn: *Txn, ally: std.mem.Allocator) !void {
        return self.acquireLock(key, txn, .Exclusive, ally);
    }

    // Acquire shared read lock
    pub fn acquireRead(self: *Manager, key: []const u8, txn: *Txn, ally: std.mem.Allocator) !void {
        return self.acquireLock(key, txn, .Shared, ally);
    }

    pub fn releaseWrite(self: *Manager, key: []const u8, txn: *Txn) void {
        self.releaseLock(key, txn.id);
    }

    pub fn releaseRead(self: *Manager, key: []const u8, txn: *Txn) void {
        self.releaseLock(key, txn.id);
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

pub fn mvccInsert(ally: std.mem.Allocator, chain: *RowChain, create_ts: Timestamp, payload: []const u8) !void {
    const v = try ally.create(Version);
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
    const ally = std.testing.allocator;
    try mvccInsert(ally, &chain, 5, "a");
    try mvccInsert(ally, &chain, 7, "b");
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
        ally.destroy(cur);
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
