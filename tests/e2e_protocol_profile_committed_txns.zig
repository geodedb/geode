const std = @import("std");

// E2E: ensure committed_txns metric appears after a committed transaction in PROFILE totals.

test "protocol PROFILE committed_txns" {
    const gpa = std.testing.allocator;
    const exe_path = "./zig-out/bin/geode";
    var child = std.process.Child.init(&[_][]const u8{exe_path}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    if (child.stdin) |stdin| {
        try stdin.writeAll("{\"type\":\"HELLO\"}\n");
        try stdin.writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writeAll("{\"type\":\"COMMIT\"}\n");
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"PROFILE RETURN 1 AS x ORDER BY x LIMIT 1\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":100}\n");
        // Close stdin so server exits its loop, then null to avoid double-close.
        stdin.close();
        child.stdin = null;
    }
    var out_buf: std.ArrayList(u8) = .{};
    defer out_buf.deinit(gpa);
    if (child.stdout) |so| {
        var tmp: [16384]u8 = undefined;
        while (true) {
            const n = so.read(&tmp) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(gpa, tmp[0..n]);
        }
    }
    _ = child.wait() catch {};
    const out = out_buf.items;
    // Extract PROFILE frame (last JSON line containing 'profile_version') then parse committed_txns numeric value.
    var lines_it = std.mem.splitScalar(u8, out, '\n');
    var committed_val: ?usize = null;
    while (lines_it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"profile_version\"") != null) {
            // Find committed_txns key
            if (std.mem.indexOf(u8, line, "\"committed_txns\":")) |pos| {
                var i: usize = pos + "\"committed_txns\":".len;
                // skip non-digits
                while (i < line.len and (line[i] < '0' or line[i] > '9')) i += 1;
                const start = i;
                while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
                if (start < i) {
                    const num_slice = line[start..i];
                    const parsed = std.fmt.parseInt(usize, num_slice, 10) catch 0;
                    committed_val = parsed;
                }
            }
        }
    }
    if (committed_val == null or committed_val.? < 1) {
        std.debug.print("OUTPUT=\n{s}\n", .{out});
        return error.MissingCommittedMetric;
    }
}
