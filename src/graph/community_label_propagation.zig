const std = @import("std");

// CANARY: REQ=REQ-GQL-065; FEATURE="CommunityDetection"; ASPECT=LabelPropagation; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2025-12-30

/// Label propagation community detection algorithm.
/// Iteratively assigns each node the most frequent label among its neighbors
/// until convergence or max_iterations is reached.
///
/// Parameters:
/// - allocator: Memory allocator for result array
/// - graph: Adjacency list where graph[i] contains neighbor indices of node i
/// - max_iterations: Maximum iterations before stopping (use 0 for unlimited)
///
/// Returns: Array where result[i] = community label of node i
pub fn detect(allocator: std.mem.Allocator, graph: [][]u32, max_iterations: u32) ![]u32 {
    const n = graph.len;
    if (n == 0) return try allocator.alloc(u32, 0);

    // Initialize: each node gets its own unique label
    const labels = try allocator.alloc(u32, n);
    for (labels, 0..) |*label, i| {
        label.* = @intCast(i);
    }

    // Create a processing order array (shuffled each iteration for asynchronous update)
    const order = try allocator.alloc(usize, n);
    defer allocator.free(order);
    for (order, 0..) |*idx, i| {
        idx.* = i;
    }

    // Label count map for finding most frequent neighbor label
    var label_counts = std.AutoHashMap(u32, u32).init(allocator);
    defer label_counts.deinit();

    // Use deterministic seed for reproducibility
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var iteration: u32 = 0;
    const effective_max = if (max_iterations == 0) std.math.maxInt(u32) else max_iterations;

    while (iteration < effective_max) : (iteration += 1) {
        var changed = false;

        // Shuffle processing order for asynchronous update semantics
        random.shuffle(usize, order);

        for (order) |node_idx| {
            const neighbors = graph[node_idx];
            if (neighbors.len == 0) continue; // Isolated node keeps its label

            // Count neighbor labels
            label_counts.clearRetainingCapacity();
            for (neighbors) |neighbor| {
                if (neighbor >= n) continue; // Skip invalid neighbor indices
                const neighbor_label = labels[neighbor];
                const gop = try label_counts.getOrPut(neighbor_label);
                if (!gop.found_existing) {
                    gop.value_ptr.* = 1;
                } else {
                    gop.value_ptr.* += 1;
                }
            }

            // Find most frequent label (tie-break: choose smallest label for determinism)
            var best_label: u32 = labels[node_idx];
            var best_count: u32 = 0;

            var it = label_counts.iterator();
            while (it.next()) |entry| {
                const label = entry.key_ptr.*;
                const count = entry.value_ptr.*;
                if (count > best_count or (count == best_count and label < best_label)) {
                    best_count = count;
                    best_label = label;
                }
            }

            // Update label if different
            if (labels[node_idx] != best_label) {
                labels[node_idx] = best_label;
                changed = true;
            }
        }

        // Converged: no labels changed this iteration
        if (!changed) break;
    }

    return labels;
}

/// Returns the number of distinct communities in the label assignment
pub fn countCommunities(labels: []const u32) usize {
    if (labels.len == 0) return 0;

    // Find unique labels
    var seen = std.AutoHashMap(u32, void).init(std.heap.c_allocator);
    defer seen.deinit();

    for (labels) |label| {
        seen.put(label, {}) catch {};
    }

    return seen.count();
}

test "detect - single node" {
    const allocator = std.testing.allocator;
    var graph: [1][]u32 = undefined;
    var n0 = [_]u32{};
    graph[0] = &n0;

    const labels = try detect(allocator, &graph, 10);
    defer allocator.free(labels);

    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectEqual(@as(u32, 0), labels[0]);
}

test "detect - two connected nodes" {
    const allocator = std.testing.allocator;
    var graph: [2][]u32 = undefined;
    var n0 = [_]u32{1};
    var n1 = [_]u32{0};
    graph[0] = &n0;
    graph[1] = &n1;

    const labels = try detect(allocator, &graph, 10);
    defer allocator.free(labels);

    // Both nodes should have same label (converge to same community)
    try std.testing.expectEqual(labels[0], labels[1]);
}

test "detect - disconnected components" {
    const allocator = std.testing.allocator;
    // Two disconnected pairs: 0-1 and 2-3
    var graph: [4][]u32 = undefined;
    var n0 = [_]u32{1};
    var n1 = [_]u32{0};
    var n2 = [_]u32{3};
    var n3 = [_]u32{2};
    graph[0] = &n0;
    graph[1] = &n1;
    graph[2] = &n2;
    graph[3] = &n3;

    const labels = try detect(allocator, &graph, 10);
    defer allocator.free(labels);

    // Nodes 0,1 should be in same community
    try std.testing.expectEqual(labels[0], labels[1]);
    // Nodes 2,3 should be in same community
    try std.testing.expectEqual(labels[2], labels[3]);
    // The two communities should be different
    try std.testing.expect(labels[0] != labels[2]);
}

test "detect - clique" {
    const allocator = std.testing.allocator;
    // Complete graph K4: all nodes connected
    var graph: [4][]u32 = undefined;
    var n0 = [_]u32{ 1, 2, 3 };
    var n1 = [_]u32{ 0, 2, 3 };
    var n2 = [_]u32{ 0, 1, 3 };
    var n3 = [_]u32{ 0, 1, 2 };
    graph[0] = &n0;
    graph[1] = &n1;
    graph[2] = &n2;
    graph[3] = &n3;

    const labels = try detect(allocator, &graph, 10);
    defer allocator.free(labels);

    // All nodes in clique should converge to same community
    try std.testing.expectEqual(labels[0], labels[1]);
    try std.testing.expectEqual(labels[1], labels[2]);
    try std.testing.expectEqual(labels[2], labels[3]);
}

test "detect - empty graph" {
    const allocator = std.testing.allocator;
    var graph: [0][]u32 = .{};

    const labels = try detect(allocator, &graph, 10);
    defer allocator.free(labels);

    try std.testing.expectEqual(@as(usize, 0), labels.len);
}

test "countCommunities" {
    const labels = [_]u32{ 0, 0, 1, 1, 2 };
    try std.testing.expectEqual(@as(usize, 3), countCommunities(&labels));
}
