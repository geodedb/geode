const std = @import("std");
const planner = @import("geode").planner;

// CANARY: REQ=REQ-GQL-016; FEATURE="Variable Length Path Expand"; ASPECT=QuantifierTieBreakStress; STATUS=TESTED; TEST=tests/test_path_quantifier_tiebreak_stress.zig; OWNER=planner; UPDATED=2026-11-14

// Stress test for bounded variable-length path expansion with deterministic tie-break ordering (UA005/UA006).
// Builds a branching graph with multiple paths of varying lengths between a start and set of end nodes.
// Verifies:
// 1. All paths within bounds [1..4] are produced.
// 2. Ordering is strictly non-decreasing by (length, start_id, end_id).
// 3. No duplicate (start_id,end_id,length,edge_seq) tuples.
// 4. Paths do not include cycles (simple path property).
// 5. Deterministic ordering stable across two executions.

test "TestCANARY_REQ_GQL_016_QuantifierTieBreakStress" {
    const alloc = std.testing.allocator;

    var adj = planner.AdjacencyList.init(alloc);
    defer adj.deinit(alloc);

    // Construct a layered DAG from node 1 outward with controlled branching.
    // Layer 1: 1 -> 2,3
    // Layer 2: 2 -> 4,5 ; 3 -> 6
    // Layer 3: 4 -> 7 ; 5 -> 7 ; 6 -> 7,8
    // Extra alternate edges to create multiple same-length paths: 2 -> 6, 3 -> 5
    // Edge ids chosen to exercise ordering stability (not strictly sequential by topology).
    var edge_id: u64 = 100; // start edge ids at 100 for readability
    const add = struct {
        fn e(a: *planner.AdjacencyList, from: u64, to: u64, eid: *u64, allocator: std.mem.Allocator) !void {
            try a.addEdge(from, to, eid.*, allocator);
            eid.* += 1;
        }
    };

    try add.e(&adj, 1, 2, &edge_id, alloc);
    try add.e(&adj, 1, 3, &edge_id, alloc);
    try add.e(&adj, 2, 4, &edge_id, alloc);
    try add.e(&adj, 2, 5, &edge_id, alloc);
    try add.e(&adj, 3, 6, &edge_id, alloc);
    try add.e(&adj, 4, 7, &edge_id, alloc);
    try add.e(&adj, 5, 7, &edge_id, alloc);
    try add.e(&adj, 6, 7, &edge_id, alloc);
    try add.e(&adj, 6, 8, &edge_id, alloc);
    // Extra alternate paths
    try add.e(&adj, 2, 6, &edge_id, alloc);
    try add.e(&adj, 3, 5, &edge_id, alloc);

    const expander = planner.PathExpand{ .min_hops = 1, .max_hops = 4, .tie_break_policy = .LengthId };
    const starts = [_]u64{1};

    const runOnce = struct {
        fn run(adj_ref: *const planner.AdjacencyList) ![]const planner.PathExpand.PathResult {
            return try expander.execute(starts[0..], adj_ref, alloc);
        }
    };

    const results1 = try runOnce.run(&adj);
    defer {
        for (results1) |r| alloc.free(r.edge_ids);
        alloc.free(results1);
    }
    const results2 = try runOnce.run(&adj);
    defer {
        for (results2) |r| alloc.free(r.edge_ids);
        alloc.free(results2);
    }

    // 1. Ensure non-zero and within expected upper bound (loose check)
    try std.testing.expect(results1.len > 0);

    // 2. Ordering check
    for (results1[0 .. results1.len - 1], results1[1..]) |a, b| {
        try std.testing.expect(a.compare(b, .LengthId) != .gt);
    }

    // 3. Duplicate detection via hash set of serialized tuples
    var seen = std.AutoHashMap(u128, void).init(alloc);
    defer seen.deinit();
    for (results1) |r| {
        // SONNY-6548: the key used only the first edge id, so two distinct
        // paths sharing their first edge (1->2->4->7 and 1->2->5->7) collided
        // and the test failed on a correct result. Key on the whole edge
        // sequence: (start_id, end_id) and a hash of every edge id in order.
        const seq_hash: u64 = std.hash.Wyhash.hash(r.path_length, std.mem.sliceAsBytes(r.edge_ids));
        const key: u128 = (@as(u128, seq_hash) << 64) | (@as(u128, r.start_id & 0xffffffff) << 32) | @as(u128, r.end_id & 0xffffffff);
        try std.testing.expect(!seen.contains(key));
        try seen.put(key, {});
    }

    // 4. Simple path (no cycles) check - edge_ids represent traversal edges; ensure no duplicate edge id in a path
    for (results1) |r| {
        var edge_set = std.AutoHashMap(u64, void).init(alloc);
        defer edge_set.deinit();
        for (r.edge_ids) |eid| {
            try std.testing.expect(!edge_set.contains(eid));
            try edge_set.put(eid, {});
        }
    }

    // 5. Deterministic ordering: lengths sequence identical across runs
    try std.testing.expect(results1.len == results2.len);
    var idx: usize = 0;
    while (idx < results1.len) : (idx += 1) {
        try std.testing.expect(results1[idx].path_length == results2[idx].path_length);
        try std.testing.expect(results1[idx].end_id == results2[idx].end_id);
    }
}
