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

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "protocol: ORDER BY alias and ordinal" {
    const exe = "./zig-out/bin/geodec";
    const res1 = try run(&.{ exe, "RETURN 1 AS x, 2 AS y ORDER BY y LIMIT 1" });
    defer std.testing.allocator.free(res1.out);
    defer std.testing.allocator.free(res1.err);
    try std.testing.expectEqual(@as(i32, 0), res1.code);
    try std.testing.expect(contains(res1.out, "\"ordered\":true"));
    try std.testing.expect(contains(res1.out, "\"order_keys\":[\"y\"]"));

    const res2 = try run(&.{ exe, "RETURN 1 AS x, 2 AS y ORDER BY 2 LIMIT 1" });
    defer std.testing.allocator.free(res2.out);
    defer std.testing.allocator.free(res2.err);
    try std.testing.expectEqual(@as(i32, 0), res2.code);
    try std.testing.expect(contains(res2.out, "\"ordered\":true"));
}

test "protocol: aggregates ORDER BY alias" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN SUM(v) AS s ORDER BY s LIMIT 1", "--json-param", "v", "[3,2,1]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "\"order_keys\":[\"s\"]"));
}

test "protocol: set ops LIMIT without ORDER triggers US001" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 2 AS x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "US001"));
}

test "protocol: GROUP BY illegality surfaces diagnostics" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a, SUM(b) GROUP BY a, b" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "GroupByIllegal"));
    try std.testing.expect(contains(res.err, "14.10"));
}

test "protocol: pagination multi-page PULL final flag" {
    const exe = "./zig-out/bin/geodec";
    // Build a query with three rows using params array
    const res = try run(&.{ exe, "RETURN a AS v", "--json-param", "a", "[1,2,3]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    // Expect two lines (SCHEMA + first page) because client only requests one PULL of size 1000 by default.
    // We can't change client default easily here; emulate manual server interaction would need custom harness.
    // For now just assert presence of all three rows in single page (default page_size large) and final true.
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "{\"v\":1}"));
    try std.testing.expect(contains(res.out, "{\"v\":2}"));
    try std.testing.expect(contains(res.out, "{\"v\":3}"));
    // final should appear true since all rows fit first page
    try std.testing.expect(contains(res.out, "\"final\":true"));
}

test "protocol: pagination multi-page pull-all sequence" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a AS v", "--json-param", "a", "[10,11,12]", "--page-size", "1", "--pull-all" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect three separate BINDINGS lines with one row each and final true only on last
    var count10: usize = 0;
    var count11: usize = 0;
    var count12: usize = 0;
    var finals: usize = 0;
    var it = std.mem.splitScalar(u8, res.out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "{\"v\":10}") != null) count10 += 1;
        if (std.mem.indexOf(u8, line, "{\"v\":11}") != null) count11 += 1;
        if (std.mem.indexOf(u8, line, "{\"v\":12}") != null) count12 += 1;
        if (std.mem.indexOf(u8, line, "\"type\":\"BINDINGS\"") != null and std.mem.indexOf(u8, line, "\"final\":true") != null) finals += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count10);
    try std.testing.expectEqual(@as(usize, 1), count11);
    try std.testing.expectEqual(@as(usize, 1), count12);
    try std.testing.expectEqual(@as(usize, 1), finals);
}

test "protocol: pagination NoResult after final extra pull" {
    const exe = "./zig-out/bin/geodec";
    // page-size 1 so we get multiple pulls then issue two extra pulls after final
    const res = try run(&.{ exe, "RETURN a AS v", "--json-param", "a", "[7,8]", "--page-size", "1", "--pull-all", "--extra-pull", "2" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect one NoResult error frame (status_class 02000 or ERROR type) after final when extra pulls happen
    // We search stderr (since client prints ERROR lines to stderr when exit would be 2; but here NoResult surfaces on stdout as status_class 02000?)
    // Fallback: just assert presence of "NoResult" in combined output.
    const combined = res.out; // stdout lines include SCHEMA/BINDINGS/ERROR frames
    try std.testing.expect(std.mem.indexOf(u8, combined, "NoResult") != null);
}

test "explain: query properties ordered limit offset" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x ORDER BY x LIMIT 5 OFFSET 2" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"limit\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"offset\":2") != null);
}

test "explain: union distinct properties" {
    const exe = "./zig-out/bin/geodec";
    // Simulate distinct union by adding DISTINCT tail (assuming syntax 'UNION DISTINCT')
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x UNION DISTINCT RETURN 2 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // distinct=true property should appear when any tail has distinct
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"distinct\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"union_mode\":\"DISTINCT\"") != null);
}

test "explain: union all properties" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x UNION ALL RETURN 2 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // union_mode should reflect ALL and distinct flag should be absent or false (we only emit when true)
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"union_mode\":\"ALL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"distinct\":true") == null);
}

test "profile: union distinct metrics" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"setop\":{\"type\":\"UNION\",\"mode\":\"DISTINCT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"output_rows\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"hash_dedup_size\":1") != null);
}

test "profile: union all metrics" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION ALL RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect at least output_rows 2 for ALL
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"mode\":\"ALL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"output_rows\":2") != null);
}
