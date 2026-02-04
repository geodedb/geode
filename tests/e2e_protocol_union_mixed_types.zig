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

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Ensure numeric 1 and string "1" are NOT collapsed by canonical numeric dedup in UNION DISTINCT.
test "protocol: UNION DISTINCT keeps numeric vs string distinct" {
    const exe = "./zig-out/bin/geode";
    const q = "RETURN 1 AS x UNION RETURN \"1\" AS x";
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect two rows: one numeric, one string. Rows order may vary, so check both forms appear.
    try std.testing.expect(contains(res.out, "{\"x\":1}"));
    try std.testing.expect(contains(res.out, "{\"x\":\"1\"}"));
    // And ensure not collapsed into single row: look for closing array with only one element pattern
    try std.testing.expect(!contains(res.out, "\"rows\":[{\"x\":1}]"));
}
