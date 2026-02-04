const std = @import("std");
const testing = std.testing;
const test_harness = @import("test_harness");
const protobuf = @import("protobuf");
const schema = @import("schema");

const ExpectedValue = union(enum) {
    Null,
    Bool: bool,
    Int: i64,
    Float: f64,
    String: []const u8,
};

const SuccessResult = struct {
    status_class: []const u8,
    flagger_findings: [][]const u8,
    columns: [][]const u8,
    rows: [][]ExpectedValue,

    fn deinit(self: *SuccessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.status_class);
        for (self.flagger_findings) |flag| allocator.free(flag);
        allocator.free(self.flagger_findings);
        for (self.columns) |col| allocator.free(col);
        allocator.free(self.columns);
        for (self.rows) |row| {
            for (row) |val| deinitExpectedValue(allocator, val);
            allocator.free(row);
        }
        allocator.free(self.rows);
    }
};

const ErrorResult = struct {
    status_class: []const u8,
    message: []const u8,
    additional_statuses: [][]const u8,

    fn deinit(self: *ErrorResult, allocator: std.mem.Allocator) void {
        allocator.free(self.status_class);
        allocator.free(self.message);
        for (self.additional_statuses) |status| allocator.free(status);
        allocator.free(self.additional_statuses);
    }
};

const DecodedResult = union(enum) {
    success: SuccessResult,
    err: ErrorResult,

    fn deinit(self: *DecodedResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*s| s.deinit(allocator),
            .err => |*e| e.deinit(allocator),
        }
    }
};

fn deinitExpectedValue(allocator: std.mem.Allocator, val: ExpectedValue) void {
    switch (val) {
        .String => |s| allocator.free(s),
        else => {},
    }
}

fn expectedFromProto(allocator: std.mem.Allocator, value: schema.Value) !ExpectedValue {
    const kind = value.kind orelse return .{ .Null = {} };
    return switch (kind) {
        .null_val => .{ .Null = {} },
        .bool_val => |b| .{ .Bool = b },
        .int_val => |i| .{ .Int = i.value },
        .double_val => |d| .{ .Float = d.value },
        .string_val => |s| .{ .String = try allocator.dupe(u8, s.value) },
        else => return error.UnsupportedValueKind,
    };
}

fn decodeResult(allocator: std.mem.Allocator, bytes: []const u8) !DecodedResult {
    var offset: usize = 0;

    var status_class: ?[]const u8 = null;
    var flagger_findings = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    errdefer flagger_findings.deinit(allocator);
    var additional_statuses = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    errdefer additional_statuses.deinit(allocator);

    var columns = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    errdefer columns.deinit(allocator);
    var rows = std.ArrayList([]ExpectedValue).initCapacity(allocator, 0) catch unreachable;
    errdefer rows.deinit(allocator);

    var error_message: ?[]const u8 = null;

    while (offset + 4 <= bytes.len) {
        const msg_len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        offset += 4;
        if (offset + msg_len > bytes.len) return error.TruncatedMessage;

        const body = bytes[offset .. offset + msg_len];
        offset += msg_len;

        var reader: std.Io.Reader = .fixed(body);
        var packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
        defer packet.deinit(allocator);

        const quic_msg = packet.quic orelse continue;
        switch (quic_msg) {
            .execute => |exec_resp| {
                if (exec_resp.status) |st| {
                    if (status_class == null) {
                        status_class = try allocator.dupe(u8, st.status_class);
                    }
                    if (flagger_findings.items.len == 0 and st.flagger_findings.items.len > 0) {
                        for (st.flagger_findings.items) |flag| {
                            try flagger_findings.append(allocator, try allocator.dupe(u8, flag));
                        }
                    }
                    if (additional_statuses.items.len == 0 and st.additional_statuses.items.len > 0) {
                        for (st.additional_statuses.items) |status| {
                            try additional_statuses.append(allocator, try allocator.dupe(u8, status));
                        }
                    }
                }

                if (exec_resp.payload) |payload| switch (payload) {
                    .schema => |schema_def| {
                        if (columns.items.len == 0) {
                            for (schema_def.columns.items) |col| {
                                try columns.append(allocator, try allocator.dupe(u8, col.name));
                            }
                        }
                    },
                    .page => |page| {
                        for (page.rows.items) |row| {
                            var vals = std.ArrayList(ExpectedValue).initCapacity(allocator, 0) catch unreachable;
                            errdefer {
                                for (vals.items) |val| deinitExpectedValue(allocator, val);
                                vals.deinit(allocator);
                            }
                            for (row.values.items) |val| {
                                try vals.append(allocator, try expectedFromProto(allocator, val));
                            }
                            try rows.append(allocator, try vals.toOwnedSlice(allocator));
                        }
                    },
                    .@"error" => |e| {
                        if (error_message == null) {
                            error_message = try allocator.dupe(u8, e.message);
                        }
                    },
                    else => {},
                };
            },
            else => {},
        }
    }

    const status = status_class orelse try allocator.dupe(u8, "");
    if (error_message) |msg| {
        return .{
            .err = .{
                .status_class = status,
                .message = msg,
                .additional_statuses = try additional_statuses.toOwnedSlice(allocator),
            },
        };
    }

    return .{
        .success = .{
            .status_class = status,
            .flagger_findings = try flagger_findings.toOwnedSlice(allocator),
            .columns = try columns.toOwnedSlice(allocator),
            .rows = try rows.toOwnedSlice(allocator),
        },
    };
}

