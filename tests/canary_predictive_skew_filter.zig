const std = @import("std");
const txn = @import("txn/manager.zig");

// TestCANARY_REQ_GQL_073_PredictiveSkewFilter
test "TestCANARY_REQ_GQL_073_PredictiveSkewFilter" {
    var mgr: txn.Manager = undefined;
    mgr.init(std.testing.allocator);
    defer mgr.deinit();
    try mgr.enablePredictiveSkew();

    // Simulate hotspot writes on key "hot" until filter marks it hot.
    var t: txn.Txn = mgr.begin();
    var i: usize = 0;
    var hot_detected = false;
    while (i < 6000) : (i += 1) {
        // we expect at some point to abort with error.HotSkew
        if (mgr.acquireWrite("hot", &t, std.testing.allocator)) {
            // acquired lock; release immediately
            mgr.releaseWrite("hot", &t);
        } else |err| switch (err) {
            error.HotSkew => {
                hot_detected = true;
                break;
            },
            else => return err,
        }
    }
    try std.testing.expect(hot_detected);
}
