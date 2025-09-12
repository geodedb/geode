const std = @import("std");
const wal_mod = @import("wal");
const storage_pm = @import("storage_page_manager");

// Unit: Write WAL with one insert then recover into fresh PageManager and assert page 0 slotCount > 0

test "wal recovery applies insert" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(base_path);

    var w = try wal_mod.Wal.init(gpa, base_path, 64 * 1024);
    const payload = try wal_mod.Wal.encodeInsert(gpa, 0, 0, "X");
    defer gpa.free(payload);
    _ = try w.append(1, .Insert, payload, 0);
    _ = try w.writeCheckpoint();
    try w.fsync();
    w.deinit();

    var w2 = try wal_mod.Wal.init(gpa, base_path, 64 * 1024);
    defer w2.deinit();
    var pm = try storage_pm.PageManager.init(gpa, base_path, .{});
    defer pm.deinit();
    const applied = try w2.recover(&pm, base_path);
    try std.testing.expect(applied >= 1);
    // Ensure page exists and has at least one slot with data.
    if (pm.pages.items.len == 0) return error.MissingPage;
    const p = pm.asPage(0);
    try std.testing.expect(p.slotCount() > 0);
}
