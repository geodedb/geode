const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const schema = @import("schema");

// Zig 0.16 compat: std.Thread.sleep removed; nanosleep directly.
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

const ExpectedValue = union(enum) {
    Null,
    Bool: bool,
    Int: i64,
    Float: f64,
    String: []const u8,
};

fn deinitExpectedValue(allocator: std.mem.Allocator, val: ExpectedValue) void {
    switch (val) {
        .String => |s| allocator.free(s),
        else => {},
    }
}

// ENG-3921 follow-up: each test spawns its own server, and the G1/G2 session
// seed helpers (`createTestGraphG1`) clear only RESIDENT nodes — a fresh server
// lazily hydrates the previous test's persisted seed afterwards, so a shared
// per-process data dir accumulates G1 rows across tests (count 3 → 6 → 9 …).
// Give every spawn its own data dir; these tests are single-server and need no
// cross-spawn durability.
var run_query_serial = std.atomic.Value(u32).init(0);

fn runQuery(allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    const addr = "127.0.0.1:3181";
    const serial = run_query_serial.fetchAdd(1, .monotonic);
    const pid = if (comptime @import("builtin").os.tag == .linux)
        @as(i64, std.os.linux.getpid())
    else
        @as(i64, std.c.getpid());
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-gqlconf-{d}-{d}", .{ pid, serial });
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir }, null);
    defer server.deinit();

    // Wait for server to be ready with retries
    var attempts: u32 = 0;
    const max_attempts: u32 = 50; // 5 seconds total
    var client: util.QuicProtoClient = undefined;
    while (attempts < max_attempts) : (attempts += 1) {
        client = util.QuicProtoClient.connect(allocator, addr) catch |err| {
            if (err == error.HandshakeError or err == error.ConnectionFailed) {
                compat_sleep(100 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        break;
    } else {
        return error.HandshakeError; // Timeout waiting for server
    }
    defer client.deinit();

    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    const params = util.emptyParams();
    return client.executeAndCollect(allocator, query, params, 1024);
}

/// runQuery variant that binds request-level query parameters over the wire.
/// Used to pin FOR..IN parameter-bound-list execution end-to-end
/// (geode#for-in-param): the FOR collection env must resolve `$param` to the
/// bound list, not Null.
fn runQueryParams(allocator: std.mem.Allocator, query: []const u8, params: std.ArrayList(schema.Param)) !util.ExecResult {
    const addr = "127.0.0.1:3181";
    const serial = run_query_serial.fetchAdd(1, .monotonic);
    const pid = if (comptime @import("builtin").os.tag == .linux)
        @as(i64, std.os.linux.getpid())
    else
        @as(i64, std.c.getpid());
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-gqlconf-{d}-{d}", .{ pid, serial });
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir }, null);
    defer server.deinit();

    var attempts: u32 = 0;
    const max_attempts: u32 = 50;
    var client: util.QuicProtoClient = undefined;
    while (attempts < max_attempts) : (attempts += 1) {
        client = util.QuicProtoClient.connect(allocator, addr) catch |err| {
            if (err == error.HandshakeError or err == error.ConnectionFailed) {
                compat_sleep(100 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        break;
    } else {
        return error.HandshakeError;
    }
    defer client.deinit();

    var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    hello.deinit(allocator);

    return client.executeAndCollect(allocator, query, params, 1024);
}

fn expectValueEqual(expected: ExpectedValue, actual: util.TestValue) !void {
    switch (expected) {
        .Null => try testing.expect(actual == .null),
        .Bool => |b| {
            try testing.expect(actual == .bool);
            try testing.expectEqual(b, actual.bool);
        },
        .Int => |i| {
            try testing.expect(actual == .int);
            try testing.expectEqual(i, actual.int);
        },
        .Float => |f| {
            try testing.expect(actual == .double);
            try testing.expect(std.math.approxEqAbs(f64, f, actual.double, 1e-6));
        },
        .String => |s| {
            try testing.expect(actual == .string);
            try testing.expectEqualStrings(s, actual.string);
        },
    }
}

fn expectFlagsContain(actual: [][]const u8, expected: []const []const u8) !void {
    for (expected) |flag| {
        var found = false;
        for (actual) |cand| {
            if (std.mem.eql(u8, cand, flag)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

fn expectSuccess(
    allocator: std.mem.Allocator,
    result: *const util.ExecResult,
    expected_columns: []const []const u8,
    expected_rows: []const []const ExpectedValue,
    expected_flags: []const []const u8,
) !void {
    _ = allocator;
    try testing.expect(result.error_code == null);
    try testing.expectEqualStrings("00000", result.status_class);

    try testing.expectEqual(expected_columns.len, result.columns.len);
    for (expected_columns, 0..) |col, i| {
        try testing.expectEqualStrings(col, result.columns[i]);
    }

    try testing.expectEqual(expected_rows.len, result.rows.len);
    for (expected_rows, 0..) |exp_row, i| {
        const act_row = result.rows[i];
        try testing.expectEqual(exp_row.len, act_row.len);
        for (exp_row, 0..) |exp_val, j| {
            try expectValueEqual(exp_val, act_row[j]);
        }
    }

    try expectFlagsContain(result.flagger_findings, expected_flags);
}

fn expectError(
    result: *const util.ExecResult,
    expected_code: []const u8,
    expected_message: []const u8,
    expected_additional: []const []const u8,
) !void {
    try testing.expect(result.error_code != null);
    try testing.expectEqualStrings(expected_code, result.error_code.?);
    try testing.expect(std.mem.indexOf(u8, result.error_message orelse "", expected_message) != null);
    try expectFlagsContain(result.additional_statuses, expected_additional);
}

// CANARY: REQ=REQ-LIB-MIGRATION-PROTOBUF-001; FEATURE="Protobuf Wire Protocol"; ASPECT=WireProtocolCompatibility; STATUS=TESTED; OWNER=protocol; UPDATED=2026-02-03

test "T1: SKIP recognized" {
    const allocator = testing.allocator;
    const query = "RETURN 1 AS x UNION ALL RETURN 2 AS x UNION ALL RETURN 3 AS x SKIP 1 LIMIT 1";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 2 }},
    };
    try expectSuccess(allocator, &result, &.{"x"}, &expected_rows, &.{});
}

test "T2: LIMIT without ORDER BY allowed" {
    const allocator = testing.allocator;
    const query = "RETURN 3 AS x UNION ALL RETURN 1 AS x UNION ALL RETURN 2 AS x LIMIT 2";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
        &[_]ExpectedValue{.{ .Int = 2 }},
    };
    try expectSuccess(allocator, &result, &.{"x"}, &expected_rows, &.{"U:OrderTiebreak=LexJSON"});
}

test "T3: ORDER BY expression allowed" {
    const allocator = testing.allocator;
    const query = "RETURN 1 AS a, 2 AS b UNION ALL RETURN 2 AS a, 3 AS b ORDER BY a + b DESC";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{ .{ .Int = 2 }, .{ .Int = 3 } },
        &[_]ExpectedValue{ .{ .Int = 1 }, .{ .Int = 2 } },
    };
    try expectSuccess(allocator, &result, &.{ "a", "b" }, &expected_rows, &.{});
}

test "T4: Per-key NULLS policy - LAST" {
    const allocator = testing.allocator;
    const query = "RETURN NULL AS x UNION ALL RETURN 1 AS x ORDER BY x NULLS LAST";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
        &[_]ExpectedValue{.{ .Null = {} }},
    };
    try expectSuccess(allocator, &result, &.{"x"}, &expected_rows, &.{});
}

test "T5: Per-key NULLS policy - mixed" {
    const allocator = testing.allocator;
    const query = "RETURN NULL AS a, 1 AS b UNION ALL RETURN 1 AS a, NULL AS b ORDER BY a NULLS FIRST, b NULLS LAST";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{ .{ .Null = {} }, .{ .Int = 1 } },
        &[_]ExpectedValue{ .{ .Int = 1 }, .{ .Null = {} } },
    };
    try expectSuccess(allocator, &result, &.{ "a", "b" }, &expected_rows, &.{});
}

