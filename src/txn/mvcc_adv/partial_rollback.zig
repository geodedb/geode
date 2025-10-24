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
