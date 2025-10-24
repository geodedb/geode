const std = @import("std");

pub const WalHandle = struct {
    flushUpToFn: *const fn (lsn: u64) anyerror!void,
};

// P2-3: Use static GPA for global WAL handles list
var wal_handles_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var wal_handles = std.ArrayList(*WalHandle).init(wal_handles_gpa.allocator());

pub fn registerWal(handle: *WalHandle) void {
    _ = wal_handles.append(handle) catch {};
}

pub fn beforeCommit(lsn: u64) !void {
    var i: usize = 0;
    while (i < wal_handles.items.len) : (i += 1) {
        try wal_handles.items[i].flushUpToFn(lsn);
    }
}

pub fn ensureWalBeforeData(lsn: u64) !void {
    try beforeCommit(lsn);
}
