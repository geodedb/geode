const std = @import("std");
const planner = @import("geode").planner;

// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=PathMultiBranchDeterminism; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_016_PathMultiBranchDeterminism; OWNER=planner; UPDATED=2025-09-21

// Additional multi-branch determinism test introducing multiple start nodes and deeper branching
// to further validate UA005/UA006 ordering invariants across simultaneous expansions.
// Graph pattern (multiple starts 1 and 9):
// 1 -> 2,3,4
// 2 -> 5,6 ; 3 -> 6,7 ; 4 -> 7,8
// 5 -> 10 ; 6 -> 10,11 ; 7 -> 11 ; 8 -> 11
// 9 -> 3,4 (alternate start feeding into mid layer)
// Extra cross edges to create path count explosion while keeping max hops bound manageable:
// 2 -> 7, 3 -> 5, 4 -> 6
// Bound: hops [1..5]

fn addEdge(adj: *planner.AdjacencyList, from: u64, to: u64, eid: *u64, allocator: std.mem.Allocator) !void {
    try adj.addEdge(from, to, eid.*, allocator);
    eid.* += 1;
}

test "TestCANARY_REQ_GQL_016_PathMultiBranchDeterminism" {
    const allocator = std.testing.allocator;
    var adj = planner.AdjacencyList.init(allocator);
    defer adj.deinit(allocator);

    var eid: u64 = 500;
    // Primary branches
    try addEdge(&adj, 1, 2, &eid, allocator);
    try addEdge(&adj, 1, 3, &eid, allocator);
    try addEdge(&adj, 1, 4, &eid, allocator);
    try addEdge(&adj, 2, 5, &eid, allocator);
    try addEdge(&adj, 2, 6, &eid, allocator);
    try addEdge(&adj, 3, 6, &eid, allocator);
    try addEdge(&adj, 3, 7, &eid, allocator);
    try addEdge(&adj, 4, 7, &eid, allocator);
    try addEdge(&adj, 4, 8, &eid, allocator);
    try addEdge(&adj, 5, 10, &eid, allocator);
    try addEdge(&adj, 6, 10, &eid, allocator);
    try addEdge(&adj, 6, 11, &eid, allocator);
    try addEdge(&adj, 7, 11, &eid, allocator);
    try addEdge(&adj, 8, 11, &eid, allocator);
    try addEdge(&adj, 9, 3, &eid, allocator);
    try addEdge(&adj, 9, 4, &eid, allocator);
    // Cross edges
    try addEdge(&adj, 2, 7, &eid, allocator);
    try addEdge(&adj, 3, 5, &eid, allocator);
    try addEdge(&adj, 4, 6, &eid, allocator);

    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 5, .tie_break_policy = .LengthId };
    const starts = [_]u64{ 1, 9 };

    const run = struct {
        fn once(a: *const planner.AdjacencyList) ![]const planner.PathExpand.PathResult {
            return try expander.execute(starts[0..], a, allocator);
        }
    };

    const r1 = try run.once(&adj);
    defer {
        for (r1) |p| allocator.free(p.edge_ids);
        allocator.free(r1);
    }
    const r2 = try run.once(&adj);
    defer {
        for (r2) |p| allocator.free(p.edge_ids);
        allocator.free(r2);
    }

    try std.testing.expect(r1.len > 0);
    // Ordering monotonic check
    for (r1[0 .. r1.len - 1], r1[1..]) |a, b| {
        try std.testing.expect(a.compare(b, .LengthId) != .gt);
    }
    // Determinism check across runs (length/end_id equality)
    try std.testing.expect(r1.len == r2.len);
    var i: usize = 0;
    while (i < r1.len) : (i += 1) {
        try std.testing.expect(r1[i].path_length == r2[i].path_length);
        try std.testing.expect(r1[i].end_id == r2[i].end_id);
    }
}
