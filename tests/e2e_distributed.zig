const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const proto_util = @import("proto_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const res = try cli_test_util.run(args);
    return .{ .code = res.code, .out = res.out, .err = res.err };
}

fn assertSimpleQueryOk(out: []const u8) !void {
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, trimmed, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("00000", obj.get("status_class").?.string);
    try std.testing.expect(obj.get("ordered").?.bool);
    try std.testing.expect(obj.get("order_keys").?.array.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, obj.get("order_keys").?.array.items[0].string, "x"));
    try std.testing.expect(obj.get("rows").?.array.items.len == 1);
    const row = obj.get("rows").?.array.items[0].object;
    try std.testing.expect(row.get("x").?.integer == 1);
}

test "distributed: single-node raft enabled simple query" {
    const exe = "./zig-out/bin/geode";
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--server", server.getAddr(), "--insecure", "--dist-enable-raft" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try assertSimpleQueryOk(res.out);
}

test "distributed: 2pc enabled simple query" {
    const exe = "./zig-out/bin/geode";
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--server", server.getAddr(), "--insecure", "--dist-enable-2pc" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try assertSimpleQueryOk(res.out);
}

test "distributed: sharding flag no-op simple query" {
    const exe = "./zig-out/bin/geode";
    var server = try proto_util.spawnServerRandom(std.testing.allocator, proto_util.TestEnv.standard());
    defer server.deinit();
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--server", server.getAddr(), "--insecure", "--dist-enable-sharding" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try assertSimpleQueryOk(res.out);
}