fn expectSuccess(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected_columns: []const []const u8,
    expected_rows: []const []const ExpectedValue,
    expected_flags: []const []const u8,
) !void {
    var decoded = try decodeResult(allocator, bytes);
    defer decoded.deinit(allocator);

    switch (decoded) {
        .success => |s| {
            try testing.expectEqualStrings("00000", s.status_class);
            try testing.expectEqual(expected_flags.len, s.flagger_findings.len);
            for (expected_flags, 0..) |flag, idx| {
                try testing.expectEqualStrings(flag, s.flagger_findings[idx]);
            }

            try testing.expectEqual(expected_columns.len, s.columns.len);
            for (expected_columns, 0..) |col, idx| {
                try testing.expectEqualStrings(col, s.columns[idx]);
            }

            try testing.expectEqual(expected_rows.len, s.rows.len);
            for (expected_rows, 0..) |row, row_idx| {
                try testing.expectEqual(row.len, s.rows[row_idx].len);
                for (row, 0..) |val, col_idx| {
                    try expectValueEqual(val, s.rows[row_idx][col_idx]);
                }
            }
        },
        .err => return error.UnexpectedError,
    }
}

fn expectValueEqual(expected: ExpectedValue, actual: ExpectedValue) !void {
    switch (expected) {
        .Null => switch (actual) {
            .Null => {},
            else => return error.ValueMismatch,
        },
        .Bool => |b| switch (actual) {
            .Bool => |ab| try testing.expectEqual(b, ab),
            else => return error.ValueMismatch,
        },
        .Int => |i| switch (actual) {
            .Int => |ai| try testing.expectEqual(i, ai),
            else => return error.ValueMismatch,
        },
        .Float => |f| switch (actual) {
            .Float => |af| try testing.expectEqual(f, af),
            else => return error.ValueMismatch,
        },
        .String => |str| switch (actual) {
            .String => |as| try testing.expectEqualStrings(str, as),
            else => return error.ValueMismatch,
        },
    }
}

