//! SONNY-6548 reproductions, fixed by SONNY-6562 (the full regression is
//! tests/test_sonny6562_wire_metadata.zig): metadata the server sent with a
//! result contradicted the result.
//!
//! 1. Exact numeric typed FLOAT, and a column typed from its first value.
//!    ISO/IEC 39075:2024 21.2 SR: an <exact numeric literal> such as `1.25`
//!    has an exact numeric declared type (scale = digits after the period);
//!    14.2 SR: a UNION's columns have the combined type of both operands
//!    (22.18, "General combination of value types"). The SCHEMA frame types
//!    `RETURN 1.25 AS a` FLOAT (src/eval/type_helpers.zig getTypeName:
//!    `.Decimal => "FLOAT"`), and types a column from the first non-null of
//!    its first rows (src/server/proto_util.zig inferColumnType), so
//!    `RETURN 2 AS a UNION RETURN 1.25 AS a` declares INTEGER for a column
//!    holding 1.25.
//! 2. ORDER BY after FOR loses its metadata. `FOR a IN [2,1,3] RETURN a
//!    ORDER BY a DESC` returns 3,2,1 with `ordered:false, order_keys:[]`;
//!    `MATCH ... ORDER BY` reports `ordered:true`. analyzeStatement
//!    (src/query/query_traits.zig) sets the traits for .Query and .Union and
//!    has no .For arm.
//! 3. PROFILE reports a spill that did not happen. With a spill threshold
//!    below the version-1 payload's (synthetic) peak, the payload carries
//!    `spill_reason:"threshold"` while every spill counter is 0
//!    (src/server/profile_payload.zig buildProfilePayload sets the reason
//!    from `peak > threshold` and never counts a spill).
//!    docs/BINARY_PROTOCOL.md: `spill_reason` is "present only if any spill
//!    counter > 0".
const std = @import("std");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const profile_util = @import("profile_test_util.zig");

fn connect(a: std.mem.Allocator, server: *util.ServerHandle) !util.QuicProtoClient {
    var client = try util.QuicProtoClient.connect(a, server.getAddr());
    errdefer client.deinit();
    var hello = try client.hello(a, util.defaultUsername(), util.defaultPassword());
    hello.deinit(a);
    return client;
}

test "SONNY-6548: an exact numeric column is typed as an exact numeric, also when a UNION mixes it with an integer" {
    const a = testing.allocator;
    var server = try util.spawnServerRandom(a, util.TestEnv.standard());
    defer server.deinit();
    var client = try connect(a, &server);
    defer client.deinit();

    for ([_][]const u8{ "RETURN 1.25 AS a", "RETURN 2 AS a UNION RETURN 1.25 AS a", "RETURN 1.25 AS a UNION RETURN 2 AS a" }) |q| {
        var res = try client.executeAndCollect(a, q, util.emptyParams(), 100);
        defer res.deinit(a);
        try testing.expect(res.error_code == null);
        try testing.expectEqual(@as(usize, 1), res.column_types.len);
        const t = res.column_types[0];
        const exact = std.mem.eql(u8, t, "DECIMAL") or std.mem.eql(u8, t, "NUMERIC");
        if (!exact) std.debug.print("{s}: column type {s}\n", .{ q, t });
        try testing.expect(exact);
    }
}

test "SONNY-6548: ORDER BY after FOR reports the result ordered by its keys" {
    const a = testing.allocator;
    var server = try util.spawnServerRandom(a, util.TestEnv.standard());
    defer server.deinit();
    var client = try connect(a, &server);
    defer client.deinit();

    var res = try client.executeAndCollect(a, "FOR a IN [2, 1, 3] RETURN a ORDER BY a DESC", util.emptyParams(), 100);
    defer res.deinit(a);
    try testing.expect(res.error_code == null);
    // The rows are ordered (control).
    try testing.expectEqual(@as(usize, 3), res.rows.len);
    try testing.expectEqual(@as(i64, 3), res.rows[0][0].int);
    try testing.expectEqual(@as(i64, 1), res.rows[2][0].int);
    // The metadata says so.
    if (!res.ordered) std.debug.print("FOR ... ORDER BY a DESC: ordered={} order_keys.len={d}\n", .{ res.ordered, res.order_keys.len });
    try testing.expect(res.ordered);
    try testing.expectEqual(@as(usize, 1), res.order_keys.len);
    try testing.expectEqualStrings("a", res.order_keys[0]);
}

test "SONNY-6548: PROFILE reports spill_reason only when a spill counter is nonzero" {
    const a = testing.allocator;
    // A data change takes the version-1 payload; its synthetic peak (64 bytes
    // per operator) exceeds a 1-byte threshold.
    const json = try profile_util.runProfile(a, "PROFILE CREATE (:Sonny6548Spill {k: 1})", &.{"GEODE_SPILL_THRESHOLD_BYTES=1"});
    defer a.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const spills = parsed.value.object.get("spills") orelse return error.MissingSpills;
    var counted: i64 = 0;
    for ([_][]const u8{ "sort_spills", "distinct_spills", "union_spills" }) |k| {
        if (spills.object.get(k)) |v| counted += v.integer;
    }
    const reason = spills.object.get("spill_reason");
    if (reason != null and counted == 0) std.debug.print("spills: {s}\n", .{json});
    try testing.expect(reason == null or counted > 0);
}
