const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn getServerAddr(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "GEODE_TEST_SERVER") catch return error.SkipZigTest;
}

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
    const expected_prefix = "{\"status_class\":\"00000\",\"result\":{\"type\":\"SCHEMA\",\"columns\":[{\"name\":\"x\",\"type\":\"INT\"}],\"flagger_findings\":[\"I:IllegalOrderKeyPolicy=ident-only\"]}}\n";
    const expected_suffix = "{\"status_class\":\"00000\",\"result\":{\"type\":\"BINDINGS\",\"ordered\":true,\"order_keys\":[\"x\"],\"rows\":[{\"x\":1}],\"flagger_findings\":[\"I:IllegalOrderKeyPolicy=ident-only\"]}}\n";
    try std.testing.expect(std.mem.eql(u8, out, expected_prefix ++ expected_suffix));
}

test "distributed: single-node raft enabled simple query" {
    const exe = "./zig-out/bin/geode";
    const allocator = std.testing.allocator;
    const server = try getServerAddr(allocator);
    defer allocator.free(server);
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--server", server", "--insecure", "--dist-enable-raft" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try assertSimpleQueryOk(res.out);
}

test "distributed: 2pc enabled simple query" {
    const exe = "./zig-out/bin/geode";
    const allocator = std.testing.allocator;
    const server = try getServerAddr(allocator);
    defer allocator.free(server);
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--server", server", "--insecure", "--dist-enable-2pc" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try assertSimpleQueryOk(res.out);
}

test "distributed: sharding flag no-op simple query" {
    const exe = "./zig-out/bin/geode";
    const allocator = std.testing.allocator;
    const server = try getServerAddr(allocator);
    defer allocator.free(server);
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--server", server", "--insecure", "--dist-enable-sharding" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try assertSimpleQueryOk(res.out);
}