test "T6: Quoted identifier as alias" {
    const allocator = testing.allocator;
    const query = "RETURN 1 AS \"order\"";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
    };
    try expectSuccess(allocator, &result, &.{"order"}, &expected_rows, &.{});
}

test "T7: UNKNOWN keyword" {
    const allocator = testing.allocator;
    const query = "RETURN NULL IS UNKNOWN AS u, 5 IS NOT UNKNOWN AS v";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{ .{ .Bool = true }, .{ .Bool = false } },
    };
    try expectSuccess(allocator, &result, &.{ "u", "v" }, &expected_rows, &.{});
}

test "T8: // comment accepted + flagged" {
    const allocator = testing.allocator;
    const query =
        "// head\n" ++
        "RETURN 1 AS x // tail";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
    };
    try expectSuccess(allocator, &result, &.{"x"}, &expected_rows, &.{"GB03:DoubleSolidusComment"});
}

test "T9: ORDER BY ordinal allowed + flagged" {
    const allocator = testing.allocator;
    const query = "RETURN 1 AS a, 2 AS b ORDER BY 2";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{ .{ .Int = 1 }, .{ .Int = 2 } },
    };
    try expectSuccess(allocator, &result, &.{ "a", "b" }, &expected_rows, &.{"E:OrdinalSortKey"});
}

test "T10: -- disabled (clear diagnostic)" {
    const allocator = testing.allocator;
    const query = "RETURN 1 -- nope";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    try expectError(&result, "42000", "syntax error: double-hyphen comments disabled (GB02)", &.{});
}

test "T11: Session graph switch applies" {
    const allocator = testing.allocator;
    const query =
        "SESSION SET PROPERTY GRAPH \"G1\";\n" ++
        "MATCH (n) RETURN count(*) AS c";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 3 }},
    };
    try expectSuccess(allocator, &result, &.{"c"}, &expected_rows, &.{});
}

