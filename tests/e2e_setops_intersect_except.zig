const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(gql: []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = Child.init(&.{ "./zig-out/bin/geodec", gql, "--no-quic" }, ally);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    // Read SCHEMA then BINDINGS lines
    var out_buf = std.ArrayList(u8).initCapacity(ally, 0) catch unreachable;
    defer out_buf.deinit(ally);
    var tmpb: [8192]u8 = undefined;
    // Read up to two lines
    var lines: usize = 0;
    while (lines < 2) : (lines += 1) {
        const n = child.stdout.?.read(&tmpb) catch 0;
        if (n == 0) break;
        try out_buf.appendSlice(std.testing.allocator, tmpb[0..n]);
        if (std.mem.indexOf(u8, out_buf.items, "\n") != null and lines == 0) {
            // continue to read second line
            continue;
        }
    }
    const out = try out_buf.toOwnedSlice(std.testing.allocator);
    const err = try child.stderr.?.readToEndAlloc(ally, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

test "INTERSECT DISTINCT basic" {
    const r = try run("RETURN 1 AS x INTERSECT RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"ordered\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "{\"x\":1}") != null);
}

test "EXCEPT DISTINCT basic" {
    const r = try run("RETURN 1 AS x EXCEPT RETURN 1 AS x");
    defer std.testing.allocator.free(r.out);
    defer std.testing.allocator.free(r.err);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    // Expect empty rows
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\"rows\":[]") != null);
}