fn expectError(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected_status: []const u8,
    expected_message: []const u8,
    expected_additional: []const []const u8,
) !void {
    var decoded = try decodeResult(allocator, bytes);
    defer decoded.deinit(allocator);

    switch (decoded) {
        .err => |e| {
            try testing.expectEqualStrings(expected_status, e.status_class);
            try testing.expectEqualStrings(expected_message, e.message);
            try testing.expectEqual(expected_additional.len, e.additional_statuses.len);
            for (expected_additional, 0..) |status, idx| {
                try testing.expectEqualStrings(status, e.additional_statuses[idx]);
            }
        },
        .success => return error.UnexpectedSuccess,
    }
}

test "T1: SKIP recognized" {
    var allocator = testing.allocator;
    const query = "RETURN 1 AS x UNION ALL RETURN 2 AS x UNION ALL RETURN 3 AS x SKIP 1 LIMIT 1";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 2 }},
    };
    try expectSuccess(allocator, result, &.{ "x" }, &expected_rows, &.{});
}

test "T2: LIMIT without ORDER BY allowed" {
    var allocator = testing.allocator;
    const query = "RETURN 3 AS x UNION ALL RETURN 1 AS x UNION ALL RETURN 2 AS x LIMIT 2";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
        &[_]ExpectedValue{.{ .Int = 2 }},
    };
    try expectSuccess(allocator, result, &.{ "x" }, &expected_rows, &.{ "U:OrderTiebreak=LexJSON" });
}

test "T3: ORDER BY expression allowed" {
    var allocator = testing.allocator;
    const query = "RETURN 1 AS a, 2 AS b UNION ALL RETURN 2 AS a, 3 AS b ORDER BY a + b DESC";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 2 }, .{ .Int = 3 }},
        &[_]ExpectedValue{.{ .Int = 1 }, .{ .Int = 2 }},
    };
    try expectSuccess(allocator, result, &.{ "a", "b" }, &expected_rows, &.{});
}

test "T4: Per-key NULLS policy - LAST" {
    var allocator = testing.allocator;
    const query = "RETURN NULL AS x UNION ALL RETURN 1 AS x ORDER BY x NULLS LAST";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
        &[_]ExpectedValue{.{ .Null = {} }},
    };
    try expectSuccess(allocator, result, &.{ "x" }, &expected_rows, &.{});
}

test "T5: Per-key NULLS policy - mixed" {
    var allocator = testing.allocator;
    const query = "RETURN NULL AS a, 1 AS b UNION ALL RETURN 1 AS a, NULL AS b ORDER BY a NULLS FIRST, b NULLS LAST";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Null = {} }, .{ .Int = 1 }},
        &[_]ExpectedValue{.{ .Int = 1 }, .{ .Null = {} }},
    };
    try expectSuccess(allocator, result, &.{ "a", "b" }, &expected_rows, &.{});
}

test "T6: Quoted identifier as alias" {
    var allocator = testing.allocator;
    const query = "RETURN 1 AS \"order\"";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
    };
    try expectSuccess(allocator, result, &.{ "order" }, &expected_rows, &.{});
}

test "T7: UNKNOWN keyword" {
    var allocator = testing.allocator;
    const query = "RETURN NULL IS UNKNOWN AS u, 5 IS NOT UNKNOWN AS v";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Bool = true }, .{ .Bool = false }},
    };
    try expectSuccess(allocator, result, &.{ "u", "v" }, &expected_rows, &.{});
}

test "T8: // comment accepted + flagged" {
    var allocator = testing.allocator;
    const query =
        \\// head
        \\RETURN 1 AS x // tail
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
    };
    try expectSuccess(allocator, result, &.{ "x" }, &expected_rows, &.{ "GB03:DoubleSolidusComment" });
}

test "T9: ORDER BY ordinal allowed + flagged" {
    var allocator = testing.allocator;
    const query = "RETURN 1 AS a, 2 AS b ORDER BY 2";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }, .{ .Int = 2 }},
    };
    try expectSuccess(allocator, result, &.{ "a", "b" }, &expected_rows, &.{ "E:OrdinalSortKey" });
}

