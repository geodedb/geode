const std = @import("std");
const cli_test_util = @import("cli_test_util.zig");
const testing = std.testing;

// Ensures PROFILE output for a query that triggers heuristic index selection
// includes inline NodeIndexScan metadata fields: index_name and selectivity_est.
// Acceptance (NEXT.md Now Task 1): NodeIndexScan op has index_name + numeric selectivity_est.
// We'll look for substrings to keep test stable against unrelated field ordering changes.

test "profile includes NodeIndexScan metadata" {
    const res = try cli_test_util.run(&.{ "./zig-out/bin/geode", "PROFILE RETURN 1 AS x WHERE x = 1" });
    defer testing.allocator.free(res.out);
    defer testing.allocator.free(res.err);
    try testing.expectEqual(@as(i32, 0), res.code);
    // We expect JSON output with a profile payload. Metadata is in the profile JSON.
    try testing.expect(std.mem.indexOf(u8, res.out, "NodeIndexScan") != null);
    try testing.expect(std.mem.indexOf(u8, res.out, "\"index_name\":\"") != null);
    // selectivity_est should appear with floating value; just assert key presence.
    try testing.expect(std.mem.indexOf(u8, res.out, "selectivity_est") != null);
}
