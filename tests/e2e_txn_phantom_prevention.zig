const std = @import("std");
const testing = std.testing;
const txn = @import("../src/txn/manager.zig");
const range_tracker = @import("../src/txn/range_tracker.zig");

// CANARY: REQ=REQ-GQL-022; FEATURE="Phantom Prevention"; ASPECT=RangeTracking; STATUS=TESTED; TEST=e2e_txn_phantom_prevention; OWNER=txn; UPDATED=2025-09-25

test "Phantom prevention with range tracking" {
    const allocator = testing.allocator;
    
    var manager = try txn.TransactionManager.init(allocator, .{
        .isolation_level = .serializable,
        .phantom_prevention = true, // Default ON in v0.16.0
    });
    defer manager.deinit();
    
    // Start transaction 1
    const txn1 = try manager.beginTransaction();
    defer txn1.rollback() catch {};
    
    // T1 reads range [A, Z]
    try txn1.addRangeRead("A", "Z");
    
    // Start transaction 2
    const txn2 = try manager.beginTransaction();
    defer txn2.rollback() catch {};
    
    // T2 tries to insert in range [A, Z]
    const result = txn2.checkPhantomConflict("M"); // Middle of range
    
    // Should detect phantom conflict
    try testing.expect(result == .Conflict);
    
    std.debug.print("PHANTOM_BLOCKED isolation=SERIALIZABLE range=[A,Z]\n", .{});
}

test "Range tracker integration" {
    const allocator = testing.allocator;
    
    var tracker = range_tracker.RangeTracker.init(allocator);
    defer tracker.deinit();
    
    // Track range read
    try tracker.addRange(1, "users", "id", .{ .start = "100", .end = "200" });
    
    // Check for conflicts
    const conflict1 = tracker.hasConflict(2, "users", "id", "150"); // Within range
    const conflict2 = tracker.hasConflict(2, "users", "id", "250"); // Outside range
    
    try testing.expect(conflict1 == true);
    try testing.expect(conflict2 == false);
}

test "Phantom prevention disabled compatibility" {
    const allocator = testing.allocator;
    
    // Test that we can disable if needed (though default is ON)
    var manager = try txn.TransactionManager.init(allocator, .{
        .isolation_level = .read_committed,
        .phantom_prevention = false,
    });
    defer manager.deinit();
    
    const txn1 = try manager.beginTransaction();
    defer txn1.rollback() catch {};
    
    // Without phantom prevention, no range tracking
    try txn1.addRangeRead("A", "Z");
    
    const txn2 = try manager.beginTransaction();
    defer txn2.rollback() catch {};
    
    // Should not detect conflict when disabled
    const result = txn2.checkPhantomConflict("M");
    try testing.expect(result == .NoConflict);
}