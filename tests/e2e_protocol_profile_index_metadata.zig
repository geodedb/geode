const std = @import("std");
const testing = std.testing;
const Child = @import("child_runner.zig");

// Ensures PROFILE output for a query that triggers heuristic index selection
// includes inline NodeIndexScan metadata fields: index_name and selectivity_est.
// Acceptance (NEXT.md Now Task 1): NodeIndexScan op has index_name + numeric selectivity_est.
// We'll look for substrings to keep test stable against unrelated field ordering changes.

test "profile includes NodeIndexScan metadata" {
    var child = try Child.spawn(&.{"PROFILE RETURN 1 AS x WHERE x = 1"});
    defer child.deinit();
    // Read all stdout
    const out = try child.readAllStdoutAlloc(testing.allocator, 1_000_000);
    // We expect SCHEMA then PROFILE JSON lines. Metadata is in PROFILE JSON.
    try testing.expect(std.mem.indexOf(u8, out, "NodeIndexScan") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"index_name\":\"") != null);
    // selectivity_est should appear with floating value; just assert key presence.
    try testing.expect(std.mem.indexOf(u8, out, "selectivity_est") != null);
}
