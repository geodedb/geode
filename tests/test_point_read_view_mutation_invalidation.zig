// CANARY: REQ=REQ-PERF-QPS-0805; FEATURE="PointReadView"; ASPECT=StaleDetection; STATUS=TESTED; TEST=tests/test_point_read_view_mutation_invalidation.zig; OWNER=performance; UPDATED=2026-04-19
//
// Regression test for M1.2 (QPS closure plan): PointReadView.isStale()
// must flip to true whenever a mutation lands after the view was
// acquired. Callers that observe isStale()==true must fall back to
// QueryReadSession for correctness — if this test ever regresses, the
// caller would silently read stale data.

const std = @import("std");
const testing = std.testing;
const graph_store = @import("graph_store");

test "PointReadView.isStale flips true after a mutation" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    store.clearNodes();

    const labels = [_][]const u8{"Person"};
    const labels_slice: [][]const u8 = @constCast(&labels);
    _ = try store.createNode(labels_slice);

    var view = try graph_store.PointReadView.init(&store);
    defer view.deinit();
    try testing.expect(!view.isStale());

    // A subsequent write bumps the mutation epoch via incrementMutationEpoch()
    // inside createNodeWithGraphAndTenant, so the view must observe drift.
    _ = try store.createNode(labels_slice);
    try testing.expect(view.isStale());
}
