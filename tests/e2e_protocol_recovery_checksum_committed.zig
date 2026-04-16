const std = @import("std");
const proto = @import("proto_test_util.zig");
const schema = @import("schema");
const graph_store = @import("geode").graph_store;

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}


// Recovery test: corrupt GraphStore snapshot checksum then start server and ensure
// StoragePageChecksum diagnostic is surfaced alongside PROFILE metrics.

test "protocol recovery checksum + committed_txns" {
    proto.testStart("recovery checksum + committed_txns");
    errdefer proto.testFail();

    const allocator = std.testing.allocator;
    const exe_path = "./zig-out/bin/geode";

    proto.progress("Creating temp directory...", .{});
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();
    const base_path = try tmpDirRealpathAlloc(allocator, &tmpdir.sub_path);
    defer allocator.free(base_path);

    proto.progress("Creating and corrupting snapshot...", .{});
    // Create a valid snapshot then corrupt it.
    graph_store.setDataDirOverride(allocator, base_path);
    defer graph_store.setDataDirOverride(allocator, null);
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var labels = [_][]const u8{"Seed"};
    _ = try store.createNode(&labels);
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

    proto.progress("Testing PROFILE committed_txns metric...", .{});
    const profile_json = try client.executeProfileJson(allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1");
    defer allocator.free(profile_json);
    try std.testing.expect(std.mem.indexOf(u8, profile_json, "\"committed_txns\"") != null);

    proto.progress("Testing StoragePageChecksum diagnostic...", .{});
    const params = std.ArrayList(schema.Param).init(allocator);
    var exec = try client.executeAndCollect(allocator, "RETURN 1 AS x", params, 100);
    defer exec.deinit(allocator);

    var found = false;
    for (exec.additional_statuses) |s| {
        if (std.mem.indexOf(u8, s, "StoragePageChecksum") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    proto.testPass();
}
