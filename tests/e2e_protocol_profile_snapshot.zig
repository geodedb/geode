const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

// structuralSignature now delegates to util.normalizeNumbers (which also strips whitespace)
fn structuralSignature(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    return util.normalizeNumbers(allocator, line);
}

// Initial snapshot test: builds a structural signature independent of numeric jitter.
// TODO(profile_version-bump): When GROUP BY operator lands and profile_version increments, update EXPECTED_PREFIX and add new op ordering expectations.

const EXPECTED_PREFIX = "{\"profile_version\":0,\"ops\":[{\"op\":\"NodeScan\",\"phase\":\"SCAN\"";

test "protocol: PROFILE structural snapshot" {
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x LIMIT 1", null);
    defer testing.allocator.free(out);
    // Ensure profile_version matches snapshot expectation before signature compare (fast fail for version bump)
    if (std.mem.indexOf(u8, out, "\"profile_version\":1") == null) return error.ProfileVersionMismatch;
    // Op order subset sanity (stabilizes semantics around structural signature)
    try util.assertOpOrder(out, &.{ "NodeScan", "Expand", "Project", "Limit" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sig = try structuralSignature(arena.allocator(), out);
    if (std.mem.indexOf(u8, sig, EXPECTED_PREFIX) == null) {
        std.debug.print("SNAPSHOT_PREFIX_MISMATCH\nexpected_prefix={s}\nactual_sig={s}\n", .{ EXPECTED_PREFIX, sig });
        return error.SnapshotMismatch;
    }
}
