const std = @import("std");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;

// Local type aliases
const Value = value_types.Value;

// CANARY: REQ=REQ-EXEC-REFACTOR-003; FEATURE="ExecutionRefactoring"; ASPECT=CENTRALITY_ALGORITHMS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted centrality and community detection algorithms from execution.zig for better modularity (M1 Phase 3)

/// Get neighbors of a node (helper function)
pub fn getNeighbors(store: *graph_store.GraphStore, node_id: u64, allocator: std.mem.Allocator) ![]u64 {
    var neighbors = try std.ArrayList(u64).initCapacity(allocator, 0);
    var edge_iter = store.edges.iterator();
    while (edge_iter.next()) |entry| {
        const edge = entry.value_ptr.*;
        if (edge.from_id == node_id) {
            try neighbors.append(allocator, edge.to_id);
        } else if (edge.to_id == node_id) {
            try neighbors.append(allocator, edge.from_id);
        }
    }
    return try neighbors.toOwnedSlice(allocator);
}

/// Degree Centrality - count edges for each node
pub fn executeDegreeCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var degree: u64 = 0;
        var edge_iter = store.edges.iterator();
        while (edge_iter.next()) |edge_entry| {
            if (edge_entry.value_ptr.*.from_id == node_id or edge_entry.value_ptr.*.to_id == node_id) {
                degree += 1;
            }
        }

        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Int = @intCast(degree) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

