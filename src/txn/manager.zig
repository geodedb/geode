const std = @import("std");

pub const TxnId = u64;

pub const TxnState = enum { Active, Committed, Aborted };

pub const Txn = struct {
    id: TxnId,
    state: TxnState = .Active,
};

pub const Manager = struct {
    next_id: TxnId = 1,

    pub fn begin(self: *Manager) Txn {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .id = id };
    }

    pub fn commit(self: *Manager, txn: *Txn) void {
        txn.state = .Committed;
        _ = self; // future: WAL flush, locks release
    }

    pub fn rollback(self: *Manager, txn: *Txn) void {
        txn.state = .Aborted;
        _ = self; // future: undo via WAL
    }
};
