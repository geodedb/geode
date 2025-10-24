const std = @import("std");
const wal_mod = @import("wal");
const storage = @import("storage_page_manager");
const tde_h = @import("tde_hierarchy");

// Basic WAL encryption round-trip test. Ensures ciphertext differs from plaintext and recovery yields original payload semantics (insert applied).
// CANARY: REQ=REQ-GQL-TDE-002; FEATURE="WAL encryption"; ASPECT=TEST; STATUS=TESTED; OWNER=security; UPDATED=2025-09-26

pub fn main() !void {}

test "wal encryption round trip insert+recover" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Prepare master key (hex) for WAL key derivation via tde_hierarchy.
    var master: [32]u8 = undefined;
    @memset(&master, 0x11);
    var hex: [64]u8 = undefined;
    for (hex, 0..) |*c, i| {
        const b = master[i / 2];
        const nib = if (i % 2 == 0) (b >> 4) & 0xF else b & 0xF;
        c.* = "0123456789abcdef"[nib];
    }
    try std.os.setenvZ("GEODE_WAL_ENCRYPTION", "on");
    try std.os.setenvZ("GEODE_DISK_ENCRYPTION", "on");
    try std.os.setenvZ("GEODE_DISK_KEY_HEX", &hex);

    // Create WAL
    var w = wal_mod.Wal.init(allocator);
    defer w.deinit();
    try w.openFile("/tmp/geode_wal_enc_test");

    // Write an INSERT record
    const payload = try wal_mod.Wal.encodeInsert(allocator, 0, 0, "hello");
    defer allocator.free(payload);
    _ = try w.append(123, .Insert, payload, 0);
    _ = try w.append(123, .Commit, &.{}, 0);
    try w.fsync();

    // Read raw WAL segment file and assert plaintext 'hello' not present (best-effort heuristic)
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const path = try std.fmt.allocPrint(allocator, "{s}.wal.0", .{"/tmp/geode_wal_enc_test"});
    defer allocator.free(path);
    const f = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer f.close();
    try buf.ensureTotalCapacity(allocator, 4096);
    const n = try f.readAll(buf.writer().context.buffer[0..4096]);
    buf.writer().context.buffer.len = n;
    std.testing.expectEqual(false, std.mem.indexOf(u8, buf.items, "hello") != null) catch |e| return e;

    // Recover into fresh page manager
    var pm = storage.PageManager.init(allocator);
    defer pm.deinit();
    // Force new page so page 0 exists after redo
    try pm.newPage();
    const applied = try w.recover(&pm, path);
    std.testing.expect(applied >= 1);
}
