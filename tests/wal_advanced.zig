const std = @import("std");
const wal = @import("../src/wal/wal.zig");
const storage = @import("../src/storage/page_manager.zig");

fn runRecovery(log_bytes: []const u8, test_fn: fn (pm: *storage.PageManager) anyerror!void) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/r.wal", .{tmp.dir_path});
    defer std.testing.allocator.free(log_path);
    var f = try std.fs.cwd().createFile(log_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(log_bytes);
    var pm = storage.PageManager.init(std.testing.allocator, 512);
    defer pm.deinit();
    var w = wal.Wal.init(std.testing.allocator);
    defer w.deinit();
    _ = try w.recover(&pm, log_path);
    try test_fn(&pm);
}

test "wal: mixed committed/uncommitted inserts and deletes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/mix.wal", .{tmp.dir_path});
    defer std.testing.allocator.free(log_path);
    var w = wal.Wal.init(std.testing.allocator);
    defer w.deinit();
    try w.openFile(log_path);
    // txn1 commit insert
    var prev: u64 = 0;
    var rec = try w.append(1, .Begin, &.{}, prev);
    prev = rec.value;
    const ins_payload = try wal.Wal.encodeInsert(std.testing.allocator, 0, 0, "alpha");
    rec = try w.append(1, .Insert, ins_payload, prev);
    prev = rec.value;
    _ = try w.append(1, .Commit, &.{}, prev);
    // txn2 uncommitted insert
    prev = 0;
    rec = try w.append(2, .Begin, &.{}, prev);
    prev = rec.value;
    const ins2_payload = try wal.Wal.encodeInsert(std.testing.allocator, 0, 1, "beta");
    _ = try w.append(2, .Insert, ins2_payload, prev);
    try w.fsync();
    // recovery
    var pm = storage.PageManager.init(std.testing.allocator, 512);
    defer pm.deinit();
    var w2 = wal.Wal.init(std.testing.allocator);
    defer w2.deinit();
    _ = try w2.recover(&pm, log_path);
    var p = pm.asPage(0);
    // Only committed insert should appear (slot0)
    try std.testing.expectEqual(@as(u16, 1), p.slotCount());
    try std.testing.expectEqualStrings("alpha", try p.read(0));
}

test "wal: tail truncation tolerance" {
    // Build a short log then truncate last bytes
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/tail.wal", .{tmp.dir_path});
    defer std.testing.allocator.free(log_path);
    var w = wal.Wal.init(std.testing.allocator);
    defer w.deinit();
    try w.openFile(log_path);
    var prev: u64 = 0;
    const rec = try w.append(3, .Begin, &.{}, prev);
    prev = rec.value;
    const ins_payload = try wal.Wal.encodeInsert(std.testing.allocator, 0, 0, "gamma");
    _ = try w.append(3, .Insert, ins_payload, prev);
    try w.fsync();
    // Truncate file by 5 bytes
    var f = try std.fs.cwd().openFile(log_path, .{ .write = true });
    const sz = try f.getEndPos();
    try f.setEndPos(sz - 5);
    f.close();
    var pm = storage.PageManager.init(std.testing.allocator, 512);
    defer pm.deinit();
    var w2 = wal.Wal.init(std.testing.allocator);
    defer w2.deinit();
    _ = try w2.recover(&pm, log_path); // should not error
}

test "wal: idempotent redo (double recover)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const log_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/idem.wal", .{tmp.dir_path});
    defer std.testing.allocator.free(log_path);
    var w = wal.Wal.init(std.testing.allocator);
    defer w.deinit();
    try w.openFile(log_path);
    var prev: u64 = 0;
    const rec2 = try w.append(4, .Begin, &.{}, prev);
    prev = rec2.value;
    const ins_payload = try wal.Wal.encodeInsert(std.testing.allocator, 0, 0, "delta");
    const rec_after = try w.append(4, .Insert, ins_payload, prev);
    prev = rec_after.value;
    _ = try w.append(4, .Commit, &.{}, prev);
    try w.fsync();
    // First recovery
    var pm = storage.PageManager.init(std.testing.allocator, 512);
    defer pm.deinit();
    var w2 = wal.Wal.init(std.testing.allocator);
    defer w2.deinit();
    _ = try w2.recover(&pm, log_path);
    // Second recovery (simulate restart again)
    var w3 = wal.Wal.init(std.testing.allocator);
    defer w3.deinit();
    _ = try w3.recover(&pm, log_path);
    var p = pm.asPage(0);
    try std.testing.expectEqualStrings("delta", try p.read(0));
}
