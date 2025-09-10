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

test "protocol: Valid ORDER/LIMIT" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Updated expected: SCHEMA now includes flagger_findings, BINDINGS unchanged for deterministic baseline
    const expected_prefix = "{\"status_class\":\"00000\",\"result\":{\"type\":\"SCHEMA\",\"columns\":[{\"name\":\"x\",\"type\":\"INT\"}],\"flagger_findings\":[\"I:IllegalOrderKeyPolicy=ident-only\"]}}\n";
    const expected_suffix = "{\"status_class\":\"00000\",\"result\":{\"type\":\"BINDINGS\",\"ordered\":true,\"order_keys\":[\"x\"],\"rows\":[{\"x\":1}],\"flagger_findings\":[\"I:IllegalOrderKeyPolicy=ident-only\"]}}\n";
    try std.testing.expect(std.mem.eql(u8, res.out, expected_prefix ++ expected_suffix));
}

test "protocol: Invalid LIMIT+OFFSET without ORDER (US001)" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 LIMIT 10 OFFSET 5" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "16.18–16.19") != null);
}

test "protocol: Invalid ORDER BY key (IllegalOrderKey)" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a ORDER BY f(a)" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "IllegalOrderKey") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "14.10") != null);
}

test "protocol: Set operation DISTINCT (UNION)" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    // We only check that ordered=false appears; and one row
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"x\":1}") != null);
}

test "protocol: Set operation ALL (UNION ALL) duplicate preserved" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x UNION ALL RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect two occurrences of {"x":1}
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, res.out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "{\"x\":1}") != null) count += 1;
    }
    try std.testing.expect(count >= 2); // at least two rows
}

test "protocol: text format simple query" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--format", "txt" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect header then value line
    try std.testing.expect(std.mem.indexOf(u8, res.out, "x\n1\n") != null);
}

test "protocol: text format union distinct" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 1 AS x", "--format", "txt" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // DISTINCT union should yield single row: header + one value line only.
    const expected = "x\n1\n";
    try std.testing.expect(std.mem.eql(u8, res.out, expected));
}

test "protocol: text format union all duplicates" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x UNION ALL RETURN 1 AS x", "--format", "txt" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect header + two lines with 1 (order not guaranteed but duplicates preserved)
    // Count occurrences of standalone line '1'
    var count: usize = 0;
    var it2 = std.mem.splitScalar(u8, res.out, '\n');
    while (it2.next()) |line| {
        if (std.mem.eql(u8, line, "1")) count += 1;
    }
    try std.testing.expect(count >= 2);
}

test "protocol: CASE expression sanity with params" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{
        exe,
        "RETURN CASE WHEN a IS NULL THEN 'n' WHEN a THEN 't' ELSE 'f' END AS r",
        "--json-param",
        "a",
        "[null,true,false]",
    });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect rows with r:n,r:t,r:f in any order (order irrelevant)
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"r\":\"n\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"r\":\"t\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"r\":\"f\"}") != null);
}
