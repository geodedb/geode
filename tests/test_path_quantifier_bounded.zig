const std = @import("std");
const planner = @import("../src/planner.zig");

// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=PathQuantifierBoundedExecution; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_016_PathQuantifierBoundedExecution; OWNER=planner; UPDATED=2026-11-14
// CANARY: REQ=REQ-GQL-016; FEATURE="Path Cycle Determinism"; ASPECT=PathTieBreakMultiBranchDeterminism; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_016_PathTieBreakMultiBranchDeterminism; OWNER=planner; UPDATED=2026-11-14

fn buildLinearGraph(allocator: std.mem.Allocator, n: usize) !planner.AdjacencyList {
    var adj = planner.AdjacencyList.init(allocator);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        try adj.addEdge(@intCast(i), @intCast(i + 1), @intCast(10_000 + i), allocator);
    }
    return adj;
}

test "TestCANARY_REQ_GQL_016_PathQuantifierBoundedExecution" {
    const allocator = std.testing.allocator;
    var adj = try buildLinearGraph(allocator, 6); // nodes 1..6 as a chain
    defer adj.deinit(allocator);
    const expand = planner.PathExpand{ .min_hops = 2, .max_hops = 3 };
    const start = [_]u64{1};
    const results = try expand.execute(start[0..], &adj, allocator);
    defer {
        for (results) |r| allocator.free(r.edge_ids);
        allocator.free(results);
    }
    // Should include paths of length 2 and 3 from node 1
    var count_len2: usize = 0;
    var count_len3: usize = 0;
    for (results) |r| switch (r.path_length) {
        2 => count_len2 += 1,
        3 => count_len3 += 1,
        else => return error.UnexpectedPathLength,
    };
    try std.testing.expect(count_len2 > 0 and count_len3 > 0);
}

test "TestCANARY_REQ_GQL_016_PathTieBreakMultiBranchDeterminism" {
    const allocator = std.testing.allocator;
    // Create a small branching graph:
    // 1 -> 2, 1 -> 3, 2 -> 4, 3 -> 5 (all single hop options ensure same length)
    var adj = planner.AdjacencyList.init(allocator);
    defer adj.deinit(allocator);
    try adj.addEdge(1, 2, 100, allocator);
    try adj.addEdge(1, 3, 101, allocator);
    try adj.addEdge(2, 4, 102, allocator);
    try adj.addEdge(3, 5, 103, allocator);
    const expand = planner.PathExpand{ .min_hops = 1, .max_hops = 2 };
    const start = [_]u64{1};
    const results1 = try expand.execute(start[0..], &adj, allocator);
    defer {
        for (results1) |r| allocator.free(r.edge_ids);
        allocator.free(results1);
    }
    // Re-run and ensure identical ordering
    const results2 = try expand.execute(start[0..], &adj, allocator);
    defer {
        for (results2) |r| allocator.free(r.edge_ids);
        allocator.free(results2);
    }
    try std.testing.expect(results1.len == results2.len);
    var i: usize = 0;
    while (i < results1.len) : (i += 1) {
        try std.testing.expect(results1[i].start_id == results2[i].start_id);
        try std.testing.expect(results1[i].end_id == results2[i].end_id);
        try std.testing.expect(results1[i].path_length == results2[i].path_length);
    }
}
