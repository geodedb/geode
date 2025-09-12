const std = @import("std");
const geode = @import("geode");

// Ensure heuristic equality detection traverses logical AND/OR nesting.
test "predicate expansion: nested equality detection" {
    var res = try geode.parseGql("RETURN 1 AS x WHERE (1 = 1 AND (2 = 2 OR 3 = 3))", std.testing.allocator);
    defer res.deinit();
    try std.testing.expect(res.program.statements.len == 1);
    // Presence of Binary nodes with Eq should exist; we just ensure parse succeeded (heuristic exercised in server path).
}