test "T10: -- disabled (clear diagnostic)" {
    var allocator = testing.allocator;
    const query = "RETURN 1 -- nope";
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    try expectError(allocator, result, "42000", "syntax error: double-hyphen comments disabled (GB02)", &.{});
}

test "T11: Session graph switch applies" {
    var allocator = testing.allocator;
    const query =
        \\SESSION SET PROPERTY GRAPH "G1";
        \\MATCH (n) RETURN count(*) AS c
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 3 }},
    };
    try expectSuccess(allocator, result, &.{ "c" }, &expected_rows, &.{ "I:GraphCatalog=memory" });
}

test "T12: Switch to another graph" {
    var allocator = testing.allocator;
    const query =
        \\SESSION SET PROPERTY GRAPH G2;
        \\MATCH (n) RETURN count(*) AS c
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 2 }},
    };
    try expectSuccess(allocator, result, &.{ "c" }, &expected_rows, &.{ "I:GraphCatalog=memory" });
}

test "T13: Non-existent graph auto-create (empty)" {
    var allocator = testing.allocator;
    const query =
        \\SESSION SET PROPERTY GRAPH "NewG";
        \\MATCH (n) RETURN count(*) AS c
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 0 }},
    };
    try expectSuccess(allocator, result, &.{ "c" }, &expected_rows, &.{ "I:GraphCatalog=memory" });
}

test "T14: COUNT(*) over matches" {
    var allocator = testing.allocator;
    const query =
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN count(*) AS c
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 3 }},
    };
    try expectSuccess(allocator, result, &.{ "c" }, &expected_rows, &.{});
}

test "T15: GROUP BY property with HAVING" {
    var allocator = testing.allocator;
    const query =
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN n.label AS L, count(*) AS c GROUP BY n.label HAVING c >= 2 ORDER BY L
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .String = "A" }, .{ .Int = 2 }},
    };
    try expectSuccess(allocator, result, &.{ "L", "c" }, &expected_rows, &.{});
}

test "T16: SUM/AVG with NULLs skipped" {
    var allocator = testing.allocator;
    const query =
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN sum(n.v) AS s, avg(n.v) AS a
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 3 }, .{ .Float = 1.5 }},
    };
    try expectSuccess(allocator, result, &.{ "s", "a" }, &expected_rows, &.{});
}

test "T17: COUNT(expr) vs COUNT(*)" {
    var allocator = testing.allocator;
    const query =
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN count(n.v) AS cnv, count(*) AS cstar
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 2 }, .{ .Int = 3 }},
    };
    try expectSuccess(allocator, result, &.{ "cnv", "cstar" }, &expected_rows, &.{});
}

test "T18: COUNT(DISTINCT …)" {
    var allocator = testing.allocator;
    const query =
        \\SESSION SET PROPERTY GRAPH G2;
        \\MATCH (n) RETURN count(DISTINCT n.v) AS d
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    const expected_rows = [_][]const ExpectedValue{
        &[_]ExpectedValue{.{ .Int = 1 }},
    };
    try expectSuccess(allocator, result, &.{ "d" }, &expected_rows, &.{});
}

test "T19: GROUP BY legality (error)" {
    var allocator = testing.allocator;
    const query =
        \\SESSION SET PROPERTY GRAPH G1;
        \\MATCH (n) RETURN n.label, sum(n.v)
    ;
    const result = try test_harness.runQuery(&allocator, query);
    defer allocator.free(result);

    try expectError(allocator, result, "42000", "grouping error: non-aggregated expression not in GROUP BY", &.{});
}

// Cleanup test catalog at the end
test "ZZ_cleanup" {
    // NOTE: Cannot cleanup catalog here because it was created with a different
    // test's allocator (from T1 test). Each test gets its own testing.allocator
    // instance, so trying to free memory allocated by T1's allocator causes SIGABRT.
    // The testing framework will detect and report the leaks from T1, which is acceptable.
    _ = test_harness.cleanupTestCatalog;
}
