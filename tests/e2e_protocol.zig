const std = @import("std");

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = std.ChildProcess.init(args, ally);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    const err = try child.stderr.?.readToEndAlloc(ally, 1 << 20);
    const term = try child.wait();
    return .{ .code = term.Exited, .out = out, .err = err };
}

test "protocol: Valid ORDER/LIMIT" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.eql(
        u8,
        "{\"status_class\":\"00000\",\"result\":{\"type\":\"SCHEMA\",\"columns\":[{\"name\":\"x\",\"type\":\"INT\"}]}}\n{\"status_class\":\"00000\",\"result\":{\"type\":\"BINDINGS\",\"ordered\":true,\"order_keys\":[\"x\"],\"rows\":[{\"x\":1}]}}\n",
        res.out,
    ));
}

test "protocol: Invalid LIMIT+OFFSET without ORDER (US001)" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 LIMIT 10 OFFSET 5" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "US001") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "16.18–16.19") != null);
}

test "protocol: Invalid ORDER BY key (IllegalOrderKey)" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN a ORDER BY f(a)" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 2), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "IllegalOrderKey") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.err, "14.10") != null);
}

test "protocol: Set operation DISTINCT (UNION)" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{ exe, "RETURN 1 AS x UNION RETURN 1 AS x" });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    // We only check that ordered=false appears; and one row
    try std.testing.expectEqual(@as(i32, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "\"ordered\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"x\":1}") != null);
}

test "protocol: CASE expression sanity with params" {
    const exe = "./zig-out/bin/geodec";
    const res = try run(&.{
        exe,
        "RETURN CASE WHEN a IS NULL THEN 'n' WHEN a THEN 't' ELSE 'f' END AS r",
        "--json-param",
        "a",
        "[null,true,false]",
    });
    defer std.testing.allocator.free(res.out);
    defer std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    // Expect rows with r:n,r:t,r:f in any order (order irrelevant)
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"r\":\"n\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"r\":\"t\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.out, "{\"r\":\"f\"}") != null);
}
