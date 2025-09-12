const std = @import("std");

// PROFILE query exercising GROUP BY to ensure HashAggBuild/HashAggEmit appear in PROFILE ops.

test "protocol PROFILE HashAgg ops" {
    const gpa = std.testing.allocator;
    const exe_path = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin/geoded", .{std.fs.cwd().realpathAlloc(gpa, ".") catch "."});
    defer gpa.free(exe_path);
    var child = std.process.Child.init(&[_][]const u8{exe_path}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    if (child.stdin) |stdin| {
        try stdin.writer().writeAll("{\"type\":\"HELLO\"}\n");
        // Use params to produce multiple input rows for grouping: a param array and UNNEST semantics simulated by evaluator (each param row becomes one env row)
        try stdin.writer().writeAll("{\"type\":\"RUN_GQL\",\"text\":\"PROFILE RETURN 1 AS k GROUP BY k\"}\n");
        try stdin.writer().writeAll("{\"type\":\"PULL\"}\n");
        try stdin.close();
    }
    var out_buf = std.ArrayList(u8).init(gpa);
    defer out_buf.deinit();
    if (child.stdout) |so| {
        var tmp: [8192]u8 = undefined;
        while (true) {
            const n = so.read(&tmp) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(tmp[0..n]);
        }
    }
    _ = child.wait() catch {};
    const out = out_buf.items;
    if (std.mem.indexOf(u8, out, "HashAggBuild") == null or std.mem.indexOf(u8, out, "HashAggEmit") == null) {
        std.debug.print("OUTPUT=\n{s}\n", .{out});
        return error.MissingHashAggOps;
    }
}
