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

pub const Manager = struct {
    next_id: TxnId = 1,
    next_ts: Timestamp = 1,
    locks: std.StringHashMap(TxnId) = undefined, // key -> owning txn id

    pub fn init(self: *Manager, ally: std.mem.Allocator) void {
        self.* = .{ .next_id = 1, .next_ts = 1, .locks = std.StringHashMap(TxnId).init(ally) };
    }
    pub fn deinit(self: *Manager) void {
        self.locks.deinit();
    }

    pub fn begin(self: *Manager) Txn {
        const id = self.next_id;
        self.next_id += 1;
        const ts = self.next_ts;
        self.next_ts += 1;
        return .{ .id = id, .start_ts = ts };
    }

    pub fn commit(self: *Manager, txn: *Txn) void {
        txn.state = .Committed;
        txn.commit_ts = self.next_ts;
        self.next_ts += 1;
    }

    pub fn rollback(self: *Manager, txn: *Txn) void {
        txn.state = .Aborted;
        _ = self;
    }

    // Acquire exclusive write lock; conflict if different txn holds it.
    pub fn acquireWrite(self: *Manager, key: []const u8, txn: *Txn, ally: std.mem.Allocator) !void {
        const entry = try self.locks.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try ally.dupe(u8, key);
            entry.value_ptr.* = txn.id;
            return;
        }
        if (entry.value_ptr.* != txn.id) return error.WriteConflict;
    }

    pub fn releaseWrite(self: *Manager, key: []const u8, txn: *Txn) void {
        if (self.locks.get(key)) |owner| {
            if (owner == txn.id) {
                _ = self.locks.remove(key);
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
}

test "txn manager: write conflict and release" {
    var mgr: Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();
    var t1 = mgr.begin();
    var t2 = mgr.begin();
    try mgr.acquireWrite("row:1", &t1, std.testing.allocator);
    try std.testing.expectError(error.WriteConflict, mgr.acquireWrite("row:1", &t2, std.testing.allocator));
    mgr.releaseWrite("row:1", &t1);
    try mgr.acquireWrite("row:1", &t2, std.testing.allocator);
}
