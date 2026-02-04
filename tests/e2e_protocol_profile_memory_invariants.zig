const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) !struct { out: []u8 } {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    try std.testing.expectEqual(@as(i32, 0), res.code);
    return .{ .out = res.out };
}

test "protocol: PROFILE memory invariants (sum vs peak/total, percent_net)" {
    const exe = "zig-out/bin/geode";
    const res = try run(&.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 3", "--param", "a", "[1,2,2,3,4,5,6,7]" });
    defer testing.allocator.free(res.out);
    var it = std.mem.splitScalar(u8, res.out, '\n');
    _ = it.next(); // schema
    const profile_line = it.next() orelse return error.MissingProfileLine;
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"profile_version\":1") != null);
    const peak_tag = "\"peak_bytes\":";
    const total_tag = "\"total_alloc_bytes\":";
    const net_tag = "\"net_bytes\":";
    const peak_bytes = try extractNum(profile_line, peak_tag);
    const total_alloc_bytes = try extractNum(profile_line, total_tag);
    const net_bytes = try extractNum(profile_line, net_tag);
    try testing.expect(peak_bytes > 0);
    try testing.expect(total_alloc_bytes >= peak_bytes);
    try testing.expect(net_bytes <= peak_bytes);
    var sum_bytes_alloc: usize = 0;
    var max_bytes_alloc: usize = 0;
    var search_index: usize = 0;
    while (true) {
        const op_pos = std.mem.indexOfPos(u8, profile_line, search_index, "\"op\":");
        if (op_pos == null) break;
        const ba_tag = "\"bytes_alloc\":";
        const ba_pos = std.mem.indexOfPos(u8, profile_line, op_pos.?, ba_tag) orelse break;
        const bytes_alloc = try extractNumFrom(profile_line, ba_pos + ba_tag.len);
        sum_bytes_alloc += bytes_alloc;
        if (bytes_alloc > max_bytes_alloc) max_bytes_alloc = bytes_alloc;
        const pn_tag = "\"percent_net\":";
        const pn_pos = std.mem.indexOfPos(u8, profile_line, ba_pos, pn_tag) orelse break;
        const percent_net = try extractNumFrom(profile_line, pn_pos + pn_tag.len);
        try testing.expect(percent_net <= 100);
        search_index = pn_pos + pn_tag.len;
    }
    // Invariant: max stage alloc <= peak
    try testing.expect(max_bytes_alloc <= peak_bytes);
    // Invariant: sum of stage alloc deltas <= total allocated bytes (they're per-stage deltas, may under-count, never exceed total)
    try testing.expect(sum_bytes_alloc <= total_alloc_bytes);
}

fn extractNum(line: []const u8, tag: []const u8) !usize {
    const pos = std.mem.indexOf(u8, line, tag) orelse return error.TagMissing;
    return extractNumFrom(line, pos + tag.len);
}

fn extractNumFrom(line: []const u8, start: usize) !usize {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == ',')) i += 1;
    const begin = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i == begin) return error.BadNumber;
    return try std.fmt.parseInt(usize, line[begin..i], 10);
}
