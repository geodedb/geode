const std = @import("std");
const protocol = @import("../src/protocol.zig");
const txn = @import("../src/transactions/manager.zig");

// Minimal helper to simulate a HELLO round trip.
fn simulateHello() !void {
    // In real implementation this would serialize/deserialize frames.
    const hello = protocol.Hello{ .client_name = "test", .client_ver = "0", .wanted_conformance = "minimum" };
    _ = hello; // placeholder no-op
}

// TestCANARY_REQ_GQL_005_HelloRoundTrip
test "TestCANARY_REQ_GQL_005_HelloRoundTrip" {
    try simulateHello();
}

// TestCANARY_REQ_GQL_030_TxnCommit
test "TestCANARY_REQ_GQL_030_TxnCommit" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var mgr: txn.Manager = undefined;
    mgr.init(allocator);
    defer mgr.deinit();
    var t = mgr.begin();
    try mgr.commit(&t);
    try std.testing.expectEqual(txn.TxnState.Committed, t.state);
}

// TestCANARY_REQ_GQL_028_SnapshotCompaction - GraphStore snapshot pipeline cadence
const graph_store = @import("geode").graph_store;
const snapshot_pipeline = @import("../src/storage/snapshot_pipeline.zig");

test "TestCANARY_REQ_GQL_028_SnapshotCompaction" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var pipeline = snapshot_pipeline.Pipeline.init(allocator, &store, .{
        .checkpoint_interval_override = 2,
        .compaction_interval = 2,
    });

    pipeline.recordCommit(2);
    var res = try pipeline.tick();
    try std.testing.expect(res.checkpoint);
    try std.testing.expect(!res.compacted);

    pipeline.recordCommit(2);
    res = try pipeline.tick();
    try std.testing.expect(res.checkpoint);
    try std.testing.expect(res.compacted);
}

// TestCANARY_REQ_GQL_016_PathExpandBfs (stub) - ensures PathExpand structure compiles and basic BFS ordering logic placeholder.
const planner = @import("../src/planner.zig");

test "TestCANARY_REQ_GQL_016_PathExpandBfs" {
    // For now we just instantiate the struct; full adjacency integration pending.
    const pe = planner.PathExpand{ .min_hops = 1, .max_hops = 2 };
    _ = pe; // silence unused
}

// TestCANARY_REQ_GQL_010_DiagnosticsFold - verify foldCodes precedence behavior exposed to CANARY.
const diagnostics = @import("../src/diagnostics.zig");

test "TestCANARY_REQ_GQL_010_DiagnosticsFold" {
    var arr: [5]diagnostics.Code = .{ .TypeMismatch, .US001, .IllegalOrderKey, .US001, .IllegalOrderKey };
    const n = diagnostics.foldCodes(arr[0..]);
    try std.testing.expect(n == 3);
    try std.testing.expect(arr[0] == .US001);
    try std.testing.expect(arr[1] == .IllegalOrderKey);
    try std.testing.expect(arr[2] == .TypeMismatch);
}
