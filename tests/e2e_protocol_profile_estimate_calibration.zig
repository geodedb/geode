const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 20);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

test "protocol: PROFILE includes calibration metrics" {
    const exe = "zig-out/bin/geoded";
    const out = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    _ = it.next();
    const profile_line = it.next() orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, profile_line, "median_error_abs_pct") != null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "stddev_error_abs_pct") != null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "adjusted_estimate_factor") != null);
}
