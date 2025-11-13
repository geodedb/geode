const std = @import("std");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;

// CANARY: REQ=REQ-EXEC-REFACTOR-003; FEATURE="ExecutionRefactoring"; ASPECT=CENTRALITY_ALGORITHMS; STATUS=IMPL; OWNER=refactor; UPDATED=2025-10-17
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
