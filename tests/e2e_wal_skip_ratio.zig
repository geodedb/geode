const std = @import("std");
const wal_mod = @import("../src/wal/wal.zig");
const storage = @import("../src/storage/page_manager.zig");

// Synthetic WAL recovery test ensuring skip ratio > 0 on patterned log.
// We write a sequence of Inserts to a small set of pages so that sparse index
// lets recovery skip early portion.

pub fn main() !void {
    var gpa = std.heap.page_allocator;
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    try wal.openFile("/tmp/geode_skip_test");
    // Build log: interleave page ids so later LSNs dominate.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const page: u32 = @intCast(i % 5); // only 5 pages referenced repeatedly
        const payload = try wal_mod.Wal.encodeInsert(gpa, page, 0, &.{ 1, 2, 3 });
        defer gpa.free(payload);
        _ = try wal.append(1, .Insert, payload, 0);
    }
    try wal.fsync();
    // Recover by reading the segment file directly.
    var pm = storage.PageManager.init(gpa);
    defer pm.deinit();
    const path = try std.fmt.allocPrint(gpa, "/tmp/geode_skip_test.wal.0", .{});
    defer gpa.free(path);
    _ = try wal.recover(&pm, path);
    const ratio = wal.skipRatio();
    // Expect some skipping (ratio > 0). Weak threshold 0.05.
    if (ratio <= 0.05) return error.SkipRatioTooLow;
}
