const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

fn run(args: []const []const u8) ![]u8 {
    const res = try cli_test_util.run(args);
    std.testing.allocator.free(res.err);
    return res.out;
}

fn parseMemCurve(profile_line: []const u8) !struct { indices: []usize, nets: []usize } {
    const allocator = testing.allocator;
    const tag = "\"mem_curve\":[";
    const start_pos_opt = std.mem.indexOf(u8, profile_line, tag) orelse return error.NoMemCurve;
    var pos = start_pos_opt + tag.len;
    var idx_list = std.ArrayList(usize).initCapacity(allocator, 0) catch return error.OOM;
    var net_list = std.ArrayList(usize).initCapacity(allocator, 0) catch return error.OOM;
    errdefer idx_list.deinit(allocator);
    errdefer net_list.deinit(allocator);
    while (pos < profile_line.len and profile_line[pos] != ']') {
        // Expect object starting with {"op_index":
        const oi_tag = "{\"op_index\":";
        if (!std.mem.startsWith(u8, profile_line[pos..], oi_tag)) return error.BadFormat;
        pos += oi_tag.len;
        const oi_begin = pos;
        while (pos < profile_line.len and profile_line[pos] >= '0' and profile_line[pos] <= '9') pos += 1;
        const oi_slice = profile_line[oi_begin..pos];
        const op_index = try std.fmt.parseInt(usize, oi_slice, 10);
        const na_tag = ",\"net_after_op\":";
        if (!std.mem.startsWith(u8, profile_line[pos..], na_tag)) return error.BadFormat;
        pos += na_tag.len;
        const na_begin = pos;
        while (pos < profile_line.len and profile_line[pos] >= '0' and profile_line[pos] <= '9') pos += 1;
        const na_slice = profile_line[na_begin..pos];
        const net_after = try std.fmt.parseInt(usize, na_slice, 10);
        try idx_list.append(allocator, op_index);
        try net_list.append(allocator, net_after);
        // Skip closing }
        if (pos >= profile_line.len or profile_line[pos] != '}') return error.BadFormat;
        pos += 1;
        if (pos < profile_line.len and profile_line[pos] == ',') pos += 1; // move past comma for next object
    }
    if (pos >= profile_line.len or profile_line[pos] != ']') return error.BadFormat;
    const indices_slice = idx_list.toOwnedSlice(allocator) catch return error.OOM;
    const nets_slice = net_list.toOwnedSlice(allocator) catch return error.OOM;
    return .{ .indices = indices_slice, .nets = nets_slice };
}

test "protocol: PROFILE mem_curve invariants monotonic indices & nets" {
    const exe = "zig-out/bin/geode";
    const out = try run(&.{ exe, "--profile-memcurve", "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 2", "--param", "a", "[1,1,2,3,5,8]" });
    defer testing.allocator.free(out);
    var it = std.mem.splitScalar(u8, out, '\n');
    _ = it.next(); // schema
    const profile_line = it.next() orelse return error.MissingProfile;
    const parsed = try parseMemCurve(profile_line);
    defer testing.allocator.free(parsed.indices);
    defer testing.allocator.free(parsed.nets);
    try testing.expect(parsed.indices.len == parsed.nets.len);
    if (parsed.indices.len > 0) {
        var i: usize = 1;
        while (i < parsed.indices.len) : (i += 1) {
            try testing.expect(parsed.indices[i] > parsed.indices[i - 1]);
            // nets must be monotonic non-decreasing (no negative freed_bytes effect)
            try testing.expect(parsed.nets[i] >= parsed.nets[i - 1]);
        }
        // Final net must equal memory.net_bytes summary
        const mem_tag = "\"memory\":{";
        const mem_pos_opt = std.mem.indexOf(u8, profile_line, mem_tag) orelse return error.MissingMemory;
        var mpos = mem_pos_opt + mem_tag.len;
        const nb_tag = "\"net_bytes\":";
        if (!std.mem.startsWith(u8, profile_line[mpos..], nb_tag)) return error.BadMemoryBlock;
        mpos += nb_tag.len;
        const nb_begin = mpos;
        while (mpos < profile_line.len and profile_line[mpos] >= '0' and profile_line[mpos] <= '9') mpos += 1;
        const nb_slice = profile_line[nb_begin..mpos];
        const net_bytes_summary = try std.fmt.parseInt(usize, nb_slice, 10);
        try testing.expectEqual(parsed.nets[parsed.nets.len - 1], net_bytes_summary);
        // Invariant: mem_curve length equals number of ops
        var op_count: usize = 0;
        var search_idx: usize = 0;
        const op_pat = "\"op\":\"";
        while (true) {
            const pos = std.mem.indexOfPos(u8, profile_line, search_idx, op_pat) orelse break;
            op_count += 1;
            search_idx = pos + op_pat.len;
        }
        try testing.expectEqual(op_count, parsed.indices.len);
    }
}
