const std = @import("std");
const geode = @import("geode");
const wal_mod = geode.wal;
const storage = geode.storage;

// Test skipRatio() > threshold after recovery of a patterned WAL
test "wal skip ratio recovery" {
    const gpa = std.testing.allocator;
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    try wal.openFile("/tmp/geode_skip_test");
    // Write repeated inserts on few pages
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const page: u32 = @intCast(i % 5);
        const payload = try wal_mod.Wal.encodeInsert(gpa, page, 0, &.{ 1, 2, 3 });
        defer gpa.free(payload);
        _ = try wal.append(1, .Insert, payload, 0);
    }
    try wal.fsync();
    // Recover from segment file
    var pm = storage.PageManager.init(gpa);
    defer pm.deinit();
    const path = try std.fmt.allocPrint(gpa, "/tmp/geode_skip_test.wal.0", .{});
    defer gpa.free(path);
    _ = try wal.recover(&pm, path);
    const ratio = wal.skipRatio();
    // Expect skip_ratio >= 0.60
    std.testing.expect(ratio >= 0.60);
}
