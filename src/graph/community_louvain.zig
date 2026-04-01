const std = @import("std");

/// GAP-0078: Louvain community detection algorithm with modularity optimization
// CANARY: REQ=REQ-GRAPH-LOUVAIN-001; FEATURE="LouvainCommunityDetection"; ASPECT=GraphAnalytics; STATUS=TESTED; TEST=src/graph/community_louvain.zig; OWNER=graph; UPDATED=2026-01-25
///
/// The Louvain algorithm optimizes modularity in two alternating phases:
/// 1. Local optimization: Each node moves to neighboring community that maximizes modularity gain
/// 2. Aggregation: Communities become super-nodes in a new condensed graph
/// Reference: Blondel et al., "Fast unfolding of communities in large networks" (2008)
pub fn detect(allocator: std.mem.Allocator, graph: [][]u64, resolution: f64, tolerance: f64) ![]u64 {
    const n = graph.len;
    if (n == 0) return &[_]u64{};

    // Initialize each node in its own community
    var communities = try allocator.alloc(u64, n);
    for (communities, 0..) |*comm, i| {
        comm.* = @intCast(i);
    }

    // Compute total edge weight (2*m for undirected)
    var total_weight: f64 = 0;
    for (graph) |neighbors| {
        total_weight += @floatFromInt(neighbors.len);
    }
    if (total_weight == 0) return communities;

    // Node degrees (k_i)
    var degrees = try allocator.alloc(f64, n);
    defer allocator.free(degrees);
    for (graph, 0..) |neighbors, i| {
        degrees[i] = @floatFromInt(neighbors.len);
    }

    // Community internal weights and total weights
    var comm_tot = try allocator.alloc(f64, n);
    defer allocator.free(comm_tot);
    for (0..n) |i| {
        comm_tot[i] = degrees[i];
    }

    var improved = true;
    var iterations: usize = 0;
    const max_iterations: usize = 100;

    // Phase 1: Local modularity optimization
    while (improved and iterations < max_iterations) {
        improved = false;
        iterations += 1;

        for (0..n) |i| {
            const current_comm = communities[i];
            const ki = degrees[i];

            // Calculate weights to neighboring communities
            var neighbor_comms = std.AutoHashMap(u64, f64).init(allocator);
            defer neighbor_comms.deinit();

            for (graph[i]) |neighbor| {
                const neighbor_comm = communities[neighbor];
                const entry = neighbor_comms.getOrPutValue(neighbor_comm, 0) catch continue;
                entry.value_ptr.* += 1.0; // Edge weight = 1 for unweighted
            }

            // Weight to current community
            const ki_in = neighbor_comms.get(current_comm) orelse 0;

            // Try moving to each neighboring community
            var best_comm = current_comm;
            var best_gain: f64 = 0;

            var comm_iter = neighbor_comms.iterator();
            while (comm_iter.next()) |entry| {
                const target_comm = entry.key_ptr.*;
                if (target_comm == current_comm) continue;

                const kj_in = entry.value_ptr.*;

                // Calculate modularity gain for moving node i from current_comm to target_comm
                // ΔQ = [kj_in - ki_in - resolution * ki * (Σtot_target - Σtot_current + ki) / (2m)]
                const sigma_tot_current = comm_tot[current_comm];
                const sigma_tot_target = comm_tot[target_comm];

                const delta_q = (kj_in - ki_in) / total_weight -
                    resolution * ki * (sigma_tot_target - sigma_tot_current + ki) / (total_weight * total_weight);

                if (delta_q > best_gain + tolerance) {
                    best_gain = delta_q;
                    best_comm = target_comm;
                }
            }

            // Move node if beneficial
            if (best_comm != current_comm and best_gain > tolerance) {
                // Update community totals
                comm_tot[current_comm] -= ki;
                comm_tot[best_comm] += ki;
                communities[i] = best_comm;
                improved = true;
            }
        }
    }

    // Renumber communities to be contiguous (0, 1, 2, ...)
    var comm_map = std.AutoHashMap(u64, u64).init(allocator);
    defer comm_map.deinit();
    var next_id: u64 = 0;

    for (communities) |comm| {
        if (!comm_map.contains(comm)) {
            comm_map.put(comm, next_id) catch continue;
            next_id += 1;
        }
    }

    // Apply renumbering
    for (communities) |*comm| {
        comm.* = comm_map.get(comm.*) orelse comm.*;
    }

    return communities;
}

/// GAP-0078: Calculate modularity score for a given community assignment
// CANARY: REQ=REQ-GRAPH-LOUVAIN-002; FEATURE="ModularityScore"; ASPECT=GraphAnalytics; STATUS=TESTED; TEST=src/graph/community_louvain.zig; OWNER=graph; UPDATED=2026-01-25
pub fn modularity(graph: [][]u64, communities: []u64, resolution: f64) f64 {
    const n = graph.len;
    if (n == 0 or communities.len != n) return 0;

    // Total edge weight
    var total_weight: f64 = 0;
    for (graph) |neighbors| {
        total_weight += @floatFromInt(neighbors.len);
    }
    if (total_weight == 0) return 0;

    var q: f64 = 0;

    // For each edge, add contribution if both endpoints in same community
    for (graph, 0..) |neighbors, i| {
        const ki = @as(f64, @floatFromInt(neighbors.len));
        const ci = communities[i];

        for (neighbors) |j| {
            if (communities[j] == ci) {
                // A_ij = 1 (edge exists)
                const kj = @as(f64, @floatFromInt(graph[j].len));
                q += 1.0 - resolution * ki * kj / total_weight;
            }
        }
    }

    return q / total_weight;
}

test "Louvain detects simple community structure" {
    const allocator = std.testing.allocator;

    // Simple test graph with two obvious communities:
    // 0-1-2 (clique 1), 3-4-5 (clique 2), connected by edge 2-3
    var graph_data = [_][]u64{
        &[_]u64{ 1, 2 }, // 0: connected to 1, 2
        &[_]u64{ 0, 2 }, // 1: connected to 0, 2
        &[_]u64{ 0, 1, 3 }, // 2: connected to 0, 1, 3 (bridge)
        &[_]u64{ 2, 4, 5 }, // 3: connected to 2, 4, 5 (bridge)
        &[_]u64{ 3, 5 }, // 4: connected to 3, 5
        &[_]u64{ 3, 4 }, // 5: connected to 3, 4
    };

    const communities = try detect(allocator, &graph_data, 1.0, 0.0001);
    defer allocator.free(communities);

    // Check that nodes 0, 1, 2 are in one community
    // and nodes 3, 4, 5 are in another
    try std.testing.expect(communities[0] == communities[1]);
    try std.testing.expect(communities[1] == communities[2]);
    try std.testing.expect(communities[3] == communities[4]);
    try std.testing.expect(communities[4] == communities[5]);
    try std.testing.expect(communities[0] != communities[3]);

    // Calculate modularity - should be positive for good partition
    const q = modularity(&graph_data, communities, 1.0);
    try std.testing.expect(q > 0);

    std.debug.print("Louvain test: communities={any}, modularity={d:.4}\n", .{ communities, q });
}
