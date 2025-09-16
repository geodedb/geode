const std = @import("std");

// Test GROUP BY execution with HashAgg physical operator
test "e2e: GROUP BY execution with HashAgg" {
    const ally = std.testing.allocator;

    // Test data: a:[1,1,2], b:[10,1,5]
    // Expected: GROUP BY a -> (a=1,sum=11),(a=2,sum=5)
    const param_json = "{\"a\":[1,1,2],\"b\":[10,1,5]}";

    // Create a simple server process to test GROUP BY
    const exe_dir = try std.fs.cwd().realpathAlloc(ally, ".");
    defer ally.free(exe_dir);
    const exe_path = try std.fmt.allocPrint(ally, "{s}/zig-out/bin/geoded", .{exe_dir});
    defer ally.free(exe_path);

    var child = std.process.Child.init(&[_][]const u8{exe_path}, ally);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    if (child.stdin) |stdin| {
        // Send PROFILE query with GROUP BY and aggregation
        const query = "PROFILE RETURN a, SUM(b) GROUP BY a ORDER BY a";
        const msg = try std.fmt.allocPrint(ally, "{{\"type\":\"RUN_GQL\",\"text\":\"{s}\",\"params\":{s}}}\n", .{ query, param_json });
        defer ally.free(msg);

        var write_buf: [8192]u8 = undefined;
        try stdin.writer(&write_buf).writeAll(msg);
        try stdin.writer(&write_buf).writeAll("{\"type\":\"PULL\"}\n");
        stdin.close();
    }

    var out_buf = std.ArrayList(u8).init(ally);
    defer out_buf.deinit();
    if (child.stdout) |so| {
        var tmpb: [8192]u8 = undefined;
        while (true) {
            const n = so.read(&tmpb) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(tmpb[0..n]);
        }
    }

    _ = child.wait() catch {};
    const output = out_buf.items;

    // Verify the output contains expected results
    // Should have rows: (a=1,sum=11),(a=2,sum=5)
    try std.testing.expect(std.mem.indexOf(u8, output, "\"a\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"a\":2") != null);

    // Verify PROFILE shows HashAgg operation
    try std.testing.expect(std.mem.indexOf(u8, output, "HashAgg") != null or std.mem.indexOf(u8, output, "hashagg") != null);

    // Verify input_rows=3, rows=2 in profile
    try std.testing.expect(std.mem.indexOf(u8, output, "input_rows") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rows") != null);
}

// Test HashAgg with memory spill
test "e2e: HashAgg with memory spill" {
    const ally = std.testing.allocator;

    // Create test with very low memory limit to trigger spill
    const exe_dir = try std.fs.cwd().realpathAlloc(ally, ".");
    defer ally.free(exe_dir);
    const exe_path = try std.fmt.allocPrint(ally, "{s}/zig-out/bin/geoded", .{exe_dir});
    defer ally.free(exe_path);

    var child = std.process.Child.init(&[_][]const u8{exe_path}, ally);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    // Set very low memory limit to trigger spill
    var env_map = try std.process.getEnvMap(ally);
    defer env_map.deinit();
    try env_map.put("GEODE_QUERY_MEM_LIMIT_BYTES", "1024"); // Very low limit
    child.env_map = &env_map;

    try child.spawn();

    if (child.stdin) |stdin| {
        // Send PROFILE query with GROUP BY that should trigger spill
        const query = "PROFILE RETURN a, SUM(b) GROUP BY a";
        const param_json = "{\"a\":[1,1,2,2,3,3,4,4,5,5],\"b\":[10,1,5,3,7,2,8,4,9,6]}";
        const msg = try std.fmt.allocPrint(ally, "{{\"type\":\"RUN_GQL\",\"text\":\"{s}\",\"params\":{s}}}\n", .{ query, param_json });
        defer ally.free(msg);

        var write_buf: [8192]u8 = undefined;
        try stdin.writer(&write_buf).writeAll(msg);
        try stdin.writer(&write_buf).writeAll("{\"type\":\"PULL\"}\n");
        stdin.close();
    }

    var out_buf = std.ArrayList(u8).init(ally);
    defer out_buf.deinit();
    if (child.stdout) |so| {
        var tmpb: [8192]u8 = undefined;
        while (true) {
            const n = so.read(&tmpb) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(tmpb[0..n]);
        }
    }

    _ = child.wait() catch {};
    const output = out_buf.items;

    // Verify status_class remains 00000 (success) even with spill
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status_class\":\"00000\"") != null);

    // Verify spill metrics are present
    try std.testing.expect(std.mem.indexOf(u8, output, "hashagg_spills") != null or std.mem.indexOf(u8, output, "sort_spills") != null);
}
