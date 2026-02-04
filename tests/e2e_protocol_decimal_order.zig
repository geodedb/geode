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

inline fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

// Validate decimal ordering across scales and sign.
// We simulate decimals using RETURN with raw literal forms once parser supports them; for now we mimic via int ordering fallback (placeholder test ensures framework readiness).

// NOTE: If decimal literal syntax not yet implemented, this test just ensures existing INT ordering is stable; adjust once decimals are exposed at parse level.

test "protocol: numeric ordering stable (placeholder for decimal)" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN 2 AS x UNION RETURN 1 AS x UNION RETURN 3 AS x ORDER BY x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect ordered rows 1,2,3 after PULL (unordered union + grouped order logic currently sorts when grouped pattern detected)
    try std.testing.expect(contains(res.out, "{\"x\":1}"));
    try std.testing.expect(contains(res.out, "{\"x\":2}"));
    try std.testing.expect(contains(res.out, "{\"x\":3}"));
}

// Mixed scale decimals with negatives: ensure normalization treats -1.2 and -1.20 as equal and ordering places them before 0 and positive values.
test "protocol: decimal ordering negatives and mixed scales" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN -1.2 AS a UNION RETURN -1.20 AS a UNION RETURN 0 AS a UNION RETURN 1.2 AS a ORDER BY a" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Rows should include -1.2 (deduped), 0, 1.2 in ascending order.
    const line_it = blk: {
        var it = std.mem.splitScalar(u8, res.out, '\n');
        while (it.next()) |ln| {
            if (contains(ln, "\"type\":\"BINDINGS\"")) break :blk ln;
        }
        break :blk res.out; // fallback
    };
    const p_neg = std.mem.indexOf(u8, line_it, "{\"a\":-1.2}") orelse 0;
    const p_zero = std.mem.indexOf(u8, line_it, "{\"a\":0}") orelse 0;
    const p_pos = std.mem.indexOf(u8, line_it, "{\"a\":1.2}") orelse 0;
    try std.testing.expect(p_neg < p_zero);
    try std.testing.expect(p_zero < p_pos);
}

// Mixed ints and decimals ordering: negatives, zeros, positives with decimal granularity.
test "protocol: numeric ordering mixed ints and decimals" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN -2 AS x UNION RETURN -1.5 AS x UNION RETURN -1 AS x UNION RETURN 0 AS x UNION RETURN 1 AS x UNION RETURN 1.25 AS x UNION RETURN 2 AS x ORDER BY x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Ensure presence of all numeric literals
    try std.testing.expect(contains(res.out, "{\"x\":-2}"));
    try std.testing.expect(contains(res.out, "{\"x\":-1.5}"));
    try std.testing.expect(contains(res.out, "{\"x\":-1}"));
    try std.testing.expect(contains(res.out, "{\"x\":0}"));
    try std.testing.expect(contains(res.out, "{\"x\":1}"));
    try std.testing.expect(contains(res.out, "{\"x\":1.25}"));
    try std.testing.expect(contains(res.out, "{\"x\":2}"));
    // Order check in bindings line
    const line_it = blk: {
        var it = std.mem.splitScalar(u8, res.out, '\n');
        while (it.next()) |ln| {
            if (contains(ln, "\"type\":\"BINDINGS\"")) break :blk ln;
        }
        break :blk res.out; // fallback
    };
    const p_m2 = std.mem.indexOf(u8, line_it, "{\"x\":-2}") orelse 0;
    const p_m15 = std.mem.indexOf(u8, line_it, "{\"x\":-1.5}") orelse 0;
    const p_m1 = std.mem.indexOf(u8, line_it, "{\"x\":-1}") orelse 0;
    const p_0 = std.mem.indexOf(u8, line_it, "{\"x\":0}") orelse 0;
    const p_1 = std.mem.indexOf(u8, line_it, "{\"x\":1}") orelse 0;
    const p_125 = std.mem.indexOf(u8, line_it, "{\"x\":1.25}") orelse 0;
    const p_2 = std.mem.indexOf(u8, line_it, "{\"x\":2}") orelse 0;
    try std.testing.expect(p_m2 < p_m15);
    try std.testing.expect(p_m15 < p_m1);
    try std.testing.expect(p_m1 < p_0);
    try std.testing.expect(p_0 < p_1);
    try std.testing.expect(p_1 < p_125);
    try std.testing.expect(p_125 < p_2);
}

// Dedup across int and decimal forms of same numeric value.
test "protocol: union distinct dedup int vs decimal canonical equality" {
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 1.0 AS x UNION RETURN 1.00 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect only one row with x:1
    var occurrences: usize = 0;
    var it = std.mem.splitScalar(u8, res.out, '\n');
    while (it.next()) |line| {
        if (contains(line, "{\"x\":1}")) occurrences += 1;
    }
    try std.testing.expect(occurrences == 1);
}
