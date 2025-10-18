const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const allocator = std.testing.allocator;
    var child = Child.init(args, allocator);
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
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--no-quic", "--dist-enable-raft" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try assertSimpleQueryOk(res.out);
}

test "distributed: 2pc enabled simple query" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--no-quic", "--dist-enable-2pc" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try assertSimpleQueryOk(res.out);
}

test "distributed: sharding flag no-op simple query" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1", "--no-quic", "--dist-enable-sharding" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try assertSimpleQueryOk(res.out);
}
