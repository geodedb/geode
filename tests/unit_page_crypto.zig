const std = @import("std");
const graph_store = @import("../src/graph_store.zig");
const tde_file = @import("../src/storage/tde_file_encryption.zig");

fn set_env() void {
    std.process.setEnvVar("GEODE_TDE_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff") catch {};
}

test "graph_store encryption: persist encrypted and decrypts on load" {
    set_env();
    defer std.process.unsetEnvVar("GEODE_TDE_KEY") catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    graph_store.setDataDirOverride(allocator, base);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    const node_id = try store.createNode(&.{"Secret"});
    try store.setNodeProperty(node_id, "payload", .{ .String = "secret" });
    try store.saveToFile();

    // Raw on disk should be encrypted (TDE magic prefix)
    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(raw);
    try std.testing.expect(tde_file.isEncrypted(raw));
    try std.testing.expect(std.mem.indexOf(u8, raw, "GEODGST1") == null);

    // Load via API (which decrypts) and verify content
    var store2 = graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();
    const prop = store2.getNodeProperty(node_id, "payload") orelse return error.MissingProperty;
    switch (prop) {
        .String => |val| try std.testing.expectEqualStrings("secret", val),
        else => return error.UnexpectedPropertyType,
    }
}
