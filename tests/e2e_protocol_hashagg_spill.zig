const std = @import("std");

// E2E: ensure hashagg_spills metric is set when spill threshold exceeded

test "protocol PROFILE hashagg_spill" {
    const gpa = std.testing.allocator;
    // Force very low spill threshold
    std.os.setEnv("GEODE_SPILL_THRESHOLD_BYTES", "1", true) catch unreachable;

    const exe_path = "./zig-out/bin/geoded";
    var child = std.process.Child.init(&[_][]const u8{exe_path});
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    if (child.stdin) |stdin| {
        try stdin.writeAll("{\"type\":\"HELLO\"}\n");
        try stdin.writeAll("{\"type\":\"RUN_GQL\",\"text\":\"PROFILE RETURN 1 AS x GROUP BY x\"}\n");
        try stdin.writeAll("{\"type\":\"PULL\",\"request_id\":1,\"page_size\":100}\n");
        stdin.close();
        child.stdin = null;
    }
    var out_buf = std.ArrayList(u8).initCapacity(gpa, 0);
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
    var lines_it = std.mem.splitScalar(u8, out, '\n');
    var spill_val: ?usize = null;
    while (lines_it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"profile_version\"") != null) {
            if (std.mem.indexOf(u8, line, "\"hashagg_spills\":") != null) {
                const key = "\"hashagg_spills\":";
                const pos = std.mem.indexOf(u8, line, key) orelse continue;
                var i: usize = pos + key.len;
                while (i < line.len and (line[i] < '0' or line[i] > '9')) i += 1;
                const start = i;
                while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
                if (start < i) {
                    const num_slice = line[start..i];
                    const parsed = std.fmt.parseInt(usize, num_slice, 10) catch 0;
                    spill_val = parsed;
                }
            }
        }
    }
    try std.testing.expect(spill_val != null and spill_val.? >= 1);
}