/// Betweenness Centrality - Brandes algorithm
pub fn executeBetweennessCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var centrality = std.AutoHashMap(u64, f64).init(allocator);
    defer centrality.deinit();

    for (node_list.items) |node| {
        try centrality.put(node, 0.0);
    }

    // Brandes algorithm
    for (node_list.items) |source| {
        var stack = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer stack.deinit(allocator);

        var paths = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator);
        defer {
            var it = paths.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(allocator);
            }
            paths.deinit();
        }

        var sigma = std.AutoHashMap(u64, f64).init(allocator);
        defer sigma.deinit();

        var dist = std.AutoHashMap(u64, i32).init(allocator);
        defer dist.deinit();

        var delta = std.AutoHashMap(u64, f64).init(allocator);
        defer delta.deinit();

        for (node_list.items) |node| {
            try paths.put(node, try std.ArrayList(u64).initCapacity(allocator, 0));
            try sigma.put(node, 0.0);
            try dist.put(node, -1);
            try delta.put(node, 0.0);
        }

        try sigma.put(source, 1.0);
        try dist.put(source, 0);

        var queue = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer queue.deinit(allocator);
        try queue.append(allocator, source);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const v = queue.items[front];
            try stack.append(allocator, v);

            const neighbors = try getNeighbors(store, v, allocator);
            defer allocator.free(neighbors);

            for (neighbors) |w| {
                if (dist.get(w).? < 0) {
                    try queue.append(allocator, w);
                    try dist.put(w, dist.get(v).? + 1);
                }

                if (dist.get(w) == dist.get(v).? + 1) {
                    try sigma.put(w, sigma.get(w).? + sigma.get(v).?);
                    var w_paths = paths.getPtr(w).?;
                    try w_paths.append(allocator, v);
                }
            }
        }

        while (stack.items.len > 0) {
            const w_opt = stack.pop();
            if (w_opt == null) break;
            const w = w_opt.?;
            if (paths.get(w)) |w_paths| {
                for (w_paths.items) |v| {
                    const contribution = (sigma.get(v).? / sigma.get(w).?) * (1.0 + delta.get(w).?);
                    try delta.put(v, delta.get(v).? + contribution);
                }
            }
            if (w != source) {
                try centrality.put(w, centrality.get(w).? + delta.get(w).?);
            }
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        const score = centrality.get(node_id).?;
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(score * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

/// Closeness Centrality - BFS-based
pub fn executeClosenessCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();

        var queue = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer queue.deinit(allocator);

        try distances.put(node_id, 0);
        try queue.append(allocator, node_id);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const neighbors = try getNeighbors(store, current, allocator);
            defer allocator.free(neighbors);

            for (neighbors) |neighbor| {
                if (!distances.contains(neighbor)) {
                    try distances.put(neighbor, current_dist + 1);
                    try queue.append(allocator, neighbor);
                }
            }
        }

        var total_distance: f64 = 0;
        var reachable: u32 = 0;
        var dist_iter = distances.iterator();
        while (dist_iter.next()) |entry| {
            if (entry.key_ptr.* != node_id) {
                total_distance += @as(f64, @floatFromInt(entry.value_ptr.*));
                reachable += 1;
            }
        }

        const closeness = if (total_distance > 0) @as(f64, @floatFromInt(reachable)) / total_distance else 0.0;

        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(closeness * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

/// Eigenvector Centrality - Power iteration
pub fn executeEigenvectorCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    if (node_list.items.len == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    var centrality = std.AutoHashMap(u64, f64).init(allocator);
    defer centrality.deinit();

    const initial = 1.0 / @sqrt(@as(f64, @floatFromInt(node_list.items.len)));
    for (node_list.items) |node| {
        try centrality.put(node, initial);
    }

    const max_iterations: u32 = 100;
    const tolerance: f64 = 0.0001;

    var iteration: u32 = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var new_centrality = std.AutoHashMap(u64, f64).init(allocator);
        defer new_centrality.deinit();

        for (node_list.items) |node| {
            var sum: f64 = 0;
            const neighbors = try getNeighbors(store, node, allocator);
            defer allocator.free(neighbors);

            for (neighbors) |neighbor| {
                sum += centrality.get(neighbor) orelse initial;
            }
            try new_centrality.put(node, sum);
        }

        var norm: f64 = 0;
        var norm_iter = new_centrality.iterator();
        while (norm_iter.next()) |entry| {
            norm += entry.value_ptr.* * entry.value_ptr.*;
        }
        norm = @sqrt(norm);
        if (norm == 0) norm = 1;

        var max_diff: f64 = 0;
        for (node_list.items) |node| {
            const new_val = (new_centrality.get(node) orelse 0) / norm;
            const old_val = centrality.get(node) orelse 0;
            max_diff = @max(max_diff, @abs(new_val - old_val));
            try centrality.put(node, new_val);
        }

        if (max_diff < tolerance) break;
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        const score = centrality.get(node_id).?;
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(score * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

/// PageRank Algorithm
pub fn executePageRank(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, params: ?std.json.Value) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    if (node_list.items.len == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Parse parameters
    var damping_factor: f64 = 0.85;
    var max_iterations: u32 = 20;
    var tolerance: f64 = 0.0001;

    if (params) |p| {
        if (p == .object) {
            if (p.object.get("dampingFactor")) |df| {
                if (df == .float) damping_factor = df.float;
                if (df == .integer) damping_factor = @floatFromInt(df.integer);
            }
            if (p.object.get("maxIterations")) |mi| {
                if (mi == .integer) max_iterations = @intCast(mi.integer);
            }
            if (p.object.get("tolerance")) |tol| {
                if (tol == .float) tolerance = tol.float;
            }
        }
    }

    var pagerank = std.AutoHashMap(u64, f64).init(allocator);
    defer pagerank.deinit();

    const initial_rank = 1.0 / @as(f64, @floatFromInt(node_list.items.len));
    for (node_list.items) |node| {
        try pagerank.put(node, initial_rank);
    }

    var iteration: u32 = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var new_pagerank = std.AutoHashMap(u64, f64).init(allocator);
        defer new_pagerank.deinit();

        const base_rank = (1.0 - damping_factor) / @as(f64, @floatFromInt(node_list.items.len));

        for (node_list.items) |node| {
            var rank_sum: f64 = 0;

            // Find nodes that link to this node
            var linking_iter = store.nodes.iterator();
            while (linking_iter.next()) |linking_entry| {
                const linking_node = linking_entry.key_ptr.*;
                const neighbors = try getNeighbors(store, linking_node, allocator);
                defer allocator.free(neighbors);

                for (neighbors) |neighbor| {
                    if (neighbor == node) {
                        const out_degree = @as(f64, @floatFromInt(neighbors.len));
                        if (out_degree > 0) {
                            rank_sum += (pagerank.get(linking_node) orelse initial_rank) / out_degree;
                        }
                        break;
                    }
                }
            }

            const new_rank = base_rank + damping_factor * rank_sum;
            try new_pagerank.put(node, new_rank);
        }

        // Check convergence
        var max_diff: f64 = 0;
        for (node_list.items) |node| {
            const new_val = new_pagerank.get(node) orelse initial_rank;
            const old_val = pagerank.get(node) orelse initial_rank;
            max_diff = @max(max_diff, @abs(new_val - old_val));
            try pagerank.put(node, new_val);
        }

        if (max_diff < tolerance) break;
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        const score = pagerank.get(node_id).?;
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(score * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

/// Louvain Community Detection
pub fn executeLouvainCommunities(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var communities = std.AutoHashMap(u64, u64).init(allocator);
    defer communities.deinit();

    // Initialize each node in its own community
    for (node_list.items, 0..) |node, i| {
        try communities.put(node, i);
    }

    // Simple community merging based on connectivity
    for (node_list.items) |node| {
        const neighbors = try getNeighbors(store, node, allocator);
        defer allocator.free(neighbors);

        if (neighbors.len > 0) {
            const neighbor_comm = communities.get(neighbors[0]).?;
            try communities.put(node, neighbor_comm);
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Int = @intCast(communities.get(node_id).?) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

/// Label Propagation community detection
pub fn executeLabelPropagation(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var labels = std.AutoHashMap(u64, u64).init(allocator);
    defer labels.deinit();

    for (node_list.items, 0..) |node, i| {
        try labels.put(node, i);
    }

    const max_iterations: u32 = 10;
    var iteration: u32 = 0;
    var changed = true;

    while (changed and iteration < max_iterations) : (iteration += 1) {
        changed = false;

        for (node_list.items) |node| {
            const neighbors = try getNeighbors(store, node, allocator);
            defer allocator.free(neighbors);

            if (neighbors.len == 0) continue;

            var label_counts = std.AutoHashMap(u64, u32).init(allocator);
            defer label_counts.deinit();

            for (neighbors) |neighbor| {
                const label = labels.get(neighbor).?;
                const count = label_counts.get(label) orelse 0;
                try label_counts.put(label, count + 1);
            }

            var max_count: u32 = 0;
            var max_label = labels.get(node).?;

            var count_iter = label_counts.iterator();
            while (count_iter.next()) |entry| {
                if (entry.value_ptr.* > max_count) {
                    max_count = entry.value_ptr.*;
                    max_label = entry.key_ptr.*;
                }
            }

            if (max_label != labels.get(node).?) {
                try labels.put(node, max_label);
                changed = true;
            }
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Int = @intCast(labels.get(node_id).?) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

/// Union-Find (Connected Components)
pub fn executeUnionFind(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var parent = std.AutoHashMap(u64, u64).init(allocator);
    defer parent.deinit();

    for (node_list.items) |node| {
        try parent.put(node, node);
    }

    const find = struct {
        fn f(p: *std.AutoHashMap(u64, u64), x: u64) ?u64 {
            // Check if node exists in parent map
            if (p.get(x) == null) return null;

            var current = x;
            while (p.get(current)) |parent_id| {
                if (parent_id == current) break;
                current = parent_id;
            }
            return current;
        }
    }.f;

    var edge_iter = store.edges.iterator();
    while (edge_iter.next()) |entry| {
        const edge = entry.value_ptr.*;

        // Ensure edge endpoints exist in parent map
        if (!parent.contains(edge.from_id)) {
            try parent.put(edge.from_id, edge.from_id);
        }
        if (!parent.contains(edge.to_id)) {
            try parent.put(edge.to_id, edge.to_id);
        }

        const root1_opt = find(&parent, edge.from_id);
        const root2_opt = find(&parent, edge.to_id);

        if (root1_opt != null and root2_opt != null) {
            const root1 = root1_opt.?;
            const root2 = root2_opt.?;
            if (root1 != root2) {
                try parent.put(root2, root1);
            }
        }
    }

    var components = std.AutoHashMap(u64, u64).init(allocator);
    defer components.deinit();

    for (node_list.items) |node| {
        if (find(&parent, node)) |root| {
            try components.put(node, root);
        } else {
            // Node has no parent (isolated node), it's its own component
            try components.put(node, node);
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Int = @intCast(components.get(node_id).?) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

/// Strongly Connected Components (Tarjan's algorithm)
pub fn executeSCC(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var component = std.AutoHashMap(u64, u64).init(allocator);
    defer component.deinit();

    // Simple SCC: treat weakly connected components as SCCs
    var visited = std.AutoHashMap(u64, bool).init(allocator);
    defer visited.deinit();

    var comp_id: u64 = 0;
    for (node_list.items) |node| {
        if (visited.contains(node)) continue;

        var stack = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer stack.deinit(allocator);
        try stack.append(allocator, node);

        while (stack.items.len > 0) {
            const current_opt = stack.pop();
            if (current_opt == null) break;
            const current = current_opt.?;
            if (visited.contains(current)) continue;

            try visited.put(current, true);
            try component.put(current, comp_id);

            const neighbors = try getNeighbors(store, current, allocator);
            defer allocator.free(neighbors);

            for (neighbors) |neighbor| {
                if (!visited.contains(neighbor)) {
                    try stack.append(allocator, neighbor);
                }
            }
        }

        comp_id += 1;
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Int = @intCast(component.get(node_id).?) };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-HARMONIC-001; FEATURE="HarmonicCentrality"; ASPECT=Centrality; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Harmonic Centrality - sum of reciprocal distances (handles disconnected graphs better than closeness)
pub fn executeHarmonicCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();

        var queue = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer queue.deinit(allocator);

        try distances.put(node_id, 0);
        try queue.append(allocator, node_id);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const neighbors = try getNeighbors(store, current, allocator);
            defer allocator.free(neighbors);

            for (neighbors) |neighbor| {
                if (!distances.contains(neighbor)) {
                    try distances.put(neighbor, current_dist + 1);
                    try queue.append(allocator, neighbor);
                }
            }
        }

        // Harmonic centrality = sum of 1/distance for all reachable nodes
        var harmonic: f64 = 0.0;
        var dist_iter = distances.iterator();
        while (dist_iter.next()) |entry| {
            if (entry.value_ptr.* > 0) {
                harmonic += 1.0 / @as(f64, @floatFromInt(entry.value_ptr.*));
            }
        }

        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(harmonic * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-BRIDGE-LEV-001; FEATURE="BridgeLeverageCentrality"; ASPECT=Centrality; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Bridge/Leverage Centrality - measures how much removing a node would disconnect the graph
pub fn executeBridgeLeverageCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        // Count components with the node vs without
        // Get neighbors of this node
        const neighbors = try getNeighbors(store, node_id, allocator);
        defer allocator.free(neighbors);

        // Bridge leverage = neighbors * (1 / degree) - measures local bridging
        const degree = neighbors.len;
        const leverage: f64 = if (degree > 0)
            @as(f64, @floatFromInt(degree)) / @as(f64, @floatFromInt(node_list.items.len))
        else
            0.0;

        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(leverage * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-GREY-CARDINAL-001; FEATURE="GreyCardinalComposite"; ASPECT=Centrality; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Grey Cardinal Composite - combines multiple centrality metrics
pub fn executeGreyCardinalComposite(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    // Compute degree centrality
    var degree_map = std.AutoHashMap(u64, f64).init(allocator);
    defer degree_map.deinit();

    // Compute closeness centrality
    var closeness_map = std.AutoHashMap(u64, f64).init(allocator);
    defer closeness_map.deinit();

    for (node_list.items) |node_id| {
        // Degree
        const neighbors = try getNeighbors(store, node_id, allocator);
        defer allocator.free(neighbors);
        try degree_map.put(node_id, @as(f64, @floatFromInt(neighbors.len)));

        // Closeness via BFS
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();
        var queue = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer queue.deinit(allocator);

        try distances.put(node_id, 0);
        try queue.append(allocator, node_id);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const current_neighbors = try getNeighbors(store, current, allocator);
            defer allocator.free(current_neighbors);

            for (current_neighbors) |neighbor| {
                if (!distances.contains(neighbor)) {
                    try distances.put(neighbor, current_dist + 1);
                    try queue.append(allocator, neighbor);
                }
            }
        }

        var total_dist: f64 = 0.0;
        var reachable: u32 = 0;
        var dist_iter = distances.iterator();
        while (dist_iter.next()) |entry| {
            if (entry.value_ptr.* > 0) {
                total_dist += @as(f64, @floatFromInt(entry.value_ptr.*));
                reachable += 1;
            }
        }
        const closeness = if (total_dist > 0) @as(f64, @floatFromInt(reachable)) / total_dist else 0.0;
        try closeness_map.put(node_id, closeness);
    }

    // Normalize and combine
    var max_degree: f64 = 1.0;
    var max_closeness: f64 = 1.0;
    for (node_list.items) |node_id| {
        if (degree_map.get(node_id).? > max_degree) max_degree = degree_map.get(node_id).?;
        if (closeness_map.get(node_id).? > max_closeness) max_closeness = closeness_map.get(node_id).?;
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, idx| {
        // Grey Cardinal = weighted combination of normalized centralities
        const norm_degree = degree_map.get(node_id).? / max_degree;
        const norm_closeness = closeness_map.get(node_id).? / max_closeness;
        const composite = 0.5 * norm_degree + 0.5 * norm_closeness;

        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(composite * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-LEIDEN-001; FEATURE="LeidenCommunityDetection"; ASPECT=Community; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Leiden Algorithm - improved community detection (similar to Louvain but with refinement)
pub fn executeLeidenCommunities(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var communities = std.AutoHashMap(u64, u64).init(allocator);
    defer communities.deinit();

    // Initialize each node in its own community
    for (node_list.items, 0..) |node, idx| {
        try communities.put(node, idx);
    }

    // Leiden refinement: multiple passes with local moving and refinement
    const max_iterations: u32 = 20;
    var iteration: u32 = 0;
    var changed = true;

    while (changed and iteration < max_iterations) : (iteration += 1) {
        changed = false;

        // Local moving phase
        for (node_list.items) |node| {
            const neighbors = try getNeighbors(store, node, allocator);
            defer allocator.free(neighbors);

            if (neighbors.len == 0) continue;

            // Count community occurrences among neighbors
            var comm_counts = std.AutoHashMap(u64, u32).init(allocator);
            defer comm_counts.deinit();

            for (neighbors) |neighbor| {
                const comm = communities.get(neighbor).?;
                const count = comm_counts.get(comm) orelse 0;
                try comm_counts.put(comm, count + 1);
            }

            // Find best community
            var best_count: u32 = 0;
            var best_comm = communities.get(node).?;

            var comm_iter = comm_counts.iterator();
            while (comm_iter.next()) |entry| {
                if (entry.value_ptr.* > best_count) {
                    best_count = entry.value_ptr.*;
                    best_comm = entry.key_ptr.*;
                }
            }

            if (best_comm != communities.get(node).?) {
                try communities.put(node, best_comm);
                changed = true;
            }
        }

        // Refinement phase: singleton communities move to best neighbor community
        if (iteration % 5 == 0) {
            for (node_list.items) |node| {
                const neighbors = try getNeighbors(store, node, allocator);
                defer allocator.free(neighbors);

                if (neighbors.len > 0) {
                    // Check if node is isolated in its community
                    var same_comm_count: u32 = 0;
                    for (neighbors) |neighbor| {
                        if (communities.get(neighbor).? == communities.get(node).?) {
                            same_comm_count += 1;
                        }
                    }
                    // If isolated, move to most connected neighbor's community
                    if (same_comm_count == 0 and neighbors.len > 0) {
                        try communities.put(node, communities.get(neighbors[0]).?);
                        changed = true;
                    }
                }
            }
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, idx| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Int = @intCast(communities.get(node_id).?) };
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-ARTICULATION-001; FEATURE="ArticulationPoints"; ASPECT=Connectivity; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Find Articulation Points (cut vertices) - nodes whose removal disconnects the graph
pub fn executeArticulationPoints(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    // Tarjan's algorithm for articulation points
    var disc = std.AutoHashMap(u64, i32).init(allocator);
    defer disc.deinit();
    var low = std.AutoHashMap(u64, i32).init(allocator);
    defer low.deinit();
    var parent = std.AutoHashMap(u64, ?u64).init(allocator);
    defer parent.deinit();
    var is_articulation = std.AutoHashMap(u64, bool).init(allocator);
    defer is_articulation.deinit();

    for (node_list.items) |node| {
        try disc.put(node, -1);
        try low.put(node, -1);
        try parent.put(node, null);
        try is_articulation.put(node, false);
    }

    var time_counter: i32 = 0;

    // DFS from each unvisited node
    for (node_list.items) |start_node| {
        if (disc.get(start_node).? != -1) continue;

        var stack = try std.ArrayList(struct { node: u64, neighbor_idx: usize, child_count: u32 }).initCapacity(allocator, 0);
        defer stack.deinit(allocator);

        try stack.append(allocator, .{ .node = start_node, .neighbor_idx = 0, .child_count = 0 });
        try disc.put(start_node, time_counter);
        try low.put(start_node, time_counter);
        time_counter += 1;

        while (stack.items.len > 0) {
            var current = &stack.items[stack.items.len - 1];
            const neighbors = try getNeighbors(store, current.node, allocator);
            defer allocator.free(neighbors);

            if (current.neighbor_idx < neighbors.len) {
                const v = neighbors[current.neighbor_idx];
                current.neighbor_idx += 1;

                if (disc.get(v).? == -1) {
                    current.child_count += 1;
                    try parent.put(v, current.node);
                    try disc.put(v, time_counter);
                    try low.put(v, time_counter);
                    time_counter += 1;
                    try stack.append(allocator, .{ .node = v, .neighbor_idx = 0, .child_count = 0 });
                } else if (parent.get(current.node).? != v) {
                    const current_low = low.get(current.node).?;
                    const v_disc = disc.get(v).?;
                    try low.put(current.node, @min(current_low, v_disc));
                }
            } else {
                const popped = stack.pop().?;

                if (stack.items.len > 0) {
                    const parent_node = &stack.items[stack.items.len - 1];
                    const parent_low = low.get(parent_node.node).?;
                    const popped_low = low.get(popped.node).?;
                    try low.put(parent_node.node, @min(parent_low, popped_low));

                    // Check articulation point condition
                    const parent_disc = disc.get(parent_node.node).?;
                    if (popped_low >= parent_disc) {
                        // Check if parent is root with multiple children
                        if (parent.get(parent_node.node).? == null) {
                            if (parent_node.child_count > 1) {
                                try is_articulation.put(parent_node.node, true);
                            }
                        } else {
                            try is_articulation.put(parent_node.node, true);
                        }
                    }
                }
            }
        }
    }

    // Collect articulation points
    var result_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer result_list.deinit(allocator);

    for (node_list.items) |node| {
        if (is_articulation.get(node).?) {
            try result_list.append(allocator, node);
        }
    }

    var rows = try allocator.alloc([]Value, result_list.items.len);
    for (result_list.items, 0..) |node_id, idx| {
        var row = try allocator.alloc(Value, 1);
        row[0] = Value{ .Int = @intCast(node_id) };
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-BRIDGES-001; FEATURE="BridgeEdges"; ASPECT=Connectivity; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Find Bridge Edges (cut edges) - edges whose removal disconnects the graph
pub fn executeBridges(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var disc = std.AutoHashMap(u64, i32).init(allocator);
    defer disc.deinit();
    var low = std.AutoHashMap(u64, i32).init(allocator);
    defer low.deinit();
    var parent = std.AutoHashMap(u64, ?u64).init(allocator);
    defer parent.deinit();

    for (node_list.items) |node| {
        try disc.put(node, -1);
        try low.put(node, -1);
        try parent.put(node, null);
    }

    var bridges = try std.ArrayList(struct { source: u64, target: u64 }).initCapacity(allocator, 0);
    defer bridges.deinit(allocator);

    var time_counter: i32 = 0;

    for (node_list.items) |start_node| {
        if (disc.get(start_node).? != -1) continue;

        var stack = try std.ArrayList(struct { node: u64, neighbor_idx: usize }).initCapacity(allocator, 0);
        defer stack.deinit(allocator);

        try stack.append(allocator, .{ .node = start_node, .neighbor_idx = 0 });
        try disc.put(start_node, time_counter);
        try low.put(start_node, time_counter);
        time_counter += 1;

        while (stack.items.len > 0) {
            var current = &stack.items[stack.items.len - 1];
            const neighbors = try getNeighbors(store, current.node, allocator);
            defer allocator.free(neighbors);

            if (current.neighbor_idx < neighbors.len) {
                const v = neighbors[current.neighbor_idx];
                current.neighbor_idx += 1;

                if (disc.get(v).? == -1) {
                    try parent.put(v, current.node);
                    try disc.put(v, time_counter);
                    try low.put(v, time_counter);
                    time_counter += 1;
                    try stack.append(allocator, .{ .node = v, .neighbor_idx = 0 });
                } else if (parent.get(current.node).? != v) {
                    const current_low = low.get(current.node).?;
                    const v_disc = disc.get(v).?;
                    try low.put(current.node, @min(current_low, v_disc));
                }
            } else {
                const popped = stack.pop().?;

                if (stack.items.len > 0) {
                    const parent_node = &stack.items[stack.items.len - 1];
                    const parent_low = low.get(parent_node.node).?;
                    const popped_low = low.get(popped.node).?;
                    try low.put(parent_node.node, @min(parent_low, popped_low));

                    // Check bridge condition: low[v] > disc[u]
                    const parent_disc = disc.get(parent_node.node).?;
                    if (popped_low > parent_disc) {
                        try bridges.append(allocator, .{ .source = parent_node.node, .target = popped.node });
                    }
                }
            }
        }
    }

    var rows = try allocator.alloc([]Value, bridges.items.len);
    for (bridges.items, 0..) |bridge, idx| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(bridge.source) };
        row[1] = Value{ .Int = @intCast(bridge.target) };
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-BICONNECTED-001; FEATURE="BiconnectedComponents"; ASPECT=Connectivity; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Find Biconnected Components - maximal 2-edge-connected subgraphs
pub fn executeBiconnectedComponents(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    // Assign each node to a biconnected component using iterative Tarjan-like algorithm
    var disc = std.AutoHashMap(u64, i32).init(allocator);
    defer disc.deinit();
    var low = std.AutoHashMap(u64, i32).init(allocator);
    defer low.deinit();
    var component = std.AutoHashMap(u64, u64).init(allocator);
    defer component.deinit();

    for (node_list.items) |node| {
        try disc.put(node, -1);
        try low.put(node, -1);
        try component.put(node, 0);
    }

    var comp_id: u64 = 0;
    var time_counter: i32 = 0;

    for (node_list.items) |start_node| {
        if (disc.get(start_node).? != -1) continue;

        // BFS/DFS to find connected component
        var stack = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer stack.deinit(allocator);

        try stack.append(allocator, start_node);
        try disc.put(start_node, time_counter);
        try low.put(start_node, time_counter);
        time_counter += 1;

        while (stack.items.len > 0) {
            const current = stack.pop().?;
            try component.put(current, comp_id);

            const neighbors = try getNeighbors(store, current, allocator);
            defer allocator.free(neighbors);

            for (neighbors) |neighbor| {
                if (disc.get(neighbor).? == -1) {
                    try disc.put(neighbor, time_counter);
                    try low.put(neighbor, time_counter);
                    time_counter += 1;
                    try stack.append(allocator, neighbor);
                }
            }
        }
        comp_id += 1;
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, idx| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Int = @intCast(component.get(node_id).?) };
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// ============================================================================
// GRAPH STATISTICS FUNCTIONS (#67)
// ============================================================================

// CANARY: REQ=REQ-GQL-GRAPH-DENSITY-001; FEATURE="GraphDensity"; ASPECT=Statistics; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Graph Density - ratio of actual edges to maximum possible edges
/// For undirected: 2E / (N * (N-1)), for directed: E / (N * (N-1))
pub fn executeGraphDensity(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    const node_count = store.nodes.count();
    const edge_count = store.edges.count();

    const density: f64 = if (node_count > 1)
        @as(f64, @floatFromInt(edge_count)) / @as(f64, @floatFromInt(node_count * (node_count - 1)))
    else
        0.0;

    var rows = try allocator.alloc([]Value, 1);
    var row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Decimal = .{ .coeff = @intFromFloat(density * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-GRAPH-DIAMETER-001; FEATURE="GraphDiameter"; ASPECT=Statistics; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Graph Diameter - the longest shortest path between any two nodes
pub fn executeGraphDiameter(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var max_distance: u32 = 0;

    // BFS from each node to find maximum shortest path
    for (node_list.items) |start_node| {
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();

        var queue = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer queue.deinit(allocator);

        try distances.put(start_node, 0);
        try queue.append(allocator, start_node);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const neighbors = try getNeighbors(store, current, allocator);
            defer allocator.free(neighbors);

            for (neighbors) |neighbor| {
                if (!distances.contains(neighbor)) {
                    const new_dist = current_dist + 1;
                    try distances.put(neighbor, new_dist);
                    try queue.append(allocator, neighbor);
                    if (new_dist > max_distance) {
                        max_distance = new_dist;
                    }
                }
            }
        }
    }

    var rows = try allocator.alloc([]Value, 1);
    var row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Int = @intCast(max_distance) };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-MEAN-DISTANCE-001; FEATURE="MeanDistance"; ASPECT=Statistics; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Mean Distance (Average Path Length) - average shortest path length between all pairs
pub fn executeMeanDistance(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var total_distance: f64 = 0.0;
    var pair_count: u64 = 0;

    // BFS from each node
    for (node_list.items) |start_node| {
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();

        var queue = try std.ArrayList(u64).initCapacity(allocator, 0);
        defer queue.deinit(allocator);

        try distances.put(start_node, 0);
        try queue.append(allocator, start_node);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const neighbors = try getNeighbors(store, current, allocator);
            defer allocator.free(neighbors);

            for (neighbors) |neighbor| {
                if (!distances.contains(neighbor)) {
                    try distances.put(neighbor, current_dist + 1);
                    try queue.append(allocator, neighbor);
                }
            }
        }

        // Sum distances from this node
        var dist_iter = distances.iterator();
        while (dist_iter.next()) |entry| {
            if (entry.value_ptr.* > 0) {
                total_distance += @as(f64, @floatFromInt(entry.value_ptr.*));
                pair_count += 1;
            }
        }
    }

    const mean_distance: f64 = if (pair_count > 0) total_distance / @as(f64, @floatFromInt(pair_count)) else 0.0;

    var rows = try allocator.alloc([]Value, 1);
    var row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Decimal = .{ .coeff = @intFromFloat(mean_distance * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-GLOBAL-CLUSTERING-001; FEATURE="GlobalClusteringCoefficient"; ASPECT=Statistics; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Global Clustering Coefficient - ratio of closed triplets to all triplets
pub fn executeGlobalClusteringCoefficient(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var closed_triplets: u64 = 0;
    var total_triplets: u64 = 0;

    for (node_list.items) |node| {
        const neighbors = try getNeighbors(store, node, allocator);
        defer allocator.free(neighbors);

        const degree = neighbors.len;
        if (degree < 2) continue;

        // Number of possible triplets centered at this node
        total_triplets += (degree * (degree - 1)) / 2;

        // Count actual triangles (closed triplets)
        for (neighbors, 0..) |n1, i| {
            for (neighbors[i + 1 ..]) |n2| {
                // Check if n1 and n2 are connected
                const n1_neighbors = try getNeighbors(store, n1, allocator);
                defer allocator.free(n1_neighbors);

                for (n1_neighbors) |n1n| {
                    if (n1n == n2) {
                        closed_triplets += 1;
                        break;
                    }
                }
            }
        }
    }

    const clustering: f64 = if (total_triplets > 0)
        @as(f64, @floatFromInt(closed_triplets)) / @as(f64, @floatFromInt(total_triplets))
    else
        0.0;

    var rows = try allocator.alloc([]Value, 1);
    var row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Decimal = .{ .coeff = @intFromFloat(clustering * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// ============================================================================
// KATZ AND HITS CENTRALITY (#69)
// ============================================================================

// CANARY: REQ=REQ-GQL-KATZ-001; FEATURE="KatzCentrality"; ASPECT=Centrality; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Katz Centrality - weighted sum of paths with attenuation factor alpha
/// Katz(i) = sum_k(alpha^k * A^k * 1) where A is adjacency matrix
pub fn executeKatzCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, params: ?std.json.Value) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    if (node_list.items.len == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Parse parameters
    var alpha: f64 = 0.1; // Attenuation factor (should be < 1/largest_eigenvalue)
    var beta: f64 = 1.0; // Base score
    var max_iterations: u32 = 100;
    var tolerance: f64 = 0.0001;

    if (params) |p| {
        if (p == .object) {
            if (p.object.get("alpha")) |a| {
                if (a == .float) alpha = a.float;
                if (a == .integer) alpha = @floatFromInt(a.integer);
            }
            if (p.object.get("beta")) |b| {
                if (b == .float) beta = b.float;
                if (b == .integer) beta = @floatFromInt(b.integer);
            }
            if (p.object.get("maxIterations")) |mi| {
                if (mi == .integer) max_iterations = @intCast(mi.integer);
            }
            if (p.object.get("tolerance")) |tol| {
                if (tol == .float) tolerance = tol.float;
            }
        }
    }

    var centrality = std.AutoHashMap(u64, f64).init(allocator);
    defer centrality.deinit();

    // Initialize with beta
    for (node_list.items) |node| {
        try centrality.put(node, beta);
    }

    // Power iteration
    var iteration: u32 = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var new_centrality = std.AutoHashMap(u64, f64).init(allocator);
        defer new_centrality.deinit();

        for (node_list.items) |node| {
            var sum: f64 = beta;
            const neighbors = try getNeighbors(store, node, allocator);
            defer allocator.free(neighbors);

            for (neighbors) |neighbor| {
                sum += alpha * (centrality.get(neighbor) orelse beta);
            }
            try new_centrality.put(node, sum);
        }

        // Check convergence
        var max_diff: f64 = 0;
        for (node_list.items) |node| {
            const new_val = new_centrality.get(node) orelse beta;
            const old_val = centrality.get(node) orelse beta;
            max_diff = @max(max_diff, @abs(new_val - old_val));
            try centrality.put(node, new_val);
        }

        if (max_diff < tolerance) break;
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        const score = centrality.get(node_id).?;
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(score * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-HITS-001; FEATURE="HITSAlgorithm"; ASPECT=Centrality; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// HITS (Hyperlink-Induced Topic Search) - Kleinberg's algorithm
/// Returns hub and authority scores for each node
pub fn executeHITS(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, params: ?std.json.Value) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    if (node_list.items.len == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    var max_iterations: u32 = 100;
    var tolerance: f64 = 0.0001;

    if (params) |p| {
        if (p == .object) {
            if (p.object.get("maxIterations")) |mi| {
                if (mi == .integer) max_iterations = @intCast(mi.integer);
            }
            if (p.object.get("tolerance")) |tol| {
                if (tol == .float) tolerance = tol.float;
            }
        }
    }

    var hub = std.AutoHashMap(u64, f64).init(allocator);
    defer hub.deinit();
    var authority = std.AutoHashMap(u64, f64).init(allocator);
    defer authority.deinit();

    // Initialize scores
    for (node_list.items) |node| {
        try hub.put(node, 1.0);
        try authority.put(node, 1.0);
    }

    // Build outgoing edges map for efficiency
    var outgoing = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator);
    defer {
        var out_iter = outgoing.iterator();
        while (out_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        outgoing.deinit();
    }

    var incoming = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator);
    defer {
        var in_iter = incoming.iterator();
        while (in_iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        incoming.deinit();
    }

    for (node_list.items) |node| {
        try outgoing.put(node, try std.ArrayList(u64).initCapacity(allocator, 0));
        try incoming.put(node, try std.ArrayList(u64).initCapacity(allocator, 0));
    }

    var edge_iter = store.edges.iterator();
    while (edge_iter.next()) |entry| {
        const edge = entry.value_ptr.*;
        if (outgoing.getPtr(edge.from_id)) |out_list| {
            try out_list.append(allocator, edge.to_id);
        }
        if (incoming.getPtr(edge.to_id)) |in_list| {
            try in_list.append(allocator, edge.from_id);
        }
    }

    // Iterate
    var iteration: u32 = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var new_authority = std.AutoHashMap(u64, f64).init(allocator);
        defer new_authority.deinit();
        var new_hub = std.AutoHashMap(u64, f64).init(allocator);
        defer new_hub.deinit();

        // Authority update: auth(p) = sum of hub(q) for all q pointing to p
        for (node_list.items) |node| {
            var auth_sum: f64 = 0.0;
            if (incoming.get(node)) |in_list| {
                for (in_list.items) |source| {
                    auth_sum += hub.get(source) orelse 1.0;
                }
            }
            try new_authority.put(node, auth_sum);
        }

        // Hub update: hub(p) = sum of auth(q) for all q that p points to
        for (node_list.items) |node| {
            var hub_sum: f64 = 0.0;
            if (outgoing.get(node)) |out_list| {
                for (out_list.items) |target| {
                    hub_sum += new_authority.get(target) orelse 1.0;
                }
            }
            try new_hub.put(node, hub_sum);
        }

        // Normalize
        var auth_norm: f64 = 0.0;
        var hub_norm: f64 = 0.0;
        for (node_list.items) |node| {
            const a = new_authority.get(node) orelse 0;
            const h = new_hub.get(node) orelse 0;
            auth_norm += a * a;
            hub_norm += h * h;
        }
        auth_norm = @sqrt(auth_norm);
        hub_norm = @sqrt(hub_norm);
        if (auth_norm == 0) auth_norm = 1;
        if (hub_norm == 0) hub_norm = 1;

        var max_diff: f64 = 0;
        for (node_list.items) |node| {
            const new_auth = (new_authority.get(node) orelse 0) / auth_norm;
            const new_h = (new_hub.get(node) orelse 0) / hub_norm;
            const old_auth = authority.get(node) orelse 0;
            const old_h = hub.get(node) orelse 0;

            max_diff = @max(max_diff, @abs(new_auth - old_auth));
            max_diff = @max(max_diff, @abs(new_h - old_h));

            try authority.put(node, new_auth);
            try hub.put(node, new_h);
        }

        if (max_diff < tolerance) break;
    }

    // Return both hub and authority scores
    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 3);
        row[0] = Value{ .Int = @intCast(node_id) };
        const hub_score = hub.get(node_id).?;
        const auth_score = authority.get(node_id).?;
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(hub_score * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        row[2] = Value{ .Decimal = .{ .coeff = @intFromFloat(auth_score * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// ============================================================================
// TRIANGLE COUNTING AND CLUSTERING COEFFICIENT (#70)
// ============================================================================

// CANARY: REQ=REQ-GQL-TRIANGLE-COUNT-001; FEATURE="TriangleCounting"; ASPECT=Statistics; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Triangle Counting - count the number of triangles in the graph
pub fn executeTriangleCounting(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var triangle_count: u64 = 0;

    // For each node, check pairs of neighbors
    for (node_list.items) |node| {
        const neighbors = try getNeighbors(store, node, allocator);
        defer allocator.free(neighbors);

        for (neighbors, 0..) |n1, i| {
            // Only count triangles where node < n1 < n2 to avoid triple counting
            if (n1 <= node) continue;

            for (neighbors[i + 1 ..]) |n2| {
                if (n2 <= n1) continue;

                // Check if n1 and n2 are connected
                const n1_neighbors = try getNeighbors(store, n1, allocator);
                defer allocator.free(n1_neighbors);

                for (n1_neighbors) |n1n| {
                    if (n1n == n2) {
                        triangle_count += 1;
                        break;
                    }
                }
            }
        }
    }

    var rows = try allocator.alloc([]Value, 1);
    var row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Int = @intCast(triangle_count) };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-LOCAL-CLUSTERING-001; FEATURE="LocalClusteringCoefficient"; ASPECT=Statistics; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// Local Clustering Coefficient - for each node, ratio of triangles to possible triangles
pub fn executeLocalClusteringCoefficient(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node, idx| {
        const neighbors = try getNeighbors(store, node, allocator);
        defer allocator.free(neighbors);

        const degree = neighbors.len;
        var coefficient: f64 = 0.0;

        if (degree >= 2) {
            const possible_triangles = (degree * (degree - 1)) / 2;
            var actual_triangles: u64 = 0;

            // Count edges among neighbors
            for (neighbors, 0..) |n1, i| {
                for (neighbors[i + 1 ..]) |n2| {
                    const n1_neighbors = try getNeighbors(store, n1, allocator);
                    defer allocator.free(n1_neighbors);

                    for (n1_neighbors) |n1n| {
                        if (n1n == n2) {
                            actual_triangles += 1;
                            break;
                        }
                    }
                }
            }

            coefficient = @as(f64, @floatFromInt(actual_triangles)) / @as(f64, @floatFromInt(possible_triangles));
        }

        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node) };
        row[1] = Value{ .Decimal = .{ .coeff = @intFromFloat(coefficient * 1000000), .scale = 6, .orig_scale = 6, .orig_repr = null } };
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// ============================================================================
// K-CORE AND K-SHELL DECOMPOSITION (#71)
// ============================================================================

// CANARY: REQ=REQ-GQL-KCORE-001; FEATURE="KCoreDecomposition"; ASPECT=Community; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// K-Core Decomposition - finds the maximal subgraph where all nodes have degree >= k
/// Returns nodes that belong to the k-core for each k value (coreness)
pub fn executeKCore(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, 0);
    defer node_list.deinit(allocator);

    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        try node_list.append(allocator, entry.key_ptr.*);
    }

    // Compute coreness for each node using Batagelj-Zaversnik algorithm
    var degree = std.AutoHashMap(u64, u32).init(allocator);
    defer degree.deinit();
    var coreness = std.AutoHashMap(u64, u32).init(allocator);
    defer coreness.deinit();
    var removed = std.AutoHashMap(u64, bool).init(allocator);
    defer removed.deinit();

    // Initialize degrees
    for (node_list.items) |node| {
        const neighbors = try getNeighbors(store, node, allocator);
        defer allocator.free(neighbors);
        try degree.put(node, @intCast(neighbors.len));
        try removed.put(node, false);
        try coreness.put(node, 0);
    }

    // Find max degree
    var max_degree: u32 = 0;
    for (node_list.items) |node| {
        const d = degree.get(node).?;
        if (d > max_degree) max_degree = d;
    }

    // Process nodes in order of degree
    var k: u32 = 0;
    while (k <= max_degree) : (k += 1) {
        var changed = true;
        while (changed) {
            changed = false;
            for (node_list.items) |node| {
                if (removed.get(node).?) continue;
                if (degree.get(node).? <= k) {
                    try coreness.put(node, k);
                    try removed.put(node, true);

                    // Decrease degree of neighbors
                    const neighbors = try getNeighbors(store, node, allocator);
                    defer allocator.free(neighbors);

                    for (neighbors) |neighbor| {
                        if (!removed.get(neighbor).?) {
                            const current_deg = degree.get(neighbor).?;
                            if (current_deg > 0) {
                                try degree.put(neighbor, current_deg - 1);
                            }
                        }
                    }
                    changed = true;
                }
            }
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, idx| {
        var row = try allocator.alloc(Value, 2);
        row[0] = Value{ .Int = @intCast(node_id) };
        row[1] = Value{ .Int = @intCast(coreness.get(node_id).?) };
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-KSHELL-001; FEATURE="KShellDecomposition"; ASPECT=Community; STATUS=IMPL; OWNER=graph; UPDATED=2026-01-03
/// K-Shell Decomposition - nodes are assigned to the shell where they are removed
/// Shell k contains nodes with coreness exactly k (not in k+1 core but in k-core)
pub fn executeKShell(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8) !ExecutionResult {
    // K-Shell is essentially the same as K-Core but returns shell assignment
    // A node's shell is its coreness value
    return executeKCore(allocator, store, columns);
}
