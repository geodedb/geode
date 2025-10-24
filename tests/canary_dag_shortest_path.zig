const std = @import("std");
const dag = @import("../src/graph/shortest_dag_path.zig");

// TestCANARY_REQ_GQL_063_DagShortestPath
test "TestCANARY_REQ_GQL_063_DagShortestPath triangle fan" {
    var g = dag.GraphBuilder.init(std.testing.allocator);
    defer g.deinit();
    // 0->1 (1), 0->2 (5), 1->2 (1) shortest 0->2 should be 0->1->2 cost 2
    try g.addEdge(0, 1, 1);
    try g.addEdge(0, 2, 5);
    try g.addEdge(1, 2, 1);
    const topo = [_]u64{ 0, 1, 2 };
    const res = try dag.DagShortestPath.singleSource(std.testing.allocator, &topo, 0, @ptrCast(&g), dag.GraphBuilder.neighborsCtx);
    defer res.distances.deinit();
    defer res.predecessors.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 2), res.distances.get(2).?, 1e-9);
    try std.testing.expectEqual(@as(u64, 1), res.predecessors.get(2).?);
}
