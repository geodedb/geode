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

test "protocol: PROFILE freed_bytes shows on Sort stage" {
    const exe = "zig-out/bin/geode";
    // ORDER BY ensures Sort stage present.
    const out = try run(&.{ exe, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1" });
    defer testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    _ = it.next();
    const profile_line = it.next() orelse return error.MissingProfile;
    // Find "Sort" object and check for freed_bytes non-zero.
    const sort_pos = std.mem.indexOf(u8, profile_line, "\"Sort\"") orelse return error.NoSort;
    // Slice from sort_pos forward to limit scanning cost
    const tail = profile_line[sort_pos..];
    const fb_tag = "freed_bytes\":";
    const fb_pos = std.mem.indexOf(u8, tail, fb_tag) orelse return error.NoFreedBytes;
    var i = fb_pos + fb_tag.len;
    var val: usize = 0;
    while (i < tail.len and tail[i] >= '0' and tail[i] <= '9') : (i += 1) {
        val = val * 10 + @as(usize, tail[i] - '0');
    }
    try testing.expect(val > 0);
}
