const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

// Ensures PROFILE output includes NodeIndexScan when heuristic conditions (WHERE + '=') present.
// Heuristic uses captured query_text (post PROFILE/EXPLAIN strip) stored in ServerState.
// Simple predicate is sufficient to trigger naming substitution.
// Accept either NodeIndexScan or NodeScan if heuristic disabled in future (soft assert path).
// Hard assert for now to exercise path.

test "profile heuristic emits NodeIndexScan" {
    const q = "PROFILE RETURN 1 AS x WHERE x=1"; // includes WHERE and '='
    const out = try util.runProfile(testing.allocator, q, null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "NodeIndexScan") != null);
    // Metadata fields should be present
    try testing.expect(std.mem.indexOf(u8, out, "\"index_name\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "selectivity_est") != null);
}
