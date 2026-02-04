const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8, env_last: bool) !struct { out: []u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    if (env_last) {
        var env = try std.process.getEnvMap(testing.allocator);
        defer env.deinit();
        try env.put("GEODE_NULLS_LAST", "1");
        var it = env.iterator();
        var arr = std.ArrayList([]const u8).init(testing.allocator);
        defer arr.deinit();
        while (it.next()) |e| {
            const kv = try std.fmt.allocPrint(testing.allocator, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* });
            try arr.append(kv);
        }
        child.env_map = &arr;
        try child.spawn();
        const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 15);
        _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 15);
        const term = try child.wait();
        try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
        for (arr.items) |kv| testing.allocator.free(kv);
        return .{ .out = out };
    } else {
        try child.spawn();
        const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 15);
        _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 15);
        const term = try child.wait();
        try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
        return .{ .out = out };
    }
}

// Query returns explicit values with a NULL in between; ordering by the column should show
// policy difference. We intentionally use duplicates to keep test simple.
// RETURN sequence: 2, NULL, 1 — after ORDER BY x ascending:
// NullsFirstPolicy -> null first => [null,1,2]
// NullsLastPolicy -> null last  => [1,2,null]

fn extractRows(out: []const u8) [][]const u8 {
    var lines = std.ArrayList([]const u8).init(std.testing.allocator);
    var it = std.mem.splitScalar(u8, out, '\n');
    while (true) {
        const l = it.next() orelse break;
        if (l.len == 0) continue;
        if (std.mem.indexOf(u8, l, "\"rows\"")) |_| {
            // naive slice rows portion
            lines.append(l) catch {};
        }
    }
    return lines.toOwnedSlice() catch &.{};
}

test "protocol: ORDER BY nulls policy toggle" {
    const exe = "zig-out/bin/geode";
    // Use params to produce rows: param vector [2,null,1]
    const res_first = try run(&.{ exe, "RETURN a AS x ORDER BY x", "--json-param", "a", "[2,null,1]" }, false);
    defer testing.allocator.free(res_first.out);
    const res_last = try run(&.{ exe, "RETURN a AS x ORDER BY x", "--json-param", "a", "[2,null,1]" }, true);
    defer testing.allocator.free(res_last.out);
    // Grab bindings lines (second line in each output)
    var it1 = std.mem.splitScalar(u8, res_first.out, '\n');
    _ = it1.next();
    const line_first = it1.next() orelse return error.MissingLineFirst;
    var it2 = std.mem.splitScalar(u8, res_last.out, '\n');
    _ = it2.next();
    const line_last = it2.next() orelse return error.MissingLineLast;
    // Expect flag differences
    try testing.expect(std.mem.indexOf(u8, line_first, "NullsFirstPolicy") != null);
    try testing.expect(std.mem.indexOf(u8, line_last, "NullsLastPolicy") != null);
    // Ensure ordering difference: for simplicity check relative position of 'null'
    const pos_null_first = std.mem.indexOf(u8, line_first, "null") orelse return error.NoNullFirst;
    const pos_null_last = std.mem.indexOf(u8, line_last, "null") orelse return error.NoNullLast;
    try testing.expect(pos_null_first < pos_null_last);
}
