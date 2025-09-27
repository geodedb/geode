const std = @import("std");

pub const WalHandle = struct {
    flushUpToFn: *const fn (lsn: u64) anyerror!void,
};

var wal_handles = std.ArrayList(*WalHandle).init(std.heap.page_allocator);

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
