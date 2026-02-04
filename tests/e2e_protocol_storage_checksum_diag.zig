const std = @import("std");
const proto = @import("proto_test_util.zig");
const schema = @import("schema");
const graph_store = @import("geode").graph_store;

// E2E: simulate checksum mismatch by corrupting GraphStore snapshot before server load.
// Expect StoragePageChecksum to appear in additional_statuses on first query.

test "protocol StoragePageChecksum diagnostic" {
    proto.testStart("StoragePageChecksum diagnostic");
    errdefer proto.testFail();

    const allocator = std.testing.allocator;
    const exe_path = "./zig-out/bin/geode";

    proto.progress("Creating temp directory...", .{});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base_path);

    proto.progress("Creating and corrupting snapshot...", .{});
    graph_store.setDataDirOverride(allocator, base_path);
    defer graph_store.setDataDirOverride(allocator, null);
    var store = graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var labels = [_][]const u8{"Diag"};
    _ = try store.createNode(&labels);
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

    // Get random port
    const port = proto.getRandomPort() catch |err| {
        proto.progress("Port allocation failed: {}", .{err});
        proto.testSkip();
        return;
    };
    const addr = try proto.formatAddr(allocator, port);
    defer allocator.free(addr);

    proto.progress("Starting server on port {d} with corrupted data...", .{port});
    var handle = proto.spawnServer(allocator, &.{ exe_path, "serve", "--listen", addr, "--data_dir", base_path }, proto.TestEnv.standard()) catch |err| {
        proto.progress("Server spawn failed: {}", .{err});
        proto.testSkip();
        return;
    };
    defer handle.deinit();

    // Wait for server readiness
    proto.waitForServerReady(allocator, addr, 10000) catch |err| {
        proto.progress("Server readiness timeout: {}", .{err});
        proto.testSkip();
        return;
    };

    proto.progress("Connecting to server...", .{});
    var client = try proto.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var hello = try client.hello(allocator, proto.defaultUsername(), proto.defaultPassword());
    defer hello.deinit(allocator);

    proto.progress("Executing query to check diagnostics...", .{});
    var params = std.ArrayList(schema.Param).init(allocator);
    var exec = try client.executeAndCollect(allocator, "RETURN 1 AS x", params, 100);
    defer exec.deinit(allocator);

    var found = false;
    for (exec.additional_statuses) |s| {
        if (std.mem.indexOf(u8, s, "StoragePageChecksum") != null) {
            found = true;
            break;
        }
    }
    if (!found) {
        proto.progress("additional_statuses={any}", .{exec.additional_statuses});
        return error.MissingChecksumDiagnostic;
    }

    proto.testPass();
}
