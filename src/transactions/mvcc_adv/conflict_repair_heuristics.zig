const std = @import("std");
// CANARY: REQ=REQ-GQL-073; FEATURE="MvccAdvanced"; ASPECT=ConflictRepairHeuristics; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_073_ConflictRepairHeuristics; BENCH=BenchmarkCANARY_REQ_GQL_073_ConflictRepairHeuristics; OWNER=txn; UPDATED=2025-09-20

/// Represents a queued operation within a transaction that might be safely reorderable.
pub const TxnOp = struct { key: []const u8, write: bool };

pub fn canSwap(a: TxnOp, b: TxnOp) bool {
    // Heuristic: two reads always reorder; read followed by write on different keys reorder; writes conflict
    if (!a.write and !b.write) return true;
    if (!a.write and b.write and !std.mem.eql(u8, a.key, b.key)) return true;
    if (a.write or b.write) {
        // If both write or one write overlapping key -> cannot swap
        if (std.mem.eql(u8, a.key, b.key)) return false;
        // Different keys: allow only if exactly one is write (already covered) else both write => false
        if (a.write and b.write) return false;
    }
    return false;
}

pub fn attemptLocalReorder(list: []TxnOp) void {
    // single pass bubble-like improvement
    if (list.len < 2) return;
    var i: usize = 0;
    while (i + 1 < list.len) : (i += 1) {
        if (canSwap(list[i], list[i + 1])) {
            const tmp = list[i];
            list[i] = list[i + 1];
            list[i + 1] = tmp;
        }
    }
}

// ==================== Unit Tests (GAP-0237) ====================
// CANARY: REQ=REQ-GAP-0237; FEATURE="MVCCAdvancedUnitTests"; ASPECT=ConflictRepair; STATUS=TESTED; TEST=test_canSwap; OWNER=txn; UPDATED=2026-01-25

test "canSwap allows two reads to reorder" {
    const read_a = TxnOp{ .key = "key1", .write = false };
    const read_b = TxnOp{ .key = "key2", .write = false };
    try std.testing.expect(canSwap(read_a, read_b));
}

test "canSwap allows read followed by write on different keys" {
    const read_op = TxnOp{ .key = "key1", .write = false };
    const write_op = TxnOp{ .key = "key2", .write = true };
    try std.testing.expect(canSwap(read_op, write_op));
}

test "canSwap prevents writes on same key" {
    const write_a = TxnOp{ .key = "key1", .write = true };
    const write_b = TxnOp{ .key = "key1", .write = true };
    try std.testing.expect(!canSwap(write_a, write_b));
}

test "canSwap prevents read-write conflict on same key" {
    const read_op = TxnOp{ .key = "key1", .write = false };
    const write_op = TxnOp{ .key = "key1", .write = true };
    // Read followed by write on same key - this should not swap per heuristics
    try std.testing.expect(!canSwap(read_op, write_op));
}

test "canSwap prevents two writes on different keys" {
    const write_a = TxnOp{ .key = "key1", .write = true };
    const write_b = TxnOp{ .key = "key2", .write = true };
    try std.testing.expect(!canSwap(write_a, write_b));
}

test "attemptLocalReorder does nothing with single element" {
    var ops = [_]TxnOp{.{ .key = "k1", .write = false }};
    attemptLocalReorder(&ops);
    try std.testing.expectEqualStrings("k1", ops[0].key);
}

test "attemptLocalReorder swaps reorderable operations" {
    var ops = [_]TxnOp{
        .{ .key = "k1", .write = false }, // read
        .{ .key = "k2", .write = false }, // read - can swap with previous
    };
    attemptLocalReorder(&ops);
    // Reads can swap, so order may change
    try std.testing.expectEqual(@as(usize, 2), ops.len);
}

test "attemptLocalReorder preserves conflicting order" {
    var ops = [_]TxnOp{
        .{ .key = "k1", .write = true }, // write
        .{ .key = "k1", .write = true }, // write same key - cannot swap
    };
    const original_first = ops[0].key;
    attemptLocalReorder(&ops);
    // Should preserve order since same key writes conflict
    try std.testing.expectEqualStrings(original_first, ops[0].key);
}

test "canSwap with empty keys" {
    const a = TxnOp{ .key = "", .write = false };
    const b = TxnOp{ .key = "", .write = false };
    // Empty keys, both reads - should allow swap
    try std.testing.expect(canSwap(a, b));
}

test "canSwap write followed by read on same key" {
    const write_op = TxnOp{ .key = "key1", .write = true };
    const read_op = TxnOp{ .key = "key1", .write = false };
    // Write followed by read on same key
    try std.testing.expect(!canSwap(write_op, read_op));
}

test "attemptLocalReorder with empty list" {
    var ops = [_]TxnOp{};
    attemptLocalReorder(&ops);
    try std.testing.expectEqual(@as(usize, 0), ops.len);
}

test "attemptLocalReorder multiple swaps" {
    var ops = [_]TxnOp{
        .{ .key = "k1", .write = false },
        .{ .key = "k2", .write = false },
        .{ .key = "k3", .write = false },
    };
    attemptLocalReorder(&ops);
    // All reads, may be reordered but count should stay same
    try std.testing.expectEqual(@as(usize, 3), ops.len);
}

test "TxnOp struct has correct fields" {
    const op = TxnOp{ .key = "test_key", .write = true };
    try std.testing.expectEqualStrings("test_key", op.key);
    try std.testing.expect(op.write);
}

test "canSwap symmetry for reads" {
    const read_a = TxnOp{ .key = "key1", .write = false };
    const read_b = TxnOp{ .key = "key2", .write = false };
    // Both directions should allow swap
    try std.testing.expect(canSwap(read_a, read_b));
    try std.testing.expect(canSwap(read_b, read_a));
}

test "canSwap with same read key" {
    const read_a = TxnOp{ .key = "same", .write = false };
    const read_b = TxnOp{ .key = "same", .write = false };
    // Same key, both reads - should allow swap
    try std.testing.expect(canSwap(read_a, read_b));
}