test "T12: Switch to another graph" {
    const allocator = testing.allocator;
    const query =
        "SESSION SET PROPERTY GRAPH G2;\n" ++
        "MATCH (n) RETURN count(*) AS c";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 2 }},
    };
    try expectSuccess(allocator, &result, &.{"c"}, &expected_rows, &.{});
}

test "T13: Non-existent graph auto-create (empty)" {
    const allocator = testing.allocator;
    const query =
        "SESSION SET PROPERTY GRAPH \"NewG\";\n" ++
        "MATCH (n) RETURN count(*) AS c";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 0 }},
    };
    try expectSuccess(allocator, &result, &.{"c"}, &expected_rows, &.{});
}

test "T14: COUNT(*) over matches" {
    const allocator = testing.allocator;
    const query =
        "SESSION SET PROPERTY GRAPH G1;\n" ++
        "MATCH (n) RETURN count(*) AS c";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 3 }},
    };
    try expectSuccess(allocator, &result, &.{"c"}, &expected_rows, &.{});
}

test "T15: GROUP BY property with HAVING" {
    const allocator = testing.allocator;
    const query =
        "SESSION SET PROPERTY GRAPH G1;\n" ++
        "MATCH (n) RETURN n.label AS L, count(*) AS c GROUP BY n.label HAVING c >= 2 ORDER BY L";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{ .{ .String = "A" }, .{ .Int = 2 } },
    };
    try expectSuccess(allocator, &result, &.{ "L", "c" }, &expected_rows, &.{});
}

test "T16: SUM/AVG with NULLs skipped" {
    const allocator = testing.allocator;
    const query =
        "SESSION SET PROPERTY GRAPH G1;\n" ++
        "MATCH (n) RETURN sum(n.v) AS s, avg(n.v) AS a";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{ .{ .Int = 3 }, .{ .Float = 1.5 } },
    };
    try expectSuccess(allocator, &result, &.{ "s", "a" }, &expected_rows, &.{});
}

test "T17: COUNT(expr) vs COUNT(*)" {
    const allocator = testing.allocator;
    const query =
        "SESSION SET PROPERTY GRAPH G1;\n" ++
        "MATCH (n) RETURN count(n.v) AS cnv, count(*) AS cstar";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{ .{ .Int = 2 }, .{ .Int = 3 } },
    };
    try expectSuccess(allocator, &result, &.{ "cnv", "cstar" }, &expected_rows, &.{});
}

test "T18: COUNT(DISTINCT …)" {
    const allocator = testing.allocator;
    const query =
        "SESSION SET PROPERTY GRAPH G2;\n" ++
        "MATCH (n) RETURN count(DISTINCT n.v) AS d";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
    };
    try expectSuccess(allocator, &result, &.{"d"}, &expected_rows, &.{});
}

test "T19: GROUP BY legality (error)" {
    const allocator = testing.allocator;
    const query =
        "SESSION SET PROPERTY GRAPH G1;\n" ++
        "MATCH (n) RETURN n.label, sum(n.v)";
    var result = try runQuery(allocator, query);
    defer result.deinit(allocator);

    try expectError(&result, "42000", "grouping error: non-aggregated expression not in GROUP BY", &.{});
}

test "T20: FOR over a parameter-bound list iterates every element" {
    // geode#for-in-param: `FOR n IN $nums RETURN n` must iterate the wire-bound
    // list. The bug collapses this to a single NULL iteration because the FOR
    // collection env (statement_handlers.zig:832-836) drops request params.
    const allocator = testing.allocator;

    // Build the $nums list param inline (util.makeIntListParam has a pre-existing
    // Zig 0.16 `append` signature bug and is not touched here). Ownership of the
    // param contents transfers to the wire path (executeAndCollect frees them),
    // mirroring tests/e2e_protocol_groupby_hashagg.zig — so no manual deinit here.
    var list_values = std.ArrayList(schema.Value).empty;
    for ([_]i64{ 10, 20, 30 }) |v| {
        try list_values.append(allocator, .{ .kind = .{ .int_val = .{ .value = v, .kind = .INT } } });
    }
    var params = util.emptyParams();
    try params.append(allocator, .{
        .name = try allocator.dupe(u8, "nums"),
        .value = .{ .kind = .{ .list_val = .{ .values = list_values } } },
    });

    var result = try runQueryParams(allocator, "FOR n IN $nums RETURN n AS v", params);
    defer result.deinit(allocator);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 10 }},
        &[_]ExpectedValue{.{ .Int = 20 }},
        &[_]ExpectedValue{.{ .Int = 30 }},
    };
    try expectSuccess(allocator, &result, &.{"v"}, &expected_rows, &.{});
}

// Cleanup placeholder to keep ordering stable in reports
test "ZZ_cleanup" {
    try testing.expect(true);
}
