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
