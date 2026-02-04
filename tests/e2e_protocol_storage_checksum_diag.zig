const std = @import("std");
const proto = @import("proto_test_util.zig");
const schema = @import("schema");
const graph_store = @import("geode").graph_store;

// E2E: simulate checksum mismatch by corrupting GraphStore snapshot before server load.
// Expect StoragePageChecksum to appear in additional_statuses on first query.

test "protocol StoragePageChecksum diagnostic" {
    const allocator = std.testing.allocator;
    const exe_path = "./zig-out/bin/geode";
    const addr = "127.0.0.1:17681";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base_path);

    graph_store.setDataDirOverride(allocator, base_path);
    defer graph_store.setDataDirOverride(allocator, null);
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"Diag"});
    try store.saveToFile();

    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    var f = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer f.close();
    const end = try f.getEndPos();
    if (end > 4) {
        try f.seekTo(end - 4);
        var zeros: [4]u8 = .{ 0, 0, 0, 0 };
        _ = try f.write(&zeros);
        try f.sync();
    }

    var handle = try proto.spawnServer(allocator, &.{ exe_path, "serve", "--listen", addr, "--data_dir", base_path }, null);
    defer handle.deinit();
    std.Thread.sleep(200 * std.time.ns_per_ms);

    var client = try proto.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, proto.defaultUsername(), proto.defaultPassword());
    defer hello.deinit(allocator);

    var params = std.ArrayList(schema.Param).init(allocator);
    const exec = try client.executeAndCollect(allocator, "RETURN 1 AS x", params, 100);
    defer exec.deinit(allocator);

    var found = false;
    for (exec.additional_statuses) |s| {
        if (std.mem.indexOf(u8, s, "StoragePageChecksum") != null) {
            found = true;
            break;
        }
    }
    if (!found) {
        std.debug.print("additional_statuses={any}\n", .{exec.additional_statuses});
        return error.MissingChecksumDiagnostic;
    }
}
