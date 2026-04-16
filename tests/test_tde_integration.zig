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


// Basic integration tests for file-level TDE with GraphStore snapshots.
// Scenarios:
// 1) TDE disabled: file not encrypted (no TDE magic header).
// 2) TDE enabled (GEODE_TDE_KEY set): file encrypted, load succeeds.
// CANARY: REQ=REQ-GQL-TDE-001; FEATURE="TDE baseline"; ASPECT=TEST; STATUS=TESTED; TEST=tests/test_tde_integration.zig:1; OWNER=security; UPDATED=2026-02-04

pub fn main() !void {}

test "tde: graphstore plaintext when disabled" {
    std.process.unsetEnvVar("GEODE_TDE_KEY") catch {};

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const allocator = std.testing.allocator;
    const tmp_path = try tmpDirRealpathAlloc(allocator, &tmp_dir.sub_path);
    defer allocator.free(tmp_path);
    graph_store.setDataDirOverride(allocator, tmp_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Person"});
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(raw);

    try std.testing.expect(!tde_file.isEncrypted(raw));
    try std.testing.expect(raw.len >= 8);
    try std.testing.expect(std.mem.eql(u8, raw[0..8], "GEODGST1"));
}

test "tde: graphstore encrypt/decrypt round trip" {
    const key_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.process.setEnvVar("GEODE_TDE_KEY", key_hex);
    defer std.process.unsetEnvVar("GEODE_TDE_KEY") catch {};

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const allocator = std.testing.allocator;
    const tmp_path = try tmpDirRealpathAlloc(allocator, &tmp_dir.sub_path);
    defer allocator.free(tmp_path);
    graph_store.setDataDirOverride(allocator, tmp_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Encrypted"});
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 2 * 1024 * 1024);
    defer allocator.free(raw);

    try std.testing.expect(tde_file.isEncrypted(raw));
    try std.testing.expect(raw.len >= tde_file.MAGIC.len);
    try std.testing.expect(std.mem.eql(u8, raw[0..tde_file.MAGIC.len], &tde_file.MAGIC));

    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();
    try std.testing.expect(store2.getNodeCount() == 1);
}
