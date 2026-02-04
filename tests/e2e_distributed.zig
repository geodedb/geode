const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;
const proto_util = @import("proto_test_util.zig");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(allocator, 1 << 20);
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    return .{ .code = code, .out = out, .err = err };
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
