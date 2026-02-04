const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

test "protocol: rollback then subsequent query works" {
    const exe = "./zig-out/bin/geode";
    // First run with BEGIN + ROLLBACK
    const res1 = try run(&.{ exe, "RETURN 1 AS x", "--begin", "--rollback" });
    defer std.testing.allocator.free(res1.out);
    defer std.testing.allocator.free(res1.err);
    try std.testing.expectEqual(@as(i32, 0), res1.code);
    // Now a fresh query without txn flags should still succeed
    const res2 = try run(&.{ exe, "RETURN 2 AS y ORDER BY y LIMIT 1" });
    defer std.testing.allocator.free(res2.out);
    defer std.testing.allocator.free(res2.err);
    try std.testing.expectEqual(@as(i32, 0), res2.code);
    try std.testing.expect(std.mem.indexOf(u8, res2.out, "\"ordered\":true") != null);
}
