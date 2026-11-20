const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("profile_test_util.zig");

test "protocol: per-stage allocation deltas and op ordering" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // DISTINCT + ORDER + LIMIT to exercise multiple phases.
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x DISTINCT ORDER BY x LIMIT 2", null);
    defer testing.allocator.free(out);
    // Parse JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const prof_obj = parsed.value.object;
    const ops_val = prof_obj.get("ops") orelse return error.MissingOps;
    try testing.expect(ops_val.* == .array);
    const ops = ops_val.array.items;
    // Collect ordering indices
    var idx_nodescan: ?usize = null;
    var idx_expand: ?usize = null;
    var idx_project: ?usize = null;
    var idx_distinct: ?usize = null;
    var idx_sort: ?usize = null;
    var idx_limit: ?usize = null;
    var sum_alloc: usize = 0;
    for (ops, 0..) |opv, i| {
        try testing.expect(opv == .object);
        const o = opv.object;
        const name_val = o.get("op") orelse return error.MissingOpName;
        try testing.expect(name_val.* == .string);
        const name = name_val.string;
        const alloc_field = o.get("bytes_alloc") orelse return error.MissingBytesAlloc;
        try testing.expect(alloc_field.* == .integer);
        const alloc_amt: usize = @intCast(alloc_field.integer);
        sum_alloc += alloc_amt;
        // No stage should have negative or huge improbable alloc (basic guard)
        try testing.expect(alloc_amt < 1 << 40);
        if (std.mem.eql(u8, name, "NodeScan")) {
            idx_nodescan = i;
        } else if (std.mem.eql(u8, name, "Expand")) {
            idx_expand = i;
        } else if (std.mem.eql(u8, name, "Project")) {
            idx_project = i;
        } else if (std.mem.eql(u8, name, "Distinct")) {
            idx_distinct = i;
        } else if (std.mem.eql(u8, name, "Sort")) {
            idx_sort = i;
        } else if (std.mem.eql(u8, name, "Limit")) {
            idx_limit = i;
        }
    }
    // Required ops appear
    try testing.expect(idx_nodescan != null);
    try testing.expect(idx_expand != null);
    try testing.expect(idx_project != null);
    try testing.expect(idx_distinct != null); // DISTINCT specified
    try testing.expect(idx_sort != null);
    try testing.expect(idx_limit != null);
    // Ordering monotonic via helper (subset sequence)
    try util.assertOpOrder(out, &.{ "NodeScan", "Expand", "Distinct", "Sort", "Project", "Limit" });
    // Peak/memory relationship: sum of per-stage allocations should not exceed peak_bytes by more than modest fragmentation slack.
    const mem_val = prof_obj.get("memory") orelse return error.MissingMemory;
    try testing.expect(mem_val.* == .object);
    const mem_obj = mem_val.object;
    const peak_val = mem_obj.get("peak_bytes") orelse return error.MissingPeak;
    try testing.expect(peak_val.* == .integer);
    const peak: usize = @intCast(peak_val.integer);
    // Allow sum_alloc to be <= peak * 2 (loose upper bound for now until fragmentation attribution refined).
    if (peak > 0) try testing.expect(sum_alloc <= peak * 2);
}
