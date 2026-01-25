const std = @import("std");

// Runtime flag checks
/// P2-3: Now accepts allocator parameter for env var reading
fn graphEnabled(allocator: std.mem.Allocator) bool {
    const res = std.process.getEnvVarOwned(allocator, "GEODE_GRAPH_MAX_ITERS");
    if (res) |val| {
        allocator.free(val);
        return true;
    } else |_| return false;
}

pub const GraphHandle = struct {
    // Placeholder graph representation; real impl integrates storage adjacency
    node_count: u32,
    // GAP-0078: Optional adjacency list for community detection
    adjacency: ?[][]u32 = null,

    pub fn init(node_count: u32) GraphHandle {
        return .{ .node_count = node_count };
    }

    /// GAP-0078: Initialize with adjacency list for Louvain
    pub fn initWithAdjacency(node_count: u32, adjacency: [][]u32) GraphHandle {
        return .{ .node_count = node_count, .adjacency = adjacency };
    }

    /// GAP-0078: Check if adjacency data is available
    pub fn hasAdjacency(self: *GraphHandle) bool {
        return self.adjacency != null;
    }

    /// GAP-0078: Convert to adjacency list format for Louvain algorithm
    pub fn toAdjacencyList(self: *GraphHandle, allocator: std.mem.Allocator) ![][]u32 {
        if (self.adjacency) |adj| {
            // Clone the adjacency list
            var result = try allocator.alloc([]u32, adj.len);
            for (adj, 0..) |neighbors, i| {
                result[i] = try allocator.dupe(u32, neighbors);
            }
            return result;
        }
        // No adjacency data - return empty lists
        var result = try allocator.alloc([]u32, self.node_count);
        for (0..self.node_count) |i| {
            result[i] = &[_]u32{};
        }
        return result;
    }
};

pub const CommunityResult = struct { modularity: f64, count: u32, labels: []u32 };

// GAP-0078: Import actual Louvain implementation
const community_louvain = @import("community_louvain.zig");

// Louvain community detection - now uses actual modularity optimization
/// P2-3: Now accepts allocator parameter for labels allocation
/// GAP-0078: Updated to use actual Louvain algorithm with real modularity calculation
// CANARY: REQ=REQ-GRAPH-LOUVAIN-003; FEATURE="LouvainIntegration"; ASPECT=GraphAnalytics; STATUS=TESTED; TEST=src/graph/community_louvain.zig; OWNER=graph; UPDATED=2026-01-25
pub fn communityDetect(allocator: std.mem.Allocator, g: *GraphHandle, method: enum { Louvain }, max_iter: u32, gamma: f64) !CommunityResult {
    _ = method;
    _ = max_iter;

    if (g.node_count == 0) return CommunityResult{ .modularity = 0, .count = 0, .labels = &[_]u32{} };

    // For GraphHandle (placeholder), we need adjacency list
    // If no adjacency data, use fallback with each node in own community
    if (!g.hasAdjacency()) {
        var labels = try allocator.alloc(u32, g.node_count);
        var i: u32 = 0;
        while (i < g.node_count) : (i += 1) labels[i] = i;
        // Each node in own community has modularity 0
        return CommunityResult{ .modularity = 0.0, .count = g.node_count, .labels = labels };
    }

    // Convert GraphHandle adjacency to [][]u32 for Louvain
    const graph_data = try g.toAdjacencyList(allocator);
    defer {
        for (graph_data) |row| allocator.free(row);
        allocator.free(graph_data);
    }

    // Run actual Louvain algorithm with resolution (gamma) parameter
    const labels = try community_louvain.detect(allocator, graph_data, gamma, 0.0001);

    // Calculate modularity score
    const mod = community_louvain.modularity(graph_data, labels, gamma);

    // Count unique communities
    var max_comm: u32 = 0;
    for (labels) |comm| {
        if (comm > max_comm) max_comm = comm;
    }
    const count = max_comm + 1;

    return CommunityResult{ .modularity = mod, .count = count, .labels = labels };
}

/// P2-3: Now accepts allocator parameter
pub fn degreeCentrality(allocator: std.mem.Allocator, g: *GraphHandle) ![]f64 {
    return try allocOnes(allocator, g.node_count);
}
/// P2-3: Now accepts allocator parameter
pub fn closenessCentrality(allocator: std.mem.Allocator, g: *GraphHandle, directed: bool) ![]f64 {
    _ = directed;
    return try allocOnes(allocator, g.node_count);
}
/// P2-3: Now accepts allocator parameter
pub fn betweennessCentrality(allocator: std.mem.Allocator, g: *GraphHandle, directed: bool, normalized: bool) ![]f64 {
    _ = directed;
    _ = normalized;
    return try allocZeros(allocator, g.node_count);
}
/// P2-3: Now accepts allocator parameter
pub fn eigenvectorCentrality(allocator: std.mem.Allocator, g: *GraphHandle, tol: f64, max_iter: u32) ![]f64 {
    _ = tol;
    _ = max_iter;
    return try allocOnes(allocator, g.node_count);
}

/// P2-3: Now accepts allocator parameter
fn allocOnes(allocator: std.mem.Allocator, n: u32) ![]f64 {
    const arr = try allocator.alloc(f64, n);
    for (arr) |*v| v.* = 1;
    return arr;
}
/// P2-3: Now accepts allocator parameter
fn allocZeros(allocator: std.mem.Allocator, n: u32) ![]f64 {
    const arr = try allocator.alloc(f64, n);
    for (arr) |*v| v.* = 0;
    return arr;
}

// Planner scope enforcement helper: only allow in RETURN
pub fn validateReturnOnlyUsage(context: []const u8) !void {
    // context could encode clause; simple heuristic
    if (!std.mem.eql(u8, context, "RETURN")) return error.GRAPH_ALG_USAGE_ERROR;
}
