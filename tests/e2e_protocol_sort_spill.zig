const std = @import("std");

// E2E: ensure sort_spills metric is set when memory threshold exceeded

test "protocol PROFILE sort_spill" {
    const gpa = std.testing.allocator;
    std.os.setEnv("GEODE_SPILL_THRESHOLD_BYTES", "1", true) catch unreachable;
    const exe = "./zig-out/bin/geode";
    var child = std.process.Child.init(&[_][]const u8{exe}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    if (child.stdin) |stdin| {
        try stdin.writeAll("{\"type\":\"HELLO\"}\n");
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"PROFILE RETURN 1 AS x ORDER BY x\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":100}\n");
        stdin.close();
        child.stdin = null;
    }
    var out_buf = std.ArrayList(u8).initCapacity(gpa, 0);
    defer out_buf.deinit(gpa);
    if (child.stdout) |so| {
        var tmp: [8192]u8 = undefined;
        while (true) {
            const n = so.read(&tmp) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(gpa, tmp[0..n]);
        }
    }
    _ = child.wait() catch {};
    const out = out_buf.items;
    var lines_it = std.mem.splitScalar(u8, out, '\n');
    var found: bool = false;
    while (lines_it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"sort_spills\":") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
