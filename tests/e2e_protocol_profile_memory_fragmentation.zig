const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

// Ensures fragmentation slack (sum bytes_alloc vs peak) remains within policy (< 1.3x tightened)
const FRAG_SLACK_NUM: usize = 13; // numerator (<= 1.3x)
const FRAG_SLACK_DEN: usize = 10; // denominator
test "protocol: PROFILE memory fragmentation slack bound" {
    // Use a query with multiple operators to accumulate allocations.
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 3", null);
    defer testing.allocator.free(out);
    // Parse ops to sum bytes_alloc
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const prof = parsed.value.object;
    const ops_val = prof.get("ops") orelse return error.MissingOps;
    if (ops_val.* != .array) return error.BadOps;
    var sum_alloc: usize = 0;
    for (ops_val.array.items) |opv| {
        if (opv != .object) return error.OpNotObject;
        const o = opv.object;
        const alloc_field = o.get("bytes_alloc") orelse return error.MissingBytesAlloc;
        if (alloc_field.* != .integer) return error.BadAllocField;
        const alloc_amt: usize = @intCast(alloc_field.integer);
        sum_alloc += alloc_amt;
    }
    const mem_stats = util.parseMemory(out) orelse return error.MissingMemoryBlock;
    if (mem_stats.peak_bytes > 0) {
        // slack = sum_alloc / peak <= FRAG_SLACK_NUM/FRAG_SLACK_DEN
        try testing.expect(sum_alloc * FRAG_SLACK_DEN <= mem_stats.peak_bytes * FRAG_SLACK_NUM);
    }
}
