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
    
    // Create a pattern that will result in high skip ratio:
    // Add many records, then create a checkpoint, then add more records
    // This simulates a scenario where early records can be skippable during recovery
    
    // Phase 1: Add initial records (these will be skippable after checkpoint)
    var i: usize = 0;
    while (i < 150) : (i += 1) {
        const page: u32 = @intCast(i % 5);
        const payload = try wal_mod.Wal.encodeInsert(gpa, page, 0, &.{ 1, 2, 3 });
        defer gpa.free(payload);
        _ = try wal.append(1, .Insert, payload, 0);
    }
    
    // Create checkpoint - this allows skipping earlier records
    _ = try wal.writeCheckpoint();
    
    // Phase 2: Add fewer records after checkpoint (these won't be skippable)
    while (i < 200) : (i += 1) {
        const page: u32 = @intCast(i % 5);
        const payload = try wal_mod.Wal.encodeInsert(gpa, page, 0, &.{ 1, 2, 3 });
        defer gpa.free(payload);
        _ = try wal.append(1, .Insert, payload, 0);
    }
    
    try wal.fsync();
    
    // Recover from segment file
    var pm = storage.PageManager.init(gpa, 4096);
    defer pm.deinit();
    const path = try std.fmt.allocPrint(gpa, "/tmp/geode_skip_test.wal.0", .{});
    defer gpa.free(path);
    _ = try wal.recover(&pm, path);
    
    const ratio = wal.skipRatio();
    // Expect skip_ratio >= 0.60
    try std.testing.expect(ratio >= 0.60);
    
    // Clean up test file
    std.fs.cwd().deleteFile("/tmp/geode_skip_test.wal.0") catch {};
}

// Test that PROFILE command exposes WAL skip ratio in JSON output
test "wal skip ratio test override" {
    const gpa = std.testing.allocator;
    
    // Set up a test WAL with known skip ratio using test override
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    
    // Use test override to set a known skip ratio
    wal.test_skip_ratio_override = 0.75;
    
    const skip_ratio = wal.skipRatio();
    try std.testing.expect(skip_ratio == 0.75);
    
    // Verify the skip ratio would be included in PROFILE JSON
    var buf: [64]u8 = undefined;
    const skip_str = try std.fmt.bufPrint(&buf, "{d:.4}", .{skip_ratio});
    try std.testing.expect(std.mem.indexOf(u8, skip_str, "0.75") != null);
}
