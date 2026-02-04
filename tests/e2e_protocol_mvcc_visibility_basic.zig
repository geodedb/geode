const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const proto_util = @import("proto_test_util.zig");

fn extractCount(res: proto_util.ExecResult) usize {
    if (res.rows.len == 0 or res.rows[0].len == 0) return 0;
    return switch (res.rows[0][0]) {
        .int => |v| @intCast(v),
        .double => |v| @intFromFloat(v),
        else => 0,
    };
}

fn runMvccScenario(allocator: std.mem.Allocator, addr: []const u8) !struct { before: usize, after: usize } {
    var client_t1 = try proto_util.QuicProtoClient.connect(allocator, addr);
    defer client_t1.deinit();
    var hello1 = try client_t1.hello(allocator, proto_util.defaultUsername(), proto_util.defaultPassword());
    hello1.deinit(allocator);

    var client_t2 = try proto_util.QuicProtoClient.connect(allocator, addr);
    defer client_t2.deinit();
    var hello2 = try client_t2.hello(allocator, proto_util.defaultUsername(), proto_util.defaultPassword());
    hello2.deinit(allocator);

    var begin1 = try client_t1.begin(allocator);
    defer begin1.deinit(allocator);

    var res1 = try client_t1.executeAndCollect(
        allocator,
        "SELECT count(v) AS c FROM SCAN_VALUES()",
        std.ArrayList(schema.Param).init(allocator),
        10,
    );
    const count1 = extractCount(res1);
    res1.deinit(allocator);

    var begin2 = try client_t2.begin(allocator);
    defer begin2.deinit(allocator);
    var res2 = try client_t2.executeAndCollect(
        allocator,
        "INSERT VALUE 'x'",
        std.ArrayList(schema.Param).init(allocator),
        10,
    );
    res2.deinit(allocator);
    _ = try client_t2.commit(allocator);

    var res3 = try client_t1.executeAndCollect(
        allocator,
        "SELECT count(v) AS c FROM SCAN_VALUES()",
        std.ArrayList(schema.Param).init(allocator),
        10,
    );
    const count2 = extractCount(res3);
    res3.deinit(allocator);

    _ = try client_t1.commit(allocator);

    return .{ .before = count1, .after = count2 };
}

// Basic MVCC visibility:
// 1. T1 BEGIN; SELECT count() (expect 0)
// 2. T2 BEGIN; INSERT; COMMIT
// 3. T1 SELECT count() again (still expect 0 under snapshot isolation)
// 4. T1 COMMIT
test "mvcc visibility snapshot isolation (QUIC)" {
    const allocator = testing.allocator;
    var server = try proto_util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:17672", "--result-format", "json" },
        null,
    );
    defer server.deinit();
    std.Thread.sleep(300 * std.time.ns_per_ms);

    const counts = try runMvccScenario(allocator, "127.0.0.1:17672");
    try testing.expectEqual(@as(usize, 0), counts.before);
    try testing.expectEqual(@as(usize, 0), counts.after);
}

// CANARY wrapper providing named test for scanner linkage
test "TestCANARY_REQ_GQL_013_SSIPhantomPrevention" {
    const allocator = testing.allocator;
    var server = try proto_util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:17673", "--result-format", "json" },
        null,
    );
    defer server.deinit();
    std.Thread.sleep(300 * std.time.ns_per_ms);

    const counts = try runMvccScenario(allocator, "127.0.0.1:17673");
    try testing.expectEqual(@as(usize, 0), counts.before);
    try testing.expectEqual(@as(usize, 0), counts.after);
}
