const std = @import("std");

pub const TxnId = u64;

pub const TxnState = enum { Active, Committed, Aborted };

pub const Timestamp = u64;

pub const Txn = struct {
    id: TxnId,
    state: TxnState = .Active,
    start_ts: Timestamp,
};

pub const Manager = struct {
    next_id: TxnId = 1,
    next_ts: Timestamp = 1,

    pub fn begin(self: *Manager) Txn {
        const id = self.next_id;
        self.next_id += 1;
        const ts = self.next_ts;
        self.next_ts += 1;
        return .{ .id = id, .start_ts = ts };
    }

    pub fn commit(self: *Manager, txn: *Txn) void {
        txn.state = .Committed;
        // future: assign commit_ts separate from start_ts for SSI
        _ = self;
    }

    pub fn rollback(self: *Manager, txn: *Txn) void {
        txn.state = .Aborted;
        _ = self;
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
