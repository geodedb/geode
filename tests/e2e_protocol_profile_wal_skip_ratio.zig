const std = @import("std");

// E2E invoking geoded with --test-wal-skip-ratio to ensure PROFILE frame includes wal_skip_ratio field.
// We run a trivial PROFILE query and scan stdout for the expected ratio string.

pub fn main() !void {}

test "protocol PROFILE wal_skip_ratio override" {
    const gpa = std.testing.allocator;
    // Build server executable path
    const exe_path = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin/geoded", .{std.fs.cwd().realpathAlloc(gpa, ".") catch "."});
    defer gpa.free(exe_path);
    // Spawn server process and feed one PROFILE query line; capture output.
    var child = std.process.Child.init(&[_][]const u8{ exe_path, "--test-wal-skip-ratio", "0.7500" }, gpa);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    // Write HELLO then RUN_GQL PROFILE RETURN 1 AS x ORDER BY x LIMIT 1 and a PULL
    if (child.stdin) |stdin| {
        try stdin.writer().writeAll("{\"type\":\"HELLO\"}\n");
        try stdin.writer().writeAll("{\"type\":\"RUN_GQL\",\"text\":\"PROFILE RETURN 1 AS x ORDER BY x LIMIT 1\"}\n");
        try stdin.writer().writeAll("{\"type\":\"PULL\"}\n");
        try stdin.close();
    }
    var stdout_buf = std.ArrayList(u8).init(gpa);
    defer stdout_buf.deinit();
    if (child.stdout) |stdout| {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = stdout.read(&tmp) catch 0;
            if (n == 0) break;
            try stdout_buf.appendSlice(tmp[0..n]);
        }
    }
    _ = child.wait() catch {};
    const out_str = stdout_buf.items;
    // Expect wal_skip_ratio and alias skip_ratio to appear with 0.7500
    if (std.mem.indexOf(u8, out_str, "\"wal_skip_ratio\":0.7500") == null or std.mem.indexOf(u8, out_str, "\"skip_ratio\":0.7500") == null) {
        std.debug.print("OUTPUT=\n{s}\n", .{out_str});
        return error.MissingWalSkipRatio;
    }
}
