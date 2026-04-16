const std = @import("std");
const cm = @import("../src/schema/constraint_manager.zig");
const unicode = @import("../src/unicode/geode_unicode.zig");
// CANARY: REQ=REQ-GQL-UNICODE-011; FEATURE="UnicodeUniqueKeys"; ASPECT=NormalizeLabel; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_UNICODE_011_UniqueKeyNormalize; OWNER=unicode; UPDATED=2025-09-27

test "TestCANARY_REQ_GQL_UNICODE_011_UniqueKeyNormalize" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var mgr = cm.ConstraintManager.init(gpa.allocator());
    defer mgr.deinit();
    // Insert unique constraint with decomposed label, later verify stored label normalized equals precomposed form
    const decomposed = "E\xCC\x81Label"; // É label decomposed
    const precomposed_norm = try unicode.nfcNormalize(gpa.allocator(), decomposed);
    defer gpa.allocator().free(precomposed_norm);
    try mgr.createUniqueConstraint("uk1", .node, decomposed, &[_][]const u8{"prop"});
    try std.testing.expect(mgr.unique_constraints.items.len == 1);
    const stored = mgr.unique_constraints.items[0].label_or_type;
    try std.testing.expect(std.mem.eql(u8, stored, precomposed_norm));
}
