// CANARY: REQ=REQ-PERF-QPS-0805; FEATURE="PointReadView"; ASPECT=ZeroCopy; STATUS=TESTED; TEST=tests/test_point_read_view_zero_copy.zig; OWNER=performance; UPDATED=2026-04-19
//
// Regression test for M1.2 (QPS closure plan): PointReadView must not
// invoke the deep-clone path that QueryReadSession.initIfAvailable takes.
// If this test ever fails with a non-zero clone count, the zero-copy
// contract has been broken and the point_read hot path has regressed.

const std = @import("std");
const testing = std.testing;
const graph_store = @import("graph_store");

test "PointReadView does not clone nodes" {
    const allocator = testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    // Start from a known clean slate — other tests in the same test binary
    // may have mutated the process-wide store.
    store.clearNodes();

    const labels = [_][]const u8{"Person"};
    const labels_slice: [][]const u8 = @constCast(&labels);
    _ = try store.createNode(labels_slice);

    graph_store.resetQueryReadSessionInitCount();
    var view = try graph_store.PointReadView.init(&store);
    defer view.deinit();

    // The whole point: acquiring the view did NOT go through the
    // QueryReadSession deep-clone path.
    try testing.expectEqual(@as(u64, 0), graph_store.getQueryReadSessionInitCount());

    // The view still exposes the nodes without cloning their properties.
    const ids = try view.getAllNodes(allocator);
    defer allocator.free(ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
}
