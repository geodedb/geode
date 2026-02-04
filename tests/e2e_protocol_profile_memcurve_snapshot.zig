const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

// Use shared normalization
fn normalize(line: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return util.normalizeNumbers(allocator, line);
}

const EXPECTED = "mem_curve\":[{\"op_index\":0,\"net_after_op\":0}"; // intentionally truncated prefix for stability

test "protocol: PROFILE mem_curve snapshot prefix" {
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x LIMIT 1", &.{"GEODE_PROFILE_MEMCURVE=1"});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"mem_curve\":") != null);
    // Check normalized contains expected prefix token order.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const norm = try normalize(out, arena.allocator());
    try testing.expect(std.mem.indexOf(u8, norm, EXPECTED) != null);
}
