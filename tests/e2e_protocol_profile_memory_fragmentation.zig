const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

// Ensures fragmentation slack (sum bytes_alloc vs peak) remains within policy (< 1.3x tightened)
const FRAG_SLACK_NUM: usize = 13; // numerator (<= 1.3x)
const FRAG_SLACK_DEN: usize = 10; // denominator
test "protocol: PROFILE memory fragmentation slack bound" {
    const exe = "./zig-out/bin/geodec";
    // Use a query with multiple operators to accumulate allocations.
    const out = try util.runCli(testing.allocator, &.{ exe, "PROFILE RETURN a AS x DISTINCT ORDER BY x OFFSET 1 LIMIT 3", "--json-param", "a", "[9,8,7,6,5,5,4,3,2,1]" });
    defer testing.allocator.free(out);
    const pl = util.findProfileLine(out) orelse return error.MissingProfile;
    // Parse ops to sum bytes_alloc
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, pl, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const result = root.get("result") orelse return error.MissingResult;
    if (result.* != .object) return error.BadResult;
    const json_val = result.object.get("json") orelse return error.MissingJson;
    if (json_val.* != .object) return error.BadJson;
    const prof = json_val.object;
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
    const mem_stats = util.parseMemory(pl) orelse return error.MissingMemoryBlock;
    if (mem_stats.peak_bytes > 0) {
        // slack = sum_alloc / peak <= FRAG_SLACK_NUM/FRAG_SLACK_DEN
        try testing.expect(sum_alloc * FRAG_SLACK_DEN <= mem_stats.peak_bytes * FRAG_SLACK_NUM);
    }
}
