const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var child = Child.init(args, allocator);
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

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Ensure AggregateBuild shows non-zero input_rows when params provide multiple rows.
test "protocol: PROFILE GROUP BY shows agg_rows_in from params" {
    const exe = "./zig-out/bin/geodec";
    // Provide param array a with three values; query groups by a returning a and COUNT(*)
    const res = try run(&.{ exe, "PROFILE RETURN a, COUNT(*) AS c GROUP BY a", "--json-param", "a", "[1,1,2]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"type\":\"PROFILE\""));
    try std.testing.expect(contains(res.out, "AggregateBuild"));
    // Expect input_rows >= 3 (param rows) and rows (groups) == 2 (values 1 & 2) in JSON substring.
    try std.testing.expect(contains(res.out, "\"AggregateBuild\""));
    try std.testing.expect(contains(res.out, "\"input_rows\":3"));
    // Group count 2 (distinct values) may appear in AggregateEmit rows field; assert rows":2 occurs
    try std.testing.expect(contains(res.out, "\"rows\":2"));
}
