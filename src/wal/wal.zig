const std = @import("std");

pub const Lsn = u64;

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
    next_lsn: Lsn = 1,
    // In-memory ring buffer stub; persistent file later
    buf: std.ArrayList(Record),

    pub fn init(ally: std.mem.Allocator) Wal {
        // Zig 0.15 removed ArrayList.init; use initCapacity(0)
        const list = std.ArrayList(Record).initCapacity(ally, 0) catch @panic("OOM WAL init");
        return .{ .ally = ally, .buf = list };
    }

    pub fn deinit(self: *Wal) void {
        self.buf.deinit(self.ally);
    }

    pub fn append(self: *Wal, txn_id: u64, typ: RecordType, payload: []const u8) !Lsn {
        const lsn = self.next_lsn;
        self.next_lsn += 1;
        try self.buf.append(self.ally, .{ .lsn = lsn, .txn_id = txn_id, .typ = typ, .payload = payload });
        return lsn;
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
