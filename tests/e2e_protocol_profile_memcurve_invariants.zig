const std = @import("std");
const testing = std.testing;
const profile_util = @import("profile_test_util.zig");

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

// SONNY-6548: ported from the deleted client's `--profile-memcurve` flag and
// `RETURN a AS x DISTINCT` with an array `--param` (neither exists). A read
// takes the trace-backed version-2 payload, whose memory figures are honest
// zeros and which has no mem_curve; the version-1 payload (data changes,
// tenant-bound and RLS sessions) carries the synthetic memory model and the
// curve when the server runs with GEODE_PROFILE_MEMCURVE
// (docs/EXPLAIN_PROFILE.md). The op count is taken from `ops` only: the
// substring count also counted peak_contributors' `{op, bytes_alloc}`.
test "protocol: PROFILE mem_curve invariants monotonic indices & nets" {
    const a = testing.allocator;
    const profile_line = try profile_util.runProfile(a, "PROFILE CREATE (:MemCurve6548 {k: 1})", &.{"GEODE_PROFILE_MEMCURVE=1"});
    defer a.free(profile_line);
    try testing.expect(std.mem.indexOf(u8, profile_line, "\"profile_version\":1") != null);
    const parsed = try parseMemCurve(profile_line);
    defer a.free(parsed.indices);
    defer a.free(parsed.nets);
    try testing.expect(parsed.indices.len > 0);
    try testing.expectEqual(parsed.indices.len, parsed.nets.len);
    var i: usize = 1;
    while (i < parsed.indices.len) : (i += 1) {
        try testing.expect(parsed.indices[i] > parsed.indices[i - 1]);
        // nets non-decreasing (no negative freed_bytes effect)
        try testing.expect(parsed.nets[i] >= parsed.nets[i - 1]);
    }
    var json = try std.json.parseFromSlice(std.json.Value, a, profile_line, .{});
    defer json.deinit();
    const root = json.value.object;
    // The final point equals memory.net_bytes.
    const net_bytes = root.get("memory").?.object.get("net_bytes").?.integer;
    try testing.expectEqual(@as(i64, @intCast(parsed.nets[parsed.nets.len - 1])), net_bytes);
    // One point per operator.
    try testing.expectEqual(root.get("ops").?.array.items.len, parsed.indices.len);
}
