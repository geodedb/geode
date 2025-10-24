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
    // adjacency list compressed placeholder
    pub fn init(node_count: u32) GraphHandle {
        return .{ .node_count = node_count };
    }
};

pub const CommunityResult = struct { modularity: f64, count: u32, labels: []u32 };

// Louvain community detection (deterministic tie-break simplified)
/// P2-3: Now accepts allocator parameter for labels allocation
pub fn communityDetect(allocator: std.mem.Allocator, g: *GraphHandle, method: enum { Louvain }, max_iter: u32, gamma: f64) !CommunityResult {
    _ = method;
    _ = gamma;
    _ = max_iter;
    if (g.node_count == 0) return CommunityResult{ .modularity = 0, .count = 0, .labels = &[_]u32{} };
    // P2-3: Use provided allocator instead of page_allocator
    var labels = try allocator.alloc(u32, g.node_count);
    var i: u32 = 0;
    while (i < g.node_count) : (i += 1) labels[i] = i; // trivial deterministic labeling
    const mod: f64 = 0.42; // placeholder modularity
    return CommunityResult{ .modularity = mod, .count = g.node_count, .labels = labels };
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
