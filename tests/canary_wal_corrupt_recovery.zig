const std = @import("std");
const walmod = @import("../src/wal/wal.zig");
const storage = @import("storage_page_manager");
// TestCANARY_REQ_GQL_028_CorruptPageRecovery
// Crafts a WAL with two valid records then a corrupted checksum record; recovery should stop before applying corrupted third.

fn writeRaw(path: []const u8, data: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer f.close();
    try f.writeAll(data);
}

test "TestCANARY_REQ_GQL_028_CorruptPageRecovery" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();
    var w = walmod.Wal.init(ally);
    defer w.deinit();
    try w.openFile("/tmp/geode_corrupt_test");
    // Append two inserts (valid)
    var prev: u64 = 0;
    const payload1 = try walmod.Wal.encodeInsert(ally, 0, 0, "abc");
    defer ally.free(payload1);
    _ = try w.append(1, .Insert, payload1, prev);
    prev = w.next_lsn - 1;
    const payload2 = try walmod.Wal.encodeInsert(ally, 0, 1, "def");
    defer ally.free(payload2);
    _ = try w.append(1, .Insert, payload2, prev);
    prev = w.next_lsn - 1;
    try w.fsync();
    // Manually craft a corrupt third record by writing header with bad checksum
    var f = w.file.?; // open segment 0
    try f.seekTo(0);
    const sz = try f.getEndPos();
    try f.seekTo(sz);
    var header: [1 + 8 + 4 + 8 + 8 + 4]u8 = undefined;
    // Minimal bogus Delete record with mismatched checksum
    header[0] = @intFromEnum(walmod.RecordType.Delete);
    std.mem.writeInt(u64, header[1..9], 1, .little); // txn
    std.mem.writeInt(u32, header[9..13], 0, .little); // no payload
    std.mem.writeInt(u64, header[13..21], w.next_lsn, .little);
    std.mem.writeInt(u64, header[21..29], prev, .little);
    std.mem.writeInt(u32, header[29..33], 0xDEADBEEF, .little); // wrong checksum
    try f.writeAll(header[0..]);
    // sentinel to look like complete record but checksum invalid
    var sentinel: [4]u8 = undefined;
    std.mem.writeInt(u32, sentinel[0..4], 0xEC0DDBAD, .little);
    try f.writeAll(&sentinel);
    try f.sync();

    // Recover into fresh page manager
    var pm = storage.PageManager.init(ally);
    defer pm.deinit();
    var w2 = walmod.Wal.init(ally);
    defer w2.deinit();
    // Directly call recover on the original wal file path
    const path = try std.fmt.allocPrint(ally, "/tmp/geode_corrupt_test.wal.0", .{});
    defer ally.free(path);
    const applied = try w2.recover(&pm, path);
    // Expect only the two valid inserts applied; third corrupted skipped.
    try std.testing.expectEqual(@as(usize, 2), applied);
}
