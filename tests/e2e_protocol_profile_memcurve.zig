const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 18);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

test "protocol: PROFILE mem_curve present when flag enabled" {
    const exe = "zig-out/bin/geoded";
    const out = try run(&.{ exe, "--profile-memcurve", "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"mem_curve\":[") != null);
}
