const std = @import("std");
const wal_mod = @import("wal");

// Unit test: exercise Wal.skipRatio() after invoking recover() on a synthetic WAL
// with a mix of records enabling skip optimization (page_lsn_index min_lsn > some earlier records).
// We construct a temp wal segment manually by appending several inserts and a checkpoint.
// Then run recover() to populate last_skip_count / last_total_records and assert ratio bounds.

test "wal skipRatio basic" {
    const gpa = std.testing.allocator;
    // Create temp directory for WAL
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_path);

    var w = try wal_mod.Wal.init(gpa, base_path, 64 * 1024); // small segment
    defer w.deinit();

    // Append a few records across different pages to populate page_lsn_index on recovery.
    // For simplicity we directly append inserts with small payloads encoding page/slot via encodeInsert.
    const payload1 = try wal_mod.Wal.encodeInsert(gpa, 0, 0, "A");
    defer gpa.free(payload1);
    _ = try w.append(1, .Insert, payload1, 0);
    const payload2 = try wal_mod.Wal.encodeInsert(gpa, 1, 0, "B");
    defer gpa.free(payload2);
    _ = try w.append(1, .Insert, payload2, 1);
    const payload3 = try wal_mod.Wal.encodeInsert(gpa, 2, 0, "C");
    defer gpa.free(payload3);
    _ = try w.append(1, .Insert, payload3, 2);
    _ = try w.writeCheckpoint();
    try w.fsync();

    // Close and re-open to force recover path.
    w.deinit();
    var w2 = try wal_mod.Wal.init(gpa, base_path, 64 * 1024);
    defer w2.deinit();

    // Provide a dummy PageManager for recovery.
    var pm = try @import("storage_page_manager").PageManager.init(gpa, base_path, .{});
    defer pm.deinit();
    _ = try w2.recover(&pm, base_path);

    const ratio = w2.skipRatio();
    // Ratio should be between 0 and 1.
    try std.testing.expect(ratio >= 0.0 and ratio <= 1.0);
}
