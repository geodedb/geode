const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const cli_test_util = @import("cli_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "protocol: ORDER BY alias and ordinal" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
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
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN SUM(v) AS s ORDER BY s LIMIT 1", "--param", "v", "[3,2,1]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "\"ordered\":true"));
    try std.testing.expect(contains(res.out, "\"order_keys\":[\"s\"]"));
}

test "protocol: set ops LIMIT without ORDER triggers US001" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 2 AS x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "US001"));
}

test "protocol: GROUP BY illegality surfaces diagnostics" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN a, SUM(b) GROUP BY a, b" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(contains(res.err, "GroupByIllegal"));
    try std.testing.expect(contains(res.err, "14.10"));
}

test "protocol: pagination multi-page PULL final flag" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    // Build a query with three rows using params array
    const res = try run(&.{ exe, "RETURN a AS v", "--param", "a", "[1,2,3]" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    // Assert presence of all three rows in the aggregated response.
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(contains(res.out, "{\"v\":1}"));
    try std.testing.expect(contains(res.out, "{\"v\":2}"));
    try std.testing.expect(contains(res.out, "{\"v\":3}"));
}

test "protocol: pagination multi-page pull-all sequence" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "RETURN a AS v", "--param", "a", "[10,11,12]", "--page-size", "1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    const trimmed = std.mem.trim(u8, res.out, " \n\r\t");
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, trimmed, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("rows").?.array.items;
    var count10: usize = 0;
    var count11: usize = 0;
    var count12: usize = 0;
    for (rows) |row_val| {
        if (row_val.object.get("v")) |v| {
            if (v == .integer and v.integer == 10) count10 += 1;
            if (v == .integer and v.integer == 11) count11 += 1;
            if (v == .integer and v.integer == 12) count12 += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count10);
    try std.testing.expectEqual(@as(usize, 1), count11);
    try std.testing.expectEqual(@as(usize, 1), count12);
}

// CANARY: REQ=REQ-GQL-004; FEATURE="PaginationExecutionStreaming"; ASPECT=OrderedEmission; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_004_PaginationStreamingOrderedEmission; OWNER=planner; UPDATED=2026-11-14
test "TestCANARY_REQ_GQL_004_PaginationStreamingOrderedEmission" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    // Build an ordered sequence with explicit ORDER BY to ensure stable order
    const res = try run(&.{ exe, "RETURN a AS x ORDER BY x", "--param", "a", "[3,1,2]", "--page-size", "1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    const trimmed = std.mem.trim(u8, res.out, " \n\r\t");
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, trimmed, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("rows").?.array.items;
    try std.testing.expect(rows.len >= 3);
    const v1 = rows[0].object.get("x").?.integer;
    const v2 = rows[1].object.get("x").?.integer;
    const v3 = rows[2].object.get("x").?.integer;
    try std.testing.expect(v1 <= v2 and v2 <= v3);
}

test "protocol: pagination NoResult after final extra pull" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    // page-size 1 so we get multiple pulls; ensure no NoResult errors in aggregated output
    const res = try run(&.{ exe, "RETURN a AS v", "--param", "a", "[7,8]", "--page-size", "1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "NoResult") == null);
    try std.testing.expect(contains(res.out, "{\"v\":7}"));
    try std.testing.expect(contains(res.out, "{\"v\":8}"));
}

// CANARY: REQ=REQ-GQL-090; FEATURE="StreamingTelemetry"; ASPECT=PagingEvents; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_090_TelemetryPagingPull; OWNER=wire; UPDATED=2026-11-14
test "TestCANARY_REQ_GQL_090_TelemetryPagingPull" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    // Set env var to enable telemetry, then run with page_size=1 and pull-all to generate multiple pages.
    // Set minimal env vars; inherit for child process
    std.posix.setenvZ("GEODE_TELEMETRY_PAGING", "1", 1) catch {};
    std.posix.setenvZ("GEODE_CAPTURE_SERVER_STDERR", "1", 1) catch {};
    const res = try run(&.{ exe, "RETURN a AS v", "--param", "a", "[5,6]", "--page-size", "1", "--pull-all" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Telemetry is emitted to stderr as JSON lines; assert presence of TELEMETRY and event key
    try std.testing.expect(contains(res.err, "\"type\":\"TELEMETRY\""));
    try std.testing.expect(contains(res.err, "\"event\":\"PULL_PAGE\""));
    // Also should include page_size 1 and rows_emitted 1 at least once
    try std.testing.expect(contains(res.err, "\"page_size\":\"1\""));
    try std.testing.expect(contains(res.err, "\"rows_emitted\":\"1\""));
}

test "explain: query properties ordered limit offset" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x ORDER BY x LIMIT 5 OFFSET 2" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"limit\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"offset\":2") != null);
}

test "explain: union distinct properties" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
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
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "EXPLAIN RETURN 1 AS x UNION ALL RETURN 2 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // union_mode should reflect ALL and distinct flag should be absent or false (we only emit when true)
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"union_mode\":\"ALL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"distinct\":true") == null);
}

test "profile: union distinct metrics" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"setop\":{\"type\":\"UNION\",\"mode\":\"DISTINCT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"output_rows\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"hash_dedup_size\":1") != null);
}

test "profile: union all metrics" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const exe = geode_test_bin.geode_exe;
    const res = try run(&.{ exe, "PROFILE RETURN 1 AS x UNION ALL RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect at least output_rows 2 for ALL
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"mode\":\"ALL\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"output_rows\":2") != null);
}
