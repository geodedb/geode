const std = @import("std");
const mvcc_adv = @import("../src/transactions/mvcc_adv/early_detect.zig");
// TestCANARY_REQ_GQL_073_FalsePositiveReduction
// Validates that overlapping pure reads do NOT produce a conflict but adding a write does.

test "TestCANARY_REQ_GQL_073_FalsePositiveReduction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var det = mvcc_adv.EarlyDetector.init(allocator);
    defer det.deinit();
    try det.noteAccess(10, "k1", false);
    try det.noteAccess(20, "k1", false); // both reads
    try std.testing.expect(!det.predictConflict(10, 20));
    try det.noteAccess(20, "k1", true); // write on same key
    try std.testing.expect(det.predictConflict(10, 20));
}
