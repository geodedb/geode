const std = @import("std");
const graph_store = @import("../src/graph_store.zig");
const tde_file = @import("../src/storage/tde_file_encryption.zig");


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn set_env() void {
    std.process.setEnvVar("GEODE_TDE_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff") catch {};
}

test "graph_store encryption: persist encrypted and decrypts on load" {
    set_env();
    defer std.process.unsetEnvVar("GEODE_TDE_KEY") catch {};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const base = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(base);

    graph_store.setDataDirOverride(allocator, base);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
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
    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();
    const prop = store2.getNodeProperty(node_id, "payload") orelse return error.MissingProperty;
    switch (prop) {
        .String => |val| try std.testing.expectEqualStrings("secret", val),
        else => return error.UnexpectedPropertyType,
    }
}
