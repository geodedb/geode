const std = @import("std");
const wal_mod = @import("../src/wal/wal.zig");
const storage = @import("../src/storage/page_manager.zig");

// NOTE: This test simulates a page checksum failure by corrupting on-disk page image and expecting
// recovery to skip/stop without panic. Diagnostic mapping to protocol not yet integrated; placeholder assertion.

pub fn main() !void {
    var gpa = std.heap.page_allocator;
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    try wal.openFile("/tmp/geode_chk");
    // Write a few inserts referencing same page to create page file via PageManager interactions post recovery.
    var pm = storage.PageManager.init(gpa, 512);
    defer pm.deinit();
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const payload = try wal_mod.Wal.encodeInsert(gpa, 0, 0, &.{ 9, 9, 9 });
        defer gpa.free(payload);
        _ = try wal.append(1, .Insert, payload, 0);
    }
    try wal.fsync();
    // Create a fake page file and corrupt checksum
    try pm.newPage();
    var p = pm.asPage(0);
    const orig = std.mem.readInt(u32, p.buf[storage.Page.ChecksumOffset .. storage.Page.ChecksumOffset + 4], .little);
    std.mem.writeInt(u32, p.buf[storage.Page.ChecksumOffset .. storage.Page.ChecksumOffset + 4], orig ^ 0xFFFF_FFFF, .little);
    // Attempt recovery (should not panic)
    const path = try std.fmt.allocPrint(gpa, "/tmp/geode_chk.wal.0", .{});
    defer gpa.free(path);
    _ = wal.recover(&pm, path) catch |err| switch (err) {
        else => return err,
    };
}
