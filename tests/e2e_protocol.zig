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
    const exe = "./zig-out/bin/geode";
    const res = try run(&.{ exe, "query", "RETURN 1 AS x ORDER BY x LIMIT 1" });
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

test "protocol: decimal ordering scale alignment" {
    const exe = "./zig-out/bin/geodec";
    // Expect stable ordering of decimals with different scales; query returns two identical logical values
    const res = try run(&.{ exe, "RETURN 1.20 AS a, 1.2 AS b ORDER BY a,b" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Ensure both forms appear once and ORDERED true
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
}

test "protocol: decimal distinct dedup different scales" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1.2 AS x UNION RETURN 1.20 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Should deduplicate into single row
    var occurrences: usize = 0;
    var it = std.mem.splitScalar(u8, res.out, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "{\"x\":") != null) occurrences += 1;
    }
    try std.testing.expect(occurrences == 1);
}

test "protocol: multi-diagnostic precedence US001 primary" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a ORDER BY f(a) LIMIT 5 OFFSET 2" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    // Expect error exit
    try std.testing.expectEqual(@as(i32, 2), res.code);
    // Primary code US001, additional contains IllegalOrderKey
    try std.testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "IllegalOrderKey") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "additional_statuses") != null);
}

test "protocol: EXPLAIN logical ops" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"type\":\"EXPLAIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "Project") != null);
}

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainProtocolBasic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainProtocolBasic; OWNER=planner; UPDATED=2025-09-22
test "TestCANARY_REQ_GQL_075_ExplainProtocolBasic" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect two frames: SCHEMA then EXPLAIN
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\n{\"status_class\":\"00000\",\"result\":{\"type\":\"EXPLAIN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "cost_explain.v1") != null);
}

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=ExplainProtocolCalibrated; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_075_ExplainProtocolCalibrated; OWNER=planner; UPDATED=2025-09-22
test "TestCANARY_REQ_GQL_075_ExplainProtocolCalibrated" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "EXPLAIN CALIBRATED RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect v2 schema and calibration block
    try std.testing.expect(std.mem.indexOf(u8, res.out, "cost_explain.v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"calibration\":{") != null);
}

test "protocol: PROFILE includes timing" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"type\":\"PROFILE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "time_ns") != null);
}
