const std = @import("std");
const proto = @import("proto_test_util.zig");
const schema = @import("schema");
const graph_store = @import("geode").graph_store;

// Recovery test: corrupt GraphStore snapshot checksum then start server and ensure
// StoragePageChecksum diagnostic is surfaced alongside PROFILE metrics.

test "protocol recovery checksum + committed_txns" {
    const allocator = std.testing.allocator;
    const exe_path = "./zig-out/bin/geode";
    const addr = "127.0.0.1:17680";

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const base_path = try tmpdir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base_path);

    // Create a valid snapshot then corrupt it.
    graph_store.setDataDirOverride(allocator, base_path);
    defer graph_store.setDataDirOverride(allocator, null);
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Seed"});
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();
    const end = try file.getEndPos();
    if (end > 1) {
        try file.seekTo(end - 1);
        var buf: [1]u8 = .{0x00};
        _ = try file.write(&buf);
        try file.sync();
    }

    // Start server with corrupted data dir.
    var handle = try proto.spawnServer(allocator, &.{ exe_path, "serve", "--listen", addr, "--data_dir", base_path }, null);
    defer handle.deinit();
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var client = try proto.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, proto.defaultUsername(), proto.defaultPassword());
    defer hello.deinit(allocator);

    const profile_json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1");
    defer allocator.free(profile_json);
    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"committed_txns\"") != null);

    const params = std.ArrayList(schema.Param).init(allocator);
    const exec = try client.executeAndCollect(allocator, "RETURN 1 AS x", params, 100);
    defer exec.deinit(allocator);

    var found = false;
    for (exec.additional_statuses) |s| {
        if (std.mem.indexOf(u8, s, "StoragePageChecksum") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
