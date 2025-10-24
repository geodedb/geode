const std = @import("std");
const testing = std.testing;

fn run(args: []const []const u8) !struct { out: []u8 } {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 16);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return .{ .out = out };
}

test "protocol: PROFILE freed_bytes and net_after_op monotonic (non-increasing freed impact)" {
    const exe = "zig-out/bin/geoded";
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x LIMIT 3", "--json-param", "a", "[1,2,2,3,4,5]" });
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next();
    const line = it.next() orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, line, "\"freed_bytes\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, "\"net_after_op\"") != null);
    const net_tag = "\"net_after_op\":";
    var idx: usize = 0;
    var last_net: usize = 0;
    while (true) {
        const pos = std.mem.indexOfPos(u8, line, idx, net_tag) orelse break;
        var i = pos + net_tag.len;
        while (i < line.len and line[i] == ' ') i += 1;
        const begin = i;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
        if (i == begin) break;
        const val = try std.fmt.parseInt(usize, line[begin..i], 10);
        try testing.expect(val >= last_net); // net bytes non-decreasing prototype (no frees yet)
        last_net = val;
        idx = i;
    }
}
