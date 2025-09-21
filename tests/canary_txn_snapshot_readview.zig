const std = @import("std");
const txn = @import("txn");

// CANARY: REQ=REQ-GQL-013; FEATURE="Transactions/MVCC"; ASPECT=SnapshotReadView; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_013_SnapshotReadView; OWNER=engine; UPDATED=2025-09-21

test "TestCANARY_REQ_GQL_013_SnapshotReadView" {
    var mgr: txn.Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();

    var t1 = mgr.begin();
    const t2 = mgr.begin();
    // capture snapshot; should include t1 and t2 ids
    const snap = mgr.captureSnapshot(std.testing.allocator);
    defer mgr.releaseSnapshot(std.testing.allocator, snap);
    try std.testing.expect(snap.active.len == 2);
    // commit one txn; snapshot still reflects prior state (SI semantics)
    try mgr.commit(&t1);
    try std.testing.expect(snap.active.len == 2);
    // new snapshot after commit should show only remaining active transaction
    const snap2 = mgr.captureSnapshot(std.testing.allocator);
    defer mgr.releaseSnapshot(std.testing.allocator, snap2);
    try std.testing.expect(snap2.active.len == 1);
    try std.testing.expect(snap2.active[0] == t2.id);
}
