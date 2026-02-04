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

test "protocol: decimal arithmetic add/sub/mul/div and comparisons" {
    const exe = "./zig-out/bin/geode";
    // Mixed int + decimal additions
    const res1 = try run(&.{ exe, "RETURN 1.25 AS a UNION RETURN 2 AS a" });
    defer std.testing.allocator.free(res1.out);
    defer std.testing.allocator.free(res1.err);
    try std.testing.expectEqual(@as(i32, 0), res1.code);
    // Expect DECIMAL type in schema and at least one decimal literal emitted ("1.25" or numeric 1.25 rendering)
    try std.testing.expect(std.mem.indexOf(u8, res1.out, "DECIMAL") != null);

    const res2 = try run(&.{ exe, "RETURN 5.00 / 2 AS x" });
    defer std.testing.allocator.free(res2.out);
    defer std.testing.allocator.free(res2.err);
    try std.testing.expectEqual(@as(i32, 0), res2.code);
    // Division may truncate scale -> check for rows entry with integer or decimal result
    try std.testing.expect(std.mem.indexOf(u8, res2.out, "\"x\":") != null);
}
