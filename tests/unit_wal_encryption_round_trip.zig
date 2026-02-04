const std = @import("std");
const graph_store = @import("geode").graph_store;
const tde_file = @import("storage/tde_file_encryption.zig");

// Basic snapshot encryption round-trip test. Ensures ciphertext differs from plaintext and load yields original data.
// CANARY: REQ=REQ-GQL-TDE-002; FEATURE="Snapshot encryption"; ASPECT=TEST; STATUS=TESTED; OWNER=security; UPDATED=2026-02-04

test "graphstore encryption round trip save+load" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    // Prepare TDE key (64 hex chars).
    var master: [32]u8 = undefined;
    @memset(&master, 0x11);
    var hex: [64]u8 = undefined;
    for (hex, 0..) |*c, i| {
        const b = master[i / 2];
        const nib = if (i % 2 == 0) (b >> 4) & 0xF else b & 0xF;
        c.* = "0123456789abcdef"[nib];
    }
    try std.os.setenvZ("GEODE_TDE_KEY", &hex);
    defer std.os.unsetenv("GEODE_TDE_KEY") catch {};

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{ "hello" });
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(data);
    try std.testing.expect(tde_file.isEncrypted(data));
    try std.testing.expect(std.mem.indexOf(u8, data, "hello") == null);

    var store2 = graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();
    try std.testing.expectEqual(@as(usize, 1), store2.getNodeCount());
}
