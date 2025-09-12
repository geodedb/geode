const std = @import("std");
const wal = @import("../src/wal/wal.zig");
const storage = @import("../src/storage/page_manager.zig");

test "wal recovery applies only committed txns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.wal", .{tmp.dir_path});
    defer std.testing.allocator.free(log_path);

    // Phase 1: create WAL, write two txns (one committed, one not), then drop state.
    var w = wal.Wal.init(std.testing.allocator);
    defer w.deinit();
    try w.openFile(log_path);

    const TXN_COMMIT: u64 = 1;
    const TXN_UNCOMMIT: u64 = 2;

    var prev1: u64 = 0;
    prev1 = (try w.append(TXN_COMMIT, .Begin, &.{}, prev1)).value;
    const ins1_payload = try wal.Wal.encodeInsert(std.testing.allocator, 0, 0, "alpha");
    defer std.testing.allocator.free(ins1_payload);
    prev1 = (try w.append(TXN_COMMIT, .Insert, ins1_payload, prev1)).value;
    _ = try w.append(TXN_COMMIT, .Commit, &.{}, prev1);

    _ = try w.append(TXN_UNCOMMIT, .Begin, &.{});
    var prev2: u64 = 0;
    prev2 = (try w.append(TXN_UNCOMMIT, .Begin, &.{}, prev2)).value;
    const ins2_payload = try wal.Wal.encodeInsert(std.testing.allocator, 0, 1, "beta");
    defer std.testing.allocator.free(ins2_payload);
    prev2 = (try w.append(TXN_UNCOMMIT, .Insert, ins2_payload, prev2)).value;
    // no commit record for TXN_UNCOMMIT
    try w.fsync();

    // Simulate crash: new WAL instance + empty page manager, run recovery.
    var pm = storage.PageManager.init(std.testing.allocator, 512);
    defer pm.deinit();
    var w2 = wal.Wal.init(std.testing.allocator);
    defer w2.deinit();
    const applied = try w2.recover(&pm, log_path);
    try std.testing.expectEqual(@as(usize, 1), applied);

    // Read back first page, ensure exactly one record with payload 'alpha'.
    // We directly inspect slotCount and record bytes as convenience.
    var p = pm.asPage(0);
    try std.testing.expectEqual(@as(u16, 1), p.slotCount());
    const rec = try p.read(0);
    try std.testing.expectEqualStrings("alpha", rec);
}
