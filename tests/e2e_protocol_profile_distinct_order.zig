const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = Child.init(args, ally);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(ally, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
}

fn has(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// PROFILE of a DISTINCT + ORDER query should include Distinct then Sort ops with tie-break flag.
// Using synthetic duplication to make DISTINCT meaningful.
// Query: PROFILE RETURN 1 AS x, 1 AS y DISTINCT ORDER BY x LIMIT 5
// (Parser syntax: RETURN DISTINCT ... ORDER BY ... LIMIT ...)

test "protocol: PROFILE Distinct then Sort ordering and flags" {
    const exe = "./zig-out/bin/geodec";
    const q = "PROFILE RETURN DISTINCT 1 AS x, 1 AS y ORDER BY x LIMIT 5";
    const res = try run(&.{ exe, q });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(has(res.out, "\"type\":\"PROFILE\""));
    // Must contain Distinct op before Sort op
    const pos_distinct = std.mem.indexOf(u8, res.out, "\"op\":\"Distinct\"") orelse return error.NoDistinct;
    const pos_sort = std.mem.indexOf(u8, res.out, "\"op\":\"Sort\"") orelse return error.NoSort;
    try std.testing.expect(pos_distinct < pos_sort);
    // Flags: IllegalOrderKeyPolicy + OrderTiebreak + NullsFirstPolicy (ordering may vary but all present)
    try std.testing.expect(has(res.out, "I:IllegalOrderKeyPolicy=ident-only"));
    try std.testing.expect(has(res.out, "U:OrderTiebreak=LexJSON"));
    try std.testing.expect(has(res.out, "U:NullsFirstPolicy"));
}
