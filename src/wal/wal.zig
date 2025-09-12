const std = @import("std");

// Log Sequence Number (LSN) wrapper. Future: encode epoch or segment.
pub const Lsn = struct {
    value: u64,
};

pub const RecordType = enum { Begin, Update, Commit, Abort, CLR, Checkpoint };

pub const Record = struct {
    lsn: Lsn,
    prev_lsn: Lsn = 0,
    txn_id: u64 = 0,
    typ: RecordType,
    payload: []const u8 = &.{},
};

pub const Wal = struct {
    ally: std.mem.Allocator,
    next_lsn: u64 = 1,
    // In-memory buffer stub; later: mmap'd segment files.
    buf: std.ArrayList(Record),

    pub fn init(ally: std.mem.Allocator) Wal {
        // Zig 0.15 removed ArrayList.init; use initCapacity(0)
        const list = std.ArrayList(Record).initCapacity(ally, 0) catch @panic("OOM WAL init");
        return .{ .ally = ally, .buf = list };
    }

    pub fn deinit(self: *Wal) void {
        self.buf.deinit(self.ally);
    }

    /// Append a record. WAL rule (write-ahead): before dirty page with update is flushed,
    /// its corresponding log record (and predecessors) must be durable. This in-memory stub
    /// only guarantees monotonic LSN assignment.
    pub fn append(self: *Wal, txn_id: u64, typ: RecordType, payload: []const u8) !Lsn {
        const lsn_val = self.next_lsn;
        self.next_lsn += 1;
        const rec_lsn: Lsn = .{ .value = lsn_val };
        try self.buf.append(self.ally, .{ .lsn = lsn_val, .txn_id = txn_id, .typ = typ, .payload = payload });
        return rec_lsn;
    }

    pub fn iter(self: *Wal) WalIter {
        return .{ .wal = self, .idx = 0 };
    }
};

pub const WalIter = struct {
    wal: *Wal,
    idx: usize,
    pub fn next(self: *WalIter) ?Record {
        if (self.idx >= self.wal.buf.items.len) return null;
        const r = self.wal.buf.items[self.idx];
        self.idx += 1;
        return r;
    }
};
