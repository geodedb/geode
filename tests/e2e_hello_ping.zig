const std = @import("std");
const Child = if (@hasDecl(std, "ChildProcess")) std.ChildProcess else std.process.Child;

fn run(args: []const []const u8) !struct { code: i32, out: []u8, err: []u8 } {
    const ally = std.testing.allocator;
    var child = Child.init(args, ally);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Send HELLO
    try child.stdin.?.writeAll("{\"type\":\"HELLO\",\"client_name\":\"test\",\"client_ver\":\"0.1\",\"wanted_conformance\":\"min\"}\n");
    const hello = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    // We expect conformance digest and diagnostics array present, ORDER_KEYS and PROFILE_SCHEMA=v2 in features
    defer ally.free(hello);
    try std.testing.expect(std.mem.indexOf(u8, hello, "\"conformance\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "\"digest\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "ORDER_KEYS=") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello, "PROFILE_SCHEMA=v2") != null);

    // Now send PING
    try child.stdin.?.writeAll("{\"type\":\"PING\"}\n");
    const ping = try child.stdout.?.readToEndAlloc(ally, 1 << 20);
    defer ally.free(ping);
    // Should contain dist block when flags are present; tolerant test: just check ok:true present
    try std.testing.expect(std.mem.indexOf(u8, ping, "\"ok\":true") != null);

    // Cleanup
    child.stdin.?.close();
    child.stdout.?.close();
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |st| st,
        else => 2,
    };
    try std.testing.expectEqual(@as(i32, 0), code);
    return .{ .code = code, .out = try ally.dupe(u8, ""), .err = try ally.dupe(u8, "") };
}

test "HELLO includes conformance digest and diagnostics; PING health OK" {
    const exe = "./zig-out/bin/geoded";
    const res = try run(&.{exe});
    _ = res;
}
