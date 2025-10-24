const std = @import("std");

test "e2e: transaction serialization failure mapping to status_class 25000" {
    const allocator = std.testing.allocator;
    const exe_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(exe_dir);
    const exe_path = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/geoded", .{exe_dir});
    defer allocator.free(exe_path);

    var child = std.process.Child.init(&[_][]const u8{exe_path}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var out_buf = std.ArrayList(u8).init(allocator);
    defer out_buf.deinit();

    if (child.stdin) |stdin| {
        // Trigger conflict by issuing BEGIN twice to induce TxnState or serialize failure path
        try stdin.writer().writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writer().writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.close();
    }

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
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status_class\":\"25000\"") != null);
}
