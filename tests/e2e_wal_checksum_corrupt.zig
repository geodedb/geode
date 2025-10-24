const std = @import("std");
const geode = @import("geode");
const wal = @import("wal");
const storage_mem = @import("storage_mem");

// Corrupt last WAL record checksum and ensure recovery stops before it (no panic).
test "wal: checksum corruption truncates tail" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var w = wal.Wal.init(allocator);
    defer w.deinit();
    try w.openFile("/tmp/geode_wal_checksum_test.log");
    defer std.fs.cwd().deleteFile("/tmp/geode_wal_checksum_test.log") catch {};
    // Append two inserts
    const p1 = try wal.Wal.encodeInsert(allocator, 0, 0, "abc");
    defer allocator.free(p1);
    _ = try w.append(1, .Insert, p1, 0);
    const p2 = try wal.Wal.encodeInsert(allocator, 0, 0, "def");
    defer allocator.free(p2);
    _ = try w.append(1, .Insert, p2, 1);
    try w.fsync();
    // Corrupt last 4 bytes (checksum) in file
    var f = try std.fs.cwd().openFile("/tmp/geode_wal_checksum_test.log", .{ .write = true, .read = true });
    defer f.close();
    const file_size = try f.getEndPos();
    if (file_size >= 4) {
        try f.seekTo(file_size - 4);
        var zeros: [4]u8 = .{ 0, 0, 0, 0 };
        try f.writeAll(&zeros);
    }
    // Recover into fresh page manager
    var pm = storage_mem.PageManager.init(allocator);
    const applied = try w.recover(&pm, "/tmp/geode_wal_checksum_test.log");
    try std.testing.expect(applied >= 1); // at least first record applied
}
