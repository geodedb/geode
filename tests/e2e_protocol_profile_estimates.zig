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

// Validates presence of estimate_bytes / estimate_vs_actual / cumulative_time_ns and monotonic cumulative.
// Uses DISTINCT + ORDER + LIMIT to exercise multiple stages.

test "protocol: PROFILE estimates & cumulative time monotonic" {
    const exe = "zig-out/bin/geoded";
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x LIMIT 5", "--json-param", "a", "[1,2,2,3,4,5,6,7,8]" });
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next(); // schema
    const profile_line = it.next() orelse return error.MissingProfileLine;
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"estimate_bytes\"") != null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"estimate_vs_actual\"") != null);
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"cumulative_time_ns\"") != null);
    var search: usize = 0;
    var last_cum: usize = 0;
    const ct_tag = "\"cumulative_time_ns\":";
    while (true) {
        const pos = std.mem.indexOfPos(u8, profile_line, search, ct_tag);
        if (pos == null) break;
        var i = pos.? + ct_tag.len;
        while (i < profile_line.len and (profile_line[i] == ' ')) i += 1;
        const begin = i;
        while (i < profile_line.len and profile_line[i] >= '0' and profile_line[i] <= '9') i += 1;
        if (i == begin) break;
        const val = try std.fmt.parseInt(usize, profile_line[begin..i], 10);
        try testing.expect(val >= last_cum);
        last_cum = val;
        search = i;
    }
    try testing.expect(last_cum > 0);
}
