const std = @import("std");
const txn = @import("../src/txn/manager.zig");

// TestCANARY_REQ_GQL_013_TxnCommit - canonical MVCC commit evidence (supersedes legacy TestCANARY_REQ_GQL_030_TxnCommit)
// Verifies that commit transitions state and assigns commit timestamp > start.
test "TestCANARY_REQ_GQL_013_TxnCommit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var mgr: txn.Manager = undefined;
    mgr.init(allocator);
    defer mgr.deinit();

    var t = mgr.begin();
    try std.testing.expectEqual(@as(txn.TxnState, .Active), t.state);
    const start_ts = t.start_ts;
    try mgr.commit(&t);
    try std.testing.expectEqual(@as(txn.TxnState, .Committed), t.state);
    try std.testing.expect(t.commit_ts > start_ts);
}
