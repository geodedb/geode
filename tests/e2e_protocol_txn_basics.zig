const std = @import("std");

// E2E: exercise BEGIN, nested BEGIN error, COMMIT, ROLLBACK paths.

test "protocol txn basics" {
    const gpa = std.testing.allocator;
    const exe_path = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin/geoded", .{std.fs.cwd().realpathAlloc(gpa, ".") catch "."});
    defer gpa.free(exe_path);
    var child = std.process.Child.init(&[_][]const u8{exe_path}, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    if (child.stdin) |stdin| {
        try stdin.writer().writeAll("{\"type\":\"HELLO\"}\n");
        try stdin.writer().writeAll("{\"type\":\"BEGIN\"}\n");
        try stdin.writer().writeAll("{\"type\":\"BEGIN\"}\n"); // should error
        try stdin.writer().writeAll("{\"type\":\"COMMIT\"}\n"); // commit active txn
        try stdin.writer().writeAll("{\"type\":\"ROLLBACK\"}\n"); // no active txn -> error
        try stdin.close();
    }
    var out_buf = std.ArrayList(u8).init(gpa);
    defer out_buf.deinit();
    if (child.stdout) |so| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = so.read(&tmp) catch 0;
            if (n == 0) break;
            try out_buf.appendSlice(tmp[0..n]);
        }
    }
    _ = child.wait() catch {};
    const out = out_buf.items;
    if (std.mem.indexOf(u8, out, "already in transaction") == null) return error.MissingNestedBeginError;
    if (std.mem.indexOf(u8, out, "no active transaction") == null) return error.MissingNoActiveTxnError;
}
