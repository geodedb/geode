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

test "protocol: PROFILE time consistency cumulative vs total" {
    const exe = "zig-out/bin/geoded";
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 5", "--json-param", "a", "[1,2,2,3,4,5,6,7,8,9]" });
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next();
    const line = it.next() orelse return error.MissingProfile;
    const total_tag = "\"total_time_ns\":";
    const cum_tag = "\"cumulative_time_ns\":";
    const total_val = try extractNum(line, total_tag);
    try testing.expect(total_val > 0);
    var search: usize = 0;
    var last_cum: usize = 0;
    while (true) {
        const pos = std.mem.indexOfPos(u8, line, search, cum_tag) orelse break;
        var i = pos + cum_tag.len;
        while (i < line.len and line[i] == ' ') i += 1;
        const begin = i;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
        if (i == begin) break;
        const v = try std.fmt.parseInt(usize, line[begin..i], 10);
        try testing.expect(v >= last_cum);
        last_cum = v;
        search = i;
    }
    try testing.expect(last_cum > 0);
    // Allow cumulative <= total (no multithreading yet so should be <= and typically close)
    try testing.expect(last_cum <= total_val);
}

fn extractNum(line: []const u8, tag: []const u8) !usize {
    const p = std.mem.indexOf(u8, line, tag) orelse return error.TagMissing;
    var i = p + tag.len;
    while (i < line.len and (line[i] == ' ')) i += 1;
    const begin = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i == begin) return error.BadNumber;
    return try std.fmt.parseInt(usize, line[begin..i], 10);
}
