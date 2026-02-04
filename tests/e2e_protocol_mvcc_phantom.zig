const std = @import("std");
const testing = std.testing;
const proto = @import("proto_test_util");
const schema = @import("schema");

fn countFromResult(res: *const proto.ExecResult) !usize {
    if (res.rows.len == 0 or res.rows[0].len == 0) return error.MissingCount;
    return switch (res.rows[0][0]) {
        .int => |v| @intCast(v),
        .double => |v| @intCast(@as(i64, @intFromFloat(v))),
        else => error.InvalidCountType,
    };
}

fn makeTempDir(allocator: std.mem.Allocator, tag: []const u8) ![]const u8 {
    const dir = try std.fmt.allocPrint(allocator, "/tmp/geode_mvcc_phantom_{s}_{d}", .{ tag, std.time.nanoTimestamp() });
    try std.fs.cwd().makePath(dir);
    return dir;
}

fn runPhantomTest() !void {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:15610";

    const data_dir = try makeTempDir(allocator, "si");
    defer {
        std.fs.cwd().deleteTree(data_dir) catch {};
        allocator.free(data_dir);
    }
    const env_kv = try std.fmt.allocPrint(allocator, "GEODE_DATA_DIR={s}", .{data_dir});
    defer allocator.free(env_kv);

    var server = try proto.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr },
        &.{env_kv},
    );
    defer server.deinit();

    std.time.sleep(200 * std.time.ns_per_ms);

    var client1 = try proto.QuicProtoClient.connect(allocator, addr);
    defer client1.deinit();
    const hello1 = try client1.hello(allocator, proto.defaultUsername(), proto.defaultPassword());
    defer hello1.deinit(allocator);
    const begin1 = try client1.begin(allocator);
    defer begin1.deinit(allocator);

    const params1 = std.ArrayList(schema.Param).init(allocator);
    const res1 = try client1.executeAndCollect(allocator, "SELECT count(v) AS c FROM SCAN_VALUES()", params1, 0);
    defer res1.deinit(allocator);
    const count1 = try countFromResult(&res1);

    var client2 = try proto.QuicProtoClient.connect(allocator, addr);
    defer client2.deinit();
    const hello2 = try client2.hello(allocator, proto.defaultUsername(), proto.defaultPassword());
    defer hello2.deinit(allocator);
    const begin2 = try client2.begin(allocator);
    defer begin2.deinit(allocator);

    const params2 = std.ArrayList(schema.Param).init(allocator);
    const res_insert = try client2.executeAndCollect(allocator, "INSERT VALUE 'x'", params2, 0);
    defer res_insert.deinit(allocator);
    _ = try client2.commit(allocator);

    const params3 = std.ArrayList(schema.Param).init(allocator);
    const res2 = try client1.executeAndCollect(allocator, "SELECT count(v) AS c FROM SCAN_VALUES()", params3, 0);
    defer res2.deinit(allocator);
    const count2 = try countFromResult(&res2);
    _ = try client1.rollback(allocator);

    try testing.expectEqual(count1, count2);
    try testing.expect(count1 == 0);
}

// E2E: snapshot isolation should prevent seeing inserted rows mid-transaction (no phantoms)
test "protocol MVCC phantom reads prevented under SI" {
    try runPhantomTest();
}

// CANARY wrapper providing named test for scanner linkage
test "TestCANARY_REQ_GQL_013_SSIPhantomPrevention" {
    try runPhantomTest();
}
