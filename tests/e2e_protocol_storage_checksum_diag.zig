const std = @import("std");

// E2E: simulate checksum mismatch by creating a page file then corrupting checksum before server load.
// Server started with GEODE_CHECKSUM_TEST_PATH env so it attempts load and emits StoragePageChecksum diagnostic on first RUN_GQL.

test "protocol StoragePageChecksum diagnostic" {
    const gpa = std.testing.allocator;
    // Prepare temp dir
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Create minimal page_0.bin with invalid checksum (all zeros) so verifyChecksum fails.
    const page_path = try std.fmt.allocPrint(gpa, "{s}/page_0.bin", .{tmp.path});
    defer gpa.free(page_path);
    var f = try std.fs.cwd().createFile(page_path, .{ .truncate = true });
    defer f.close();
    var buf: [4096]u8 = .{0} ** 4096; // zeroed page -> checksum mismatch (expected adler32 over zeroed with zeroed field is not prewritten stored value pattern)
    // Write without computing valid checksum so verification fails.
    try f.writeAll(&buf);
    try f.sync();

    const exe_dir = try std.fs.cwd().realpathAlloc(gpa, ".");
    defer gpa.free(exe_dir);
    const exe_path = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin/geode", .{exe_dir});
    defer gpa.free(exe_path);

    var child = std.process.Child.init(&[_][]const u8{exe_path}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // Inject env to trigger load attempt
    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();
    try env_map.put("GEODE_CHECKSUM_TEST_PATH", tmp.path);
    child.env_map = &env_map;
    try child.spawn();

    if (child.stdin) |stdin| {
        try stdin.writer().writeAll("{\"type\":\"RUN_GQL\",\"text\":\"RETURN 1 AS x\"}\n");
        try stdin.writer().writeAll("{\"type\":\"PULL\"}\n");
        try stdin.close();
    }

    var out_buf = std.ArrayList(u8).init(gpa);
    defer out_buf.deinit();
    if (child.stdout) |so| {
        var tmpb: [4096]u8 = undefined;
        while (true) {
            const n = so.read(&tmpb) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(tmpb[0..n]);
        }
    }
    _ = child.wait() catch {};
    const out = out_buf.items;
    if (std.mem.indexOf(u8, out, "StoragePageChecksum") == null) {
        std.debug.print("OUTPUT=\n{s}\n", .{out});
        return error.MissingChecksumDiagnostic;
    }
}
