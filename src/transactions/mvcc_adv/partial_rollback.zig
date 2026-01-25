const std = @import("std");
// CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=PartialRollbackMechanism; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_073_PartialRollbackMechanism; BENCH=BenchmarkCANARY_REQ_GQL_073_PartialRollbackMechanism; OWNER=txn; UPDATED=2025-09-20

/// Partial rollback marker: logically mark a sub-sequence of operations as discarded without aborting the whole txn.
pub const SubTxn = struct {
    id: u64,
    active: bool = true,
    discarded: bool = false,
};

pub fn rollback(sub: *SubTxn) void {
    if (sub.active) {
        sub.discarded = true;
        sub.active = false;
    }
}

// ==================== Unit Tests (GAP-0237) ====================
// CANARY: REQ=REQ-GAP-0237; FEATURE="MVCCAdvancedUnitTests"; ASPECT=PartialRollback; STATUS=TESTED; TEST=test_partial_rollback; OWNER=txn; UPDATED=2026-01-25

test "SubTxn initializes with default values" {
    const sub = SubTxn{ .id = 1 };
    try std.testing.expectEqual(@as(u64, 1), sub.id);
    try std.testing.expect(sub.active);
    try std.testing.expect(!sub.discarded);
}

test "SubTxn can be created inactive" {
    const sub = SubTxn{ .id = 2, .active = false };
    try std.testing.expect(!sub.active);
}

test "rollback marks active SubTxn as discarded" {
    var sub = SubTxn{ .id = 1 };
    try std.testing.expect(sub.active);
    try std.testing.expect(!sub.discarded);

    rollback(&sub);

    try std.testing.expect(!sub.active);
    try std.testing.expect(sub.discarded);
}

test "rollback is idempotent on inactive SubTxn" {
    var sub = SubTxn{ .id = 1, .active = false, .discarded = false };

    rollback(&sub);

    // Should not change discarded state since it wasn't active
    try std.testing.expect(!sub.active);
    try std.testing.expect(!sub.discarded);
}

test "rollback does not affect already discarded SubTxn" {
    var sub = SubTxn{ .id = 1 };
    rollback(&sub);
    try std.testing.expect(sub.discarded);

    // Call rollback again - should be no-op
    rollback(&sub);
    try std.testing.expect(sub.discarded);
}

test "SubTxn with zero id" {
    const sub = SubTxn{ .id = 0 };
    try std.testing.expectEqual(@as(u64, 0), sub.id);
}

test "SubTxn with large id" {
    const sub = SubTxn{ .id = std.math.maxInt(u64) };
    try std.testing.expectEqual(std.math.maxInt(u64), sub.id);
}

test "multiple SubTxn instances are independent" {
    var sub1 = SubTxn{ .id = 1 };
    const sub2 = SubTxn{ .id = 2 };

    rollback(&sub1);

    // sub1 should be rolled back
    try std.testing.expect(sub1.discarded);
    try std.testing.expect(!sub1.active);

    // sub2 should be unchanged
    try std.testing.expect(!sub2.discarded);
    try std.testing.expect(sub2.active);
}

test "SubTxn fields can be set independently" {
    const sub = SubTxn{ .id = 1, .active = true, .discarded = true };
    // Both active and discarded true is unusual but allowed
    try std.testing.expect(sub.active);
    try std.testing.expect(sub.discarded);
}

test "SubTxn sequence of state transitions" {
    var sub = SubTxn{ .id = 1 };

    // Initial state
    try std.testing.expect(sub.active);
    try std.testing.expect(!sub.discarded);

    // After rollback
    rollback(&sub);
    try std.testing.expect(!sub.active);
    try std.testing.expect(sub.discarded);

    // Cannot "un-rollback" - state is final
    sub.active = true; // Manual attempt
    rollback(&sub); // Should set discarded again
    try std.testing.expect(sub.discarded);
}

test "rollback preserves id" {
    var sub = SubTxn{ .id = 42 };
    rollback(&sub);
    try std.testing.expectEqual(@as(u64, 42), sub.id);
}
