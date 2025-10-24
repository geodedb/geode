const std = @import("std");
const recursive = @import("../src/planner/recursive.zig");

// TestCANARY_REQ_GQL_079_CycleGuard
// Ensures hasCycleSimple detects simple cycles and does not flag acyclic sequences.

fn alloc() std.mem.Allocator {
    return std.heap.page_allocator; // minimal for this test
}

test "TestCANARY_REQ_GQL_079_CycleGuard" {
    const a = alloc();

    // Acyclic path
    var path1: [5]u64 = .{ 1, 2, 3, 4, 5 };
    const cyc1 = try recursive.RecursiveQueryProcessor.hasCycleSimple(a, path1[0..]);
    try std.testing.expect(!cyc1);

    // Simple cycle: 1->2->3->2
    var path2: [4]u64 = .{ 1, 2, 3, 2 };
    const cyc2 = try recursive.RecursiveQueryProcessor.hasCycleSimple(a, path2[0..]);
    try std.testing.expect(cyc2);

    // Self cycle (single node repeated later)
    var path3: [6]u64 = .{ 10, 11, 12, 13, 10, 14 };
    const cyc3 = try recursive.RecursiveQueryProcessor.hasCycleSimple(a, path3[0..]);
    try std.testing.expect(cyc3);
}
