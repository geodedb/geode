const std = @import("std");
const planner = @import("../src/planner.zig");

// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=PathCycleStressDeterminism; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_016_PathCycleStressDeterminism; OWNER=planner; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=PathZeroLengthInclusionPolicy; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_016_PathZeroLengthInclusionPolicy; OWNER=planner; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=PathHighBranchDeterminism; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_016_PathHighBranchDeterminism; OWNER=planner; UPDATED=2026-11-14

fn buildCycleGraph(allocator: std.mem.Allocator) !planner.AdjacencyList {
    // Graph with overlapping cycles to stress ordering:
    // 1->2,2->3,3->1 (cycle A); 2->4,4->2 (cycle B); 3->5,5->3 (cycle C)
    var adj = planner.AdjacencyList.init(allocator);
    try adj.addEdge(1, 2, 200, allocator);
    try adj.addEdge(2, 3, 201, allocator);
    try adj.addEdge(3, 1, 202, allocator);
    try adj.addEdge(2, 4, 203, allocator);
    try adj.addEdge(4, 2, 204, allocator);
    try adj.addEdge(3, 5, 205, allocator);
    try adj.addEdge(5, 3, 206, allocator);
    return adj;
}

fn buildHighBranchGraph(allocator: std.mem.Allocator, width: u32) !planner.AdjacencyList {
    // Star from 1 to many leaves plus a second layer to create broader breadth ordering
    var adj = planner.AdjacencyList.init(allocator);
    var i: u32 = 0;
    while (i < width) : (i += 1) {
        const leaf = 10 + i;
        try adj.addEdge(1, leaf, 300 + leaf, allocator);
        // Add a chain from each leaf to a unique child to increase paths at hop=2
        try adj.addEdge(leaf, 100 + leaf, 400 + leaf, allocator);
    }
    return adj;
}

test "TestCANARY_REQ_GQL_016_PathCycleStressDeterminism" {
    const allocator = std.testing.allocator;
    var adj = try buildCycleGraph(allocator);
    defer adj.deinit(allocator);
    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 3, .tie_break_policy = .LengthId };
    const start = [_]u64{1};
    const r1 = try expander.execute(start[0..], &adj, allocator);
    defer {
        for (r1) |p| allocator.free(p.edge_ids);
        allocator.free(r1);
    }
    const r2 = try expander.execute(start[0..], &adj, allocator);
    defer {
        for (r2) |p| allocator.free(p.edge_ids);
        allocator.free(r2);
    }
    try std.testing.expect(r1.len == r2.len);
    var i: usize = 0;
    while (i < r1.len) : (i += 1) {
        try std.testing.expect(r1[i].start_id == r2[i].start_id);
        try std.testing.expect(r1[i].end_id == r2[i].end_id);
        try std.testing.expect(r1[i].path_length == r2[i].path_length);
    }
}

test "TestCANARY_REQ_GQL_016_PathZeroLengthInclusionPolicy" {
    // Policy: zero-length paths (start==end with length 0) are NOT included even when min_hops=0 (implementation-defined) — verify none appear.
    const allocator = std.testing.allocator;
    var adj = try buildCycleGraph(allocator);
    defer adj.deinit(allocator);
    const expander = planner.PathExpand{ .min_hops = 0, .max_hops = 2, .tie_break_policy = .LengthId };
    const start = [_]u64{1};
    const res = try expander.execute(start[0..], &adj, allocator);
    defer {
        for (res) |p| allocator.free(p.edge_ids);
        allocator.free(res);
    }
    // Expect all path_length >= 1 (zero-length excluded)
    for (res) |p| try std.testing.expect(p.path_length >= 1);
}

test "TestCANARY_REQ_GQL_016_PathHighBranchDeterminism" {
    const allocator = std.testing.allocator;
    var adj = try buildHighBranchGraph(allocator, 8); // width 8
    defer adj.deinit(allocator);
    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 2, .tie_break_policy = .LengthId };
    const start = [_]u64{1};
    const first = try expander.execute(start[0..], &adj, allocator);
    defer {
        for (first) |p| allocator.free(p.edge_ids);
        allocator.free(first);
    }
    const second = try expander.execute(start[0..], &adj, allocator);
    defer {
        for (second) |p| allocator.free(p.edge_ids);
        allocator.free(second);
    }
    try std.testing.expect(first.len == second.len);
    var i: usize = 0;
    while (i < first.len) : (i += 1) {
        try std.testing.expect(first[i].end_id == second[i].end_id);
        try std.testing.expect(first[i].path_length == second[i].path_length);
    }
}
