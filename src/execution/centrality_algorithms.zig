const std = @import("std");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;

// SONNY-1318 (GEO-UP-005): the shared, hierarchy-aware tenant visibility
// predicate — the SAME one `match_operations.zig` applies to a MATCH read.
// Before this, every `executeX` here iterated `store.nodes` and raw adjacency
// with no tenant term at all, so `CALL algo.pagerank.stream` scored (and
// returned the node ids of) every tenant in the deployment.
//
// EVERY public entry point in this file therefore takes the call's scope as a
// REQUIRED trailing parameter. SONNY-1318 made it the session's resolved
// tenant scope; SONNY-2685 made it an `AlgoScope`, which adds the session's
// graph and RLS policies. Required rather than ambient so a new algorithm
// that forgets it is a compile error instead of a silent leak.
const tenant_visibility = @import("tenant_visibility.zig");

// SONNY-2685: every algorithm below takes the call's `AlgoScope` (the
// session's graph, tenant scope and RLS policies) as a REQUIRED parameter in
// place of the bare tenant scope SONNY-1318 threaded through. See
// `algo_scope.zig`.
const AlgoScope = @import("algo_scope.zig").AlgoScope;

// GAP-0273: Thread-pool-backed parallelism for graph algorithm hot paths.
const parallel_wrapper = @import("parallel/thread_pool_parallel");
const ParallelPool = parallel_wrapper.ParallelPool;

// Local type aliases
const Value = value_types.Value;

/// Safe conversion of u64 node/edge IDs to Value.Int (i64).
/// Saturates to maxInt(i64) if the ID exceeds the signed range,
/// preventing a Zig safety-checked @intCast panic at runtime.
pub fn safeU64ToValue(id: u64) Value {
    if (id > @as(u64, @intCast(std.math.maxInt(i64)))) {
        return Value{ .Int = std.math.maxInt(i64) };
    }
    return Value{ .Int = @intCast(id) };
}

/// DRY helper: Convert an f64 score to a Decimal Value with scale 6.
/// Replaces 14+ inline `Value{ .Decimal = .{ .coeff = @intFromFloat(score * 1000000), .scale = 6, ...} }` patterns.
/// SONNY-2739: a score the decimal cannot hold (NaN, an infinity or a
/// magnitude past 38 digits, from degenerate weights) is returned as the
/// double itself; the bare `@intFromFloat` aborted the server.
fn scoreToDecimal(score: f64) Value {
    const SCALE: u8 = 6;
    const FACTOR: i128 = 1_000_000;
    const coeff = @import("../types/decimal128.zig").checkedScaledCoeff(score, @floatFromInt(FACTOR)) catch return .{ .Double = score };
    return Value{ .Decimal = .{ .coeff = coeff, .scale = SCALE, .orig_scale = SCALE, .orig_repr = null } };
}

/// DRY helper: Collect all node IDs from the store into an ArrayList.
/// Replaces 24+ inline `var node_list = ...; var node_iter = store.nodes.iterator(); while ...` patterns.
/// Caller owns the returned ArrayList and must call `node_list.deinit(allocator)`.
fn collectNodeIds(store: *graph_store.GraphStore, allocator: std.mem.Allocator, scope: *AlgoScope) !std.ArrayList(u64) {
    var node_list = try std.ArrayList(u64).initCapacity(allocator, store.nodes.count());
    var node_iter = store.nodes.iterator();
    while (node_iter.next()) |entry| {
        // SONNY-1318 / SONNY-2685: this is the node UNIVERSE every algorithm
        // in this file scores and returns. Filtering here keeps other graphs'
        // nodes, other tenants' nodes and RLS-hidden nodes out of the result
        // set; `store.nodes` holds every graph's nodes.
        if (!scope.nodeVisible(entry.value_ptr)) continue;
        try node_list.append(allocator, entry.key_ptr.*);
    }
    return node_list;
}

const Degree = struct { out: u64, in: u64 };

/// A node's raw adjacency lengths: every incident edge, all in the node's
/// graph. Predicate-free; only for a scope that restricts nothing
/// (`AlgoScope.restricts`). SONNY-6607 (1): an adjacency list that cannot be
/// read is the read's error (it counted as 0), and the read may hydrate from
/// the storage adapter, so calling thread only.
fn rawDegree(store: *graph_store.GraphStore, node_id: u64) !Degree {
    return .{
        .out = if ((try store.getOutgoingEdgeIdsOrError(node_id))) |ids| ids.len else 0,
        .in = if ((try store.getIncomingEdgeIdsOrError(node_id))) |ids| ids.len else 0,
    };
}

/// SONNY-1318 / SONNY-2685: count a node's incident edges that the scope
/// may traverse (the edge's tag and RLS policies, and both endpoints).
/// Replaces the raw `getOutgoingEdgeIds(..).len` degree reads, which counted
/// edges into other tenants' subgraphs and edges RLS hides. Calling thread
/// only.
fn visibleDegree(store: *graph_store.GraphStore, node_id: u64, scope: *AlgoScope) !Degree {
    if (!scope.restricts()) return try rawDegree(store, node_id);
    var out_deg: u64 = 0;
    var in_deg: u64 = 0;
    if ((try store.getOutgoingEdgeIdsOrError(node_id))) |ids| {
        for (ids) |eid| {
            if (try scope.edgeIdTraversable(store, eid)) out_deg += 1;
        }
    }
    if ((try store.getIncomingEdgeIdsOrError(node_id))) |ids| {
        for (ids) |eid| {
            if (try scope.edgeIdTraversable(store, eid)) in_deg += 1;
        }
    }
    return .{ .out = out_deg, .in = in_deg };
}

/// SONNY-1318 / SONNY-2685: total number of edges the scope may traverse.
/// Replaces `store.edges.count()` in the graph-statistics procedures, which
/// counted every graph's resident edges.
fn visibleEdgeCount(store: *graph_store.GraphStore, allocator: std.mem.Allocator, scope: *AlgoScope) !usize {
    if (!scope.restricts()) return store.countEdgesForGraph(scope.graph());
    const ids = try store.allEdgeIds(allocator);
    defer allocator.free(ids);
    var n: usize = 0;
    for (ids) |eid| {
        if (try scope.edgeIdTraversable(store, eid)) n += 1;
    }
    return n;
}

/// SONNY-1318 / SONNY-2685: number of nodes visible to the scope.
fn visibleNodeCount(store: *graph_store.GraphStore, scope: *AlgoScope) !usize {
    if (!scope.restricts()) return store.countNodesForGraph(scope.graph(), null);
    var n: usize = 0;
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        if (scope.nodeVisible(entry.value_ptr)) n += 1;
    }
    return n;
}

/// DRY helper: Build a single-row ExecutionResult from column/row data.
/// Reduces boilerplate for the common pattern of returning results with a flags list.
fn singleResult(allocator: std.mem.Allocator, columns: [][]const u8, row: []Value) !ExecutionResult {
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// DRY helper: Build a multi-row ExecutionResult.
fn multiResult(columns: [][]const u8, rows: [][]Value) ExecutionResult {
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// GAP-0273: Global parallel pool for graph algorithm parallelism.
// Initialized lazily on first use, shared across all algorithm calls.
// GAP-0883: the pool is process-lifetime, so it MUST own a process-lifetime
// allocator. It previously captured the first caller's allocator — which on
// the server is the per-request arena (GAP-0755): the pool's threads and
// chunk buffers would race a non-thread-safe arena and dangle after the
// request completed. smp_allocator is the governance-approved global
// allocator for process-lifetime registries (see schema_change_notifier.zig).
var g_parallel_pool: ?ParallelPool = null;
var g_parallel_pool_mu: std.Io.Mutex = std.Io.Mutex.init;

fn getParallelPool() *ParallelPool {
    g_parallel_pool_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_parallel_pool_mu.unlock(std.Io.Threaded.global_single_threaded.io());
    if (g_parallel_pool == null) {
        g_parallel_pool = ParallelPool.init(std.heap.smp_allocator, null);
        g_parallel_pool.?.start();
    }
    return &g_parallel_pool.?;
}

// CANARY: REQ=REQ-EXEC-REFACTOR-003; FEATURE="ExecutionRefactoring"; ASPECT=CENTRALITY_ALGORITHMS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted centrality and community detection algorithms from execution.zig for better modularity (M1 Phase 3)

/// Get neighbors of a node using adjacency indexes (O(degree) instead of O(E)).
/// Returns a caller-owned slice of neighbor node IDs.
pub fn getNeighbors(store: *graph_store.GraphStore, node_id: u64, allocator: std.mem.Allocator, scope: *AlgoScope) ![]u64 {
    var neighbors = std.ArrayList(u64).empty;

    // Use adjacency indexes for O(degree) lookup instead of full edge scan.
    // SONNY-1318: the edge AND both its endpoints must be visible to the
    // session's tenant scope — never expand a frontier THROUGH an invisible
    // node, even across an edge that happens to carry the reader's own tag.
    if ((try store.getOutgoingEdgeIdsOrError(node_id))) |out_edge_ids| {
        for (out_edge_ids) |edge_id| {
            if ((try store.getEdgeHydratedChecked(edge_id))) |edge| {
                if (!scope.edgeTraversable(store, edge)) continue;
                try neighbors.append(allocator, edge.to_id);
            }
        }
    }
    if ((try store.getIncomingEdgeIdsOrError(node_id))) |in_edge_ids| {
        for (in_edge_ids) |edge_id| {
            if ((try store.getEdgeHydratedChecked(edge_id))) |edge| {
                if (!scope.edgeTraversable(store, edge)) continue;
                try neighbors.append(allocator, edge.from_id);
            }
        }
    }
    return try neighbors.toOwnedSlice(allocator);
}

/// Precompute adjacency lists for all nodes once (O(V+E) total).
/// Returns a map from node_id -> owned slice of neighbor IDs.
/// Caller must call `deinitAdjacency` to free resources.
pub fn precomputeAdjacency(store: *graph_store.GraphStore, node_list: []const u64, allocator: std.mem.Allocator, scope: *AlgoScope) !std.AutoHashMap(u64, []const u64) {
    var adj = std.AutoHashMap(u64, []const u64).init(allocator);
    errdefer {
        var val_iter = adj.valueIterator();
        while (val_iter.next()) |v| allocator.free(v.*);
        adj.deinit();
    }
    for (node_list) |node_id| {
        const neighbors = try getNeighbors(store, node_id, allocator, scope);
        try adj.put(node_id, neighbors);
    }
    return adj;
}

/// Free all neighbor slices and the adjacency map itself.
pub fn deinitAdjacency(adj: *std.AutoHashMap(u64, []const u64), allocator: std.mem.Allocator) void {
    var val_iter = adj.valueIterator();
    while (val_iter.next()) |v| allocator.free(v.*);
    adj.deinit();
}

/// Neighbor set type used by triangle-counting optimizations.
pub const NeighborSet = std.AutoHashMap(u64, void);

/// Build a map from node ID to a HashSet of its neighbor IDs for O(1) adjacency
/// checks. Caller must call `deinitNeighborSets` to free resources.
pub fn buildNeighborSets(node_list: []const u64, store: *graph_store.GraphStore, allocator: std.mem.Allocator, scope: *AlgoScope) !std.AutoHashMap(u64, NeighborSet) {
    var sets = std.AutoHashMap(u64, NeighborSet).init(allocator);
    errdefer {
        var it = sets.valueIterator();
        while (it.next()) |v| v.deinit();
        sets.deinit();
    }
    for (node_list) |node| {
        var set = NeighborSet.init(allocator);
        if ((try store.getOutgoingEdgeIdsOrError(node))) |out_edge_ids| {
            for (out_edge_ids) |edge_id| {
                if ((try store.getEdgeHydratedChecked(edge_id))) |edge| {
                    // SONNY-1318: same visibility rule as getNeighbors.
                    if (!scope.edgeTraversable(store, edge)) continue;
                    try set.put(edge.to_id, {});
                }
            }
        }
        if ((try store.getIncomingEdgeIdsOrError(node))) |in_edge_ids| {
            for (in_edge_ids) |edge_id| {
                if ((try store.getEdgeHydratedChecked(edge_id))) |edge| {
                    if (!scope.edgeTraversable(store, edge)) continue;
                    try set.put(edge.from_id, {});
                }
            }
        }
        try sets.put(node, set);
    }
    return sets;
}

/// Free all NeighborSets and the outer map.
pub fn deinitNeighborSets(sets: *std.AutoHashMap(u64, NeighborSet)) void {
    var it = sets.valueIterator();
    while (it.next()) |v| v.deinit();
    sets.deinit();
}

/// Degree Centrality - count edges for each node
/// GAP-0273: Uses the shared parallel wrapper for concurrent degree computation on large graphs.
pub fn executeDegreeCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    const n = node_list.items.len;
    const rows = try allocator.alloc([]Value, n);
    // Pre-allocate all row arrays so parallel workers don't need the allocator
    for (rows) |*row| {
        row.* = try allocator.alloc(Value, 2);
    }

    // SONNY-1318 review R1: the SCOPED degree is computed HERE, on the calling
    // thread, and the workers only read the result.
    //
    // `visibleDegree` with a tenant scope calls `edgeIdTraversable` ->
    // `edgeTraversable` -> `nodeIdVisible`, whose bounded-cache-miss arm takes
    // `store.dupeNodeTenantForRead(store.allocator, ..)` — the SHARED store
    // allocator — and can reach the storage adapter for an evicted node. Both
    // are forbidden on a `parallelForEach` worker, and doing them there
    // contradicted this function's own invariant ("pre-allocate all row arrays
    // so parallel workers don't need the allocator"). Precomputing on the
    // calling thread is the smaller of the two fixes the review offered: it
    // needs no worker-local arena plumbing through the shared predicate module,
    // it keeps `tenant_visibility.zig` allocator-parameter-free for every other
    // caller, and the parallel section still runs (it fills the rows), so the
    // >32-node threshold and its worker fan-out are unchanged.
    //
    // SONNY-6607 (1): an unrestricted scope's raw adjacency lengths are read
    // here too. A worker read them, which hydrates an evicted adjacency list
    // from the storage adapter (forbidden on a worker, as above), and a list
    // that could not be read counted as degree 0 (a worker cannot fail the
    // call). Read here, a failed read fails the call.
    //
    // SONNY-2685: likewise for the RLS checks, which read the active execution
    // context and the traversal's label snapshot, both thread-local: on a
    // worker they would see neither and allow every edge. Whenever the scope
    // restricts anything (a tenant scope, or an RLS policy that may deny),
    // every degree is computed here.
    const degrees: []u64 = blk: {
        const degs = try allocator.alloc(u64, n);
        errdefer allocator.free(degs);
        for (node_list.items, 0..) |node_id, i| {
            const deg = try visibleDegree(store, node_id, scope);
            degs[i] = deg.out + deg.in;
        }
        break :blk degs;
    };
    defer allocator.free(degrees);

    const DegreeCtx = struct {
        nodes: []const u64,
        rows: [][]Value,
        // SONNY-1318 / SONNY-6607: every degree, computed on the calling
        // thread; the worker touches no tenant predicate, no allocator and no
        // storage adapter.
        degrees: []const u64,
    };

    const ctx = DegreeCtx{
        .nodes = node_list.items,
        .rows = rows,
        .degrees = degrees,
    };

    // GAP-0273: Parallel degree computation — each node's degree is independent
    const pool = getParallelPool();
    parallel_wrapper.parallelForEach(
        pool,
        0,
        n,
        ctx,
        struct {
            fn compute(_: *parallel_wrapper.Task, idx: usize, c: DegreeCtx) void {
                const node_id = c.nodes[idx];
                const total: u64 = c.degrees[idx];
                c.rows[idx][0] = safeU64ToValue(node_id);
                c.rows[idx][1] = safeU64ToValue(total);
            }
        }.compute,
        parallel_wrapper.Thresholds.forEach,
    );
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Betweenness Centrality - Brandes algorithm
/// Uses precomputed adjacency to avoid per-call getNeighbors allocation in inner loops.
pub fn executeBetweennessCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    // Precompute adjacency once: O(V+E) total instead of O(V*(V+E)) repeated getNeighbors calls
    var adj = try precomputeAdjacency(store, node_list.items, allocator, scope);
    defer deinitAdjacency(&adj, allocator);

    var centrality = std.AutoHashMap(u64, f64).init(allocator);
    defer centrality.deinit();

    for (node_list.items) |node| {
        try centrality.put(node, 0.0);
    }

    // Brandes algorithm
    for (node_list.items) |source| {
        var stack = std.ArrayList(u64).empty;
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
            try paths.put(node, std.ArrayList(u64).empty);
            try sigma.put(node, 0.0);
            try dist.put(node, -1);
            try delta.put(node, 0.0);
        }

        try sigma.put(source, 1.0);
        try dist.put(source, 0);

        var queue = std.ArrayList(u64).empty;
        defer queue.deinit(allocator);
        try queue.append(allocator, source);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const v = queue.items[front];
            try stack.append(allocator, v);

            const neighbors = adj.get(v) orelse &[_]u64{};

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
                const sigma_w = sigma.get(w).?;
                if (sigma_w == 0.0) continue;
                for (w_paths.items) |v| {
                    const contribution = (sigma.get(v).? / sigma_w) * (1.0 + delta.get(w).?);
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
        row[0] = safeU64ToValue(node_id);
        const score = centrality.get(node_id).?;
        row[1] = scoreToDecimal(score);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Closeness Centrality - BFS-based
/// Uses precomputed adjacency to avoid per-call getNeighbors allocation in BFS inner loop.
pub fn executeClosenessCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    // Precompute adjacency once: O(V+E) total instead of O(V^2 * avg_degree) repeated getNeighbors calls
    var adj = try precomputeAdjacency(store, node_list.items, allocator, scope);
    defer deinitAdjacency(&adj, allocator);

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();

        var queue = std.ArrayList(u64).empty;
        defer queue.deinit(allocator);

        try distances.put(node_id, 0);
        try queue.append(allocator, node_id);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const neighbors = adj.get(current) orelse &[_]u64{};

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
        row[0] = safeU64ToValue(node_id);
        row[1] = scoreToDecimal(closeness);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Eigenvector Centrality - Power iteration
/// Uses double-buffered flat arrays and precomputed adjacency for O(1) index lookups
/// instead of HashMap per-iteration allocation.
pub fn executeEigenvectorCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    const n = node_list.items.len;

    if (n == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // Build node_id -> dense index mapping once
    var node_id_to_index = std.AutoHashMap(u64, usize).init(allocator);
    defer node_id_to_index.deinit();
    for (node_list.items, 0..) |node, idx| {
        try node_id_to_index.put(node, idx);
    }

    // Precompute adjacency once
    var adj = try precomputeAdjacency(store, node_list.items, allocator, scope);
    defer deinitAdjacency(&adj, allocator);

    // Double-buffered flat arrays for scores
    const buf_a = try allocator.alloc(f64, n);
    defer allocator.free(buf_a);
    const buf_b = try allocator.alloc(f64, n);
    defer allocator.free(buf_b);

    const initial = 1.0 / @sqrt(@as(f64, @floatFromInt(n)));
    for (buf_a) |*v| v.* = initial;

    var current = buf_a;
    var next = buf_b;

    const max_iterations: u32 = 100;
    const tolerance: f64 = 0.0001;

    var iteration: u32 = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        // Compute next scores from current using adjacency + flat index lookup
        for (node_list.items, 0..) |node, idx| {
            var sum: f64 = 0;
            const neighbors = adj.get(node) orelse &[_]u64{};
            for (neighbors) |neighbor| {
                const ni = node_id_to_index.get(neighbor) orelse continue;
                sum += current[ni];
            }
            next[idx] = sum;
        }

        // Normalize
        var norm: f64 = 0;
        for (next[0..n]) |v| {
            norm += v * v;
        }
        norm = @sqrt(norm);
        if (norm == 0) norm = 1;

        var max_diff: f64 = 0;
        for (0..n) |idx| {
            const new_val = next[idx] / norm;
            const old_val = current[idx];
            max_diff = @max(max_diff, @abs(new_val - old_val));
            next[idx] = new_val;
        }

        // Swap buffers (pointer swap, no copy)
        const tmp = current;
        current = next;
        next = tmp;

        if (max_diff < tolerance) break;
    }

    var rows = try allocator.alloc([]Value, n);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node_id);
        const score = current[i];
        row[1] = scoreToDecimal(score);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// PageRank Algorithm
/// Uses double-buffered flat arrays for O(1) rank lookups instead of HashMap per iteration.
pub fn executePageRank(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, params: ?std.json.Value, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    const n = node_list.items.len;

    if (n == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
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
                // SONNY-2769: outside u32 the cast aborted the server.
                if (mi == .integer) max_iterations = std.math.cast(u32, mi.integer) orelse return error.InvalidArgs;
            }
            if (p.object.get("tolerance")) |tol| {
                if (tol == .float) tolerance = tol.float;
            }
        }
    }

    // Build node_id -> dense index mapping once
    var node_id_to_index = std.AutoHashMap(u64, usize).init(allocator);
    defer node_id_to_index.deinit();
    for (node_list.items, 0..) |node, idx| {
        try node_id_to_index.put(node, idx);
    }

    // Precompute out-degrees into a flat array for O(1) lookup
    var out_degrees = try allocator.alloc(f64, n);
    defer allocator.free(out_degrees);
    for (node_list.items, 0..) |node, idx| {
        // SONNY-1318: out-degree over VISIBLE edges only, or a node's rank
        // would be diluted by links into tenants the session cannot see.
        const out_degree_count = (try visibleDegree(store, node, scope)).out;
        out_degrees[idx] = @as(f64, @floatFromInt(out_degree_count));
    }

    // Double-buffered flat arrays for PageRank scores
    const buf_a = try allocator.alloc(f64, n);
    defer allocator.free(buf_a);
    const buf_b = try allocator.alloc(f64, n);
    defer allocator.free(buf_b);

    const initial_rank = 1.0 / @as(f64, @floatFromInt(n));
    for (buf_a) |*v| v.* = initial_rank;

    var current = buf_a;
    var next = buf_b;

    var iteration: u32 = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        const base_rank = (1.0 - damping_factor) / @as(f64, @floatFromInt(n));

        for (node_list.items, 0..) |node, idx| {
            var rank_sum: f64 = 0;

            // Use incoming_edges adjacency index to find predecessors in O(in_degree)
            if ((try store.getIncomingEdgeIdsOrError(node))) |in_edge_ids| {
                for (in_edge_ids) |edge_id| {
                    if ((try store.getEdgeHydratedChecked(edge_id))) |edge| {
                        // SONNY-1318: never accumulate rank across an edge (or
                        // from a predecessor) the session's scope cannot see.
                        if (!scope.edgeTraversable(store, edge)) continue;
                        const linking_node = edge.from_id;
                        const li = node_id_to_index.get(linking_node) orelse continue;
                        const out_degree = out_degrees[li];
                        if (out_degree > 0) {
                            rank_sum += current[li] / out_degree;
                        }
                    }
                }
            }

            next[idx] = base_rank + damping_factor * rank_sum;
        }

        // Check convergence
        var max_diff: f64 = 0;
        for (0..n) |idx| {
            max_diff = @max(max_diff, @abs(next[idx] - current[idx]));
        }

        // Swap buffers
        const tmp = current;
        current = next;
        next = tmp;

        if (max_diff < tolerance) break;
    }

    var rows = try allocator.alloc([]Value, n);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node_id);
        const score = current[i];
        row[1] = scoreToDecimal(score);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Louvain Community Detection - real modularity optimization
/// Implements the Louvain method: iteratively moves nodes to the neighboring
/// community that yields the maximum modularity gain, until convergence or
/// max_iterations is reached.
pub fn executeLouvainCommunities(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    if (node_list.items.len == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // node -> community mapping
    var communities = std.AutoHashMap(u64, u64).init(allocator);
    defer communities.deinit();

    // Initialize each node in its own community (use node_id as community id)
    for (node_list.items) |node| {
        try communities.put(node, node);
    }

    // Compute total edge weight (m). All edges have weight 1.0 since Edge has
    // no weight field. Each undirected edge is stored once in store.edges, so
    // m = number of edges (we treat each stored edge as contributing 1 to m,
    // representing one undirected link with weight 1).
    // SONNY-1318: m is the total edge weight of the graph the session can SEE.
    const edge_count = try visibleEdgeCount(store, allocator, scope);
    if (edge_count == 0) {
        // No edges: every node stays in its own community
        var rows = try allocator.alloc([]Value, node_list.items.len);
        for (node_list.items, 0..) |node_id, i| {
            var row = try allocator.alloc(Value, 2);
            row[0] = safeU64ToValue(node_id);
            row[1] = safeU64ToValue(communities.get(node_id).?);
            rows[i] = row;
        }
        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    const m: f64 = @floatFromInt(edge_count);

    // Precompute node degree (k_i): number of edges incident to each node
    // (out-degree + in-degree, with weight 1 per edge)
    var node_degree = std.AutoHashMap(u64, f64).init(allocator);
    defer node_degree.deinit();
    for (node_list.items) |node| {
        const deg = try visibleDegree(store, node, scope);
        try node_degree.put(node, @floatFromInt(deg.out + deg.in));
    }

    // Modularity optimization loop
    const max_iterations: u32 = 100;
    var iteration: u32 = 0;
    var improved = true;

    while (improved and iteration < max_iterations) : (iteration += 1) {
        improved = false;

        for (node_list.items) |node| {
            const current_comm = communities.get(node).?;
            const k_i = node_degree.get(node).?;

            // Gather neighbor communities and the weight of edges to each community
            const neighbors = try getNeighbors(store, node, allocator, scope);
            defer allocator.free(neighbors);

            // k_i_in for each candidate community: sum of edge weights from node
            // to nodes in that community. Also compute sigma_tot and sigma_in
            // per candidate community.
            var neighbor_comm_weight = std.AutoHashMap(u64, f64).init(allocator);
            defer neighbor_comm_weight.deinit();

            for (neighbors) |neighbor| {
                const nc = communities.get(neighbor).?;
                const prev = neighbor_comm_weight.get(nc) orelse 0.0;
                try neighbor_comm_weight.put(nc, prev + 1.0);
            }

            // Compute sigma_tot for each candidate community (sum of degrees
            // of all nodes in that community). Also need sigma_tot for the
            // current community excluding node i.
            // For efficiency we compute sigma_tot on the fly for candidate
            // communities that appear in the neighbor set.

            // Collect unique candidate communities (including current)
            var candidate_comms = std.AutoHashMap(u64, void).init(allocator);
            defer candidate_comms.deinit();
            try candidate_comms.put(current_comm, {});
            {
                var nc_iter = neighbor_comm_weight.iterator();
                while (nc_iter.next()) |entry| {
                    try candidate_comms.put(entry.key_ptr.*, {});
                }
            }

            // Compute sigma_tot for each candidate community
            var sigma_tot_map = std.AutoHashMap(u64, f64).init(allocator);
            defer sigma_tot_map.deinit();

            for (node_list.items) |n| {
                const nc = communities.get(n).?;
                if (candidate_comms.contains(nc)) {
                    const prev = sigma_tot_map.get(nc) orelse 0.0;
                    try sigma_tot_map.put(nc, prev + node_degree.get(n).?);
                }
            }

            // Evaluate modularity gain of moving node to each neighbor community.
            // delta_Q = k_i_in / m - sigma_tot * k_i / (2 * m * m)
            // (simplified form: we compare the gain of moving INTO a community
            //  vs removing from current community)
            //
            // Full formula for moving node i from community A to community B:
            // delta_Q = [ (sigma_in_B + 2*k_i_in_B) / (2m) - ((sigma_tot_B + k_i)/(2m))^2 ]
            //         - [ sigma_in_B / (2m) - (sigma_tot_B/(2m))^2 - (k_i/(2m))^2 ]
            //         - [ (sigma_in_A_excl + 2*k_i_in_A_excl) ... ] (removal cost)
            //
            // Simplified: delta_Q_move_to_B = k_i_in_B/m - sigma_tot_B * k_i / (2*m*m)
            // delta_Q_remove_from_A = -(k_i_in_A/m - sigma_tot_A_excl * k_i / (2*m*m))
            // net = delta_Q_move_to_B + delta_Q_remove_from_A
            //
            // We pick the community with the best net gain > 0.

            const k_i_in_current = neighbor_comm_weight.get(current_comm) orelse 0.0;
            const sigma_tot_current = sigma_tot_map.get(current_comm) orelse 0.0;
            // sigma_tot of current community excluding node i
            const sigma_tot_current_excl = sigma_tot_current - k_i;
            // Cost of removing from current community
            const remove_cost = k_i_in_current / m - sigma_tot_current_excl * k_i / (2.0 * m * m);

            var best_gain: f64 = 0.0;
            var best_comm: u64 = current_comm;

            var nc_iter = neighbor_comm_weight.iterator();
            while (nc_iter.next()) |entry| {
                const cand_comm = entry.key_ptr.*;
                if (cand_comm == current_comm) continue;

                const k_i_in_cand = entry.value_ptr.*;
                const sigma_tot_cand = sigma_tot_map.get(cand_comm) orelse 0.0;

                // Gain of inserting into candidate community
                const insert_gain = k_i_in_cand / m - sigma_tot_cand * k_i / (2.0 * m * m);

                // Net gain = insert_gain - remove_cost
                const net_gain = insert_gain - remove_cost;

                if (net_gain > best_gain) {
                    best_gain = net_gain;
                    best_comm = cand_comm;
                }
            }

            if (best_comm != current_comm and best_gain > 0.0) {
                try communities.put(node, best_comm);
                improved = true;
            }
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node_id);
        row[1] = safeU64ToValue(communities.get(node_id).?);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Label Propagation community detection
pub fn executeLabelPropagation(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

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
            const neighbors = try getNeighbors(store, node, allocator, scope);
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
        row[0] = safeU64ToValue(node_id);
        row[1] = safeU64ToValue(labels.get(node_id).?);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Union-Find (Connected Components) with path compression and union-by-rank
pub fn executeUnionFind(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    var parent = std.AutoHashMap(u64, u64).init(allocator);
    defer parent.deinit();

    var rank = std.AutoHashMap(u64, u32).init(allocator);
    defer rank.deinit();

    for (node_list.items) |node| {
        try parent.put(node, node);
        try rank.put(node, 0);
    }

    // Find with path compression: after finding root, set every node
    // along the path to point directly to root.
    const find = struct {
        fn f(p: *std.AutoHashMap(u64, u64), x: u64) ?u64 {
            if (p.get(x) == null) return null;

            // Phase 1: find root
            var current = x;
            while (p.get(current)) |parent_id| {
                if (parent_id == current) break;
                current = parent_id;
            }
            const root = current;

            // Phase 2: path compression - walk again, pointing each node to root
            current = x;
            while (p.get(current)) |parent_id| {
                if (parent_id == current) break;
                p.put(current, root) catch {};
                current = parent_id;
            }

            return root;
        }
    }.f;

    // PHASE 1 (edge-engine-direct): enumerate the COMPLETE edge id set
    // (bounded-cache-safe) and hydrate each body, instead of iterating the
    // resident `store.edges` map (which under a bounded edge cache would skip
    // evicted edges and produce wrong connected components).
    const uf_edge_ids = try store.allEdgeIds(allocator);
    defer allocator.free(uf_edge_ids);
    for (uf_edge_ids) |__eid| {
        // SONNY-1318 review m-1: read the edge BY VALUE. `getEdgePtrHydrated`
        // hands back a raw `*Edge` into the bounded edge-body cache and the
        // raw `edge_ptr.*` deref happened BEFORE the visibility check, so a
        // concurrent shard-locked edge-create writer resizing that shard could
        // tear the copy. `getEdgeHydrated` copies under the per-shard map lock
        // SHARED — the same accessor `getNeighbors`/`buildNeighborSets` already
        // use, and the one `graph_store.zig` (~:3169) names as safe for an
        // analytical read that overlaps ingest.
        const edge = (try store.getEdgeHydratedChecked(__eid)) orelse continue;

        // SONNY-1318: an invisible edge must not union two components, or a
        // cross-tenant bridge would merge another tenant's nodes into this
        // tenant's component AND introduce that tenant's ids into the result.
        if (!scope.edgeTraversable(store, edge)) continue;

        // Ensure edge endpoints exist in parent map
        if (!parent.contains(edge.from_id)) {
            try parent.put(edge.from_id, edge.from_id);
            try rank.put(edge.from_id, 0);
        }
        if (!parent.contains(edge.to_id)) {
            try parent.put(edge.to_id, edge.to_id);
            try rank.put(edge.to_id, 0);
        }

        const root1_opt = find(&parent, edge.from_id);
        const root2_opt = find(&parent, edge.to_id);

        if (root1_opt != null and root2_opt != null) {
            const root1 = root1_opt.?;
            const root2 = root2_opt.?;
            if (root1 != root2) {
                // Union by rank: attach smaller tree under larger
                const rank1 = rank.get(root1) orelse 0;
                const rank2 = rank.get(root2) orelse 0;
                if (rank1 < rank2) {
                    try parent.put(root1, root2);
                } else if (rank1 > rank2) {
                    try parent.put(root2, root1);
                } else {
                    try parent.put(root2, root1);
                    try rank.put(root1, rank1 + 1);
                }
            }
        }
    }

    var components = std.AutoHashMap(u64, u64).init(allocator);
    defer components.deinit();

    for (node_list.items) |node| {
        if (find(&parent, node)) |root| {
            try components.put(node, root);
        } else {
            try components.put(node, node);
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node_id);
        row[1] = safeU64ToValue(components.get(node_id).?);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

/// Strongly Connected Components (Tarjan's algorithm)
/// Uses only OUTGOING edges (directed) to correctly identify SCCs.
/// Iterative implementation to avoid stack overflow on large graphs.
pub fn executeSCC(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    // Tarjan's state
    var index_map = std.AutoHashMap(u64, u32).init(allocator);
    defer index_map.deinit();
    var lowlink_map = std.AutoHashMap(u64, u32).init(allocator);
    defer lowlink_map.deinit();
    var on_stack = std.AutoHashMap(u64, bool).init(allocator);
    defer on_stack.deinit();
    var component = std.AutoHashMap(u64, u64).init(allocator);
    defer component.deinit();

    // Tarjan stack (not the DFS call stack)
    var tarjan_stack = std.ArrayList(u64).empty;
    defer tarjan_stack.deinit(allocator);

    var index_counter: u32 = 0;
    var comp_id: u64 = 0;

    // Helper to get OUTGOING neighbors only (directed edges)
    const getOutNeighbors = struct {
        fn get(s: *graph_store.GraphStore, node_id: u64, alloc: std.mem.Allocator, filter: *AlgoScope) ![]u64 {
            var out = try std.ArrayList(u64).initCapacity(alloc, 0);
            if ((try s.getOutgoingEdgeIdsOrError(node_id))) |out_edge_ids| {
                for (out_edge_ids) |edge_id| {
                    if (s.edges.get(edge_id)) |edge| {
                        // SONNY-1318 / SONNY-2685: same visibility rule as getNeighbors.
                        if (!filter.edgeTraversable(s, edge)) continue;
                        try out.append(alloc, edge.to_id);
                    }
                }
            }
            return try out.toOwnedSlice(alloc);
        }
    }.get;

    // Iterative Tarjan's algorithm using an explicit DFS call stack.
    // Each frame stores: node, its outgoing neighbors, current neighbor index.
    const Frame = struct {
        node: u64,
        neighbors: []u64,
        neighbor_idx: usize,
    };

    for (node_list.items) |start_node| {
        if (index_map.contains(start_node)) continue;

        // Begin iterative strongconnect from start_node
        var call_stack = std.ArrayList(Frame).empty;
        defer call_stack.deinit(allocator);

        // Initialize start_node
        try index_map.put(start_node, index_counter);
        try lowlink_map.put(start_node, index_counter);
        index_counter += 1;
        try tarjan_stack.append(allocator, start_node);
        try on_stack.put(start_node, true);

        const start_neighbors = try getOutNeighbors(store, start_node, allocator, scope);
        try call_stack.append(allocator, .{
            .node = start_node,
            .neighbors = start_neighbors,
            .neighbor_idx = 0,
        });

        while (call_stack.items.len > 0) {
            var frame = &call_stack.items[call_stack.items.len - 1];

            if (frame.neighbor_idx < frame.neighbors.len) {
                const w = frame.neighbors[frame.neighbor_idx];
                frame.neighbor_idx += 1;

                if (!index_map.contains(w)) {
                    // w has not been visited; push new frame (recurse)
                    try index_map.put(w, index_counter);
                    try lowlink_map.put(w, index_counter);
                    index_counter += 1;
                    try tarjan_stack.append(allocator, w);
                    try on_stack.put(w, true);

                    const w_neighbors = try getOutNeighbors(store, w, allocator, scope);
                    try call_stack.append(allocator, .{
                        .node = w,
                        .neighbors = w_neighbors,
                        .neighbor_idx = 0,
                    });
                } else if (on_stack.get(w) orelse false) {
                    // w is on stack, update lowlink
                    const v_lowlink = lowlink_map.get(frame.node).?;
                    const w_index = index_map.get(w).?;
                    try lowlink_map.put(frame.node, @min(v_lowlink, w_index));
                }
            } else {
                // Done processing all neighbors of this frame's node
                const finished = call_stack.pop().?;
                // Free the neighbor list for this frame
                allocator.free(finished.neighbors);

                // If this is not the bottom frame, propagate lowlink to parent
                if (call_stack.items.len > 0) {
                    const parent_frame = &call_stack.items[call_stack.items.len - 1];
                    const parent_lowlink = lowlink_map.get(parent_frame.node).?;
                    const finished_lowlink = lowlink_map.get(finished.node).?;
                    try lowlink_map.put(parent_frame.node, @min(parent_lowlink, finished_lowlink));
                }

                // If finished.node is a root of an SCC
                if (lowlink_map.get(finished.node).? == index_map.get(finished.node).?) {
                    // Pop from tarjan_stack until we reach finished.node
                    while (tarjan_stack.items.len > 0) {
                        const w_opt = tarjan_stack.pop();
                        if (w_opt == null) break;
                        const w = w_opt.?;
                        try on_stack.put(w, false);
                        try component.put(w, comp_id);
                        if (w == finished.node) break;
                    }
                    comp_id += 1;
                }
            }
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node_id);
        row[1] = safeU64ToValue(component.get(node_id) orelse 0);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-HARMONIC-001; FEATURE="HarmonicCentrality"; ASPECT=Centrality; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Harmonic Centrality - sum of reciprocal distances (handles disconnected graphs better than closeness)
pub fn executeHarmonicCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();

        var queue = std.ArrayList(u64).empty;
        defer queue.deinit(allocator);

        try distances.put(node_id, 0);
        try queue.append(allocator, node_id);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const neighbors = try getNeighbors(store, current, allocator, scope);
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
        row[0] = safeU64ToValue(node_id);
        row[1] = scoreToDecimal(harmonic);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-BRIDGE-LEV-001; FEATURE="BridgeLeverageCentrality"; ASPECT=Centrality; STATUS=EXEMPT; OWNER=graph; UPDATED=2026-01-03
/// Bridge/Leverage Centrality - measures how much removing a node would disconnect the graph
pub fn executeBridgeLeverageCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, i| {
        // Count components with the node vs without
        // Get neighbors of this node
        const neighbors = try getNeighbors(store, node_id, allocator, scope);
        defer allocator.free(neighbors);

        // Bridge leverage = neighbors * (1 / degree) - measures local bridging
        const degree = neighbors.len;
        const leverage: f64 = if (degree > 0)
            @as(f64, @floatFromInt(degree)) / @as(f64, @floatFromInt(node_list.items.len))
        else
            0.0;

        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node_id);
        row[1] = scoreToDecimal(leverage);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-GREY-CARDINAL-001; FEATURE="GreyCardinalComposite"; ASPECT=Centrality; STATUS=EXEMPT; OWNER=graph; UPDATED=2026-01-03
/// Grey Cardinal Composite - combines multiple centrality metrics
pub fn executeGreyCardinalComposite(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    // Compute degree centrality
    var degree_map = std.AutoHashMap(u64, f64).init(allocator);
    defer degree_map.deinit();

    // Compute closeness centrality
    var closeness_map = std.AutoHashMap(u64, f64).init(allocator);
    defer closeness_map.deinit();

    for (node_list.items) |node_id| {
        // Degree
        const neighbors = try getNeighbors(store, node_id, allocator, scope);
        defer allocator.free(neighbors);
        try degree_map.put(node_id, @as(f64, @floatFromInt(neighbors.len)));

        // Closeness via BFS
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();
        var queue = std.ArrayList(u64).empty;
        defer queue.deinit(allocator);

        try distances.put(node_id, 0);
        try queue.append(allocator, node_id);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const current_neighbors = try getNeighbors(store, current, allocator, scope);
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
        row[0] = safeU64ToValue(node_id);
        row[1] = scoreToDecimal(composite);
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-LEIDEN-001; FEATURE="LeidenCommunityDetection"; ASPECT=Community; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Leiden Algorithm - improved community detection (similar to Louvain but with refinement)
pub fn executeLeidenCommunities(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

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
            const neighbors = try getNeighbors(store, node, allocator, scope);
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
                const neighbors = try getNeighbors(store, node, allocator, scope);
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
        row[0] = safeU64ToValue(node_id);
        row[1] = safeU64ToValue(communities.get(node_id).?);
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-ARTICULATION-001; FEATURE="ArticulationPoints"; ASPECT=Connectivity; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Find Articulation Points (cut vertices) - nodes whose removal disconnects the graph
pub fn executeArticulationPoints(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

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

        var stack = std.ArrayList(struct { node: u64, neighbor_idx: usize, child_count: u32 }).empty;
        defer stack.deinit(allocator);

        try stack.append(allocator, .{ .node = start_node, .neighbor_idx = 0, .child_count = 0 });
        try disc.put(start_node, time_counter);
        try low.put(start_node, time_counter);
        time_counter += 1;

        while (stack.items.len > 0) {
            var current = &stack.items[stack.items.len - 1];
            const neighbors = try getNeighbors(store, current.node, allocator, scope);
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
    var result_list = std.ArrayList(u64).empty;
    defer result_list.deinit(allocator);

    for (node_list.items) |node| {
        if (is_articulation.get(node).?) {
            try result_list.append(allocator, node);
        }
    }

    var rows = try allocator.alloc([]Value, result_list.items.len);
    for (result_list.items, 0..) |node_id, idx| {
        var row = try allocator.alloc(Value, 1);
        row[0] = safeU64ToValue(node_id);
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-BRIDGES-001; FEATURE="BridgeEdges"; ASPECT=Connectivity; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Find Bridge Edges (cut edges) - edges whose removal disconnects the graph
pub fn executeBridges(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

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

    var bridges = std.ArrayList(struct { source: u64, target: u64 }).empty;
    defer bridges.deinit(allocator);

    var time_counter: i32 = 0;

    for (node_list.items) |start_node| {
        if (disc.get(start_node).? != -1) continue;

        var stack = std.ArrayList(struct { node: u64, neighbor_idx: usize }).empty;
        defer stack.deinit(allocator);

        try stack.append(allocator, .{ .node = start_node, .neighbor_idx = 0 });
        try disc.put(start_node, time_counter);
        try low.put(start_node, time_counter);
        time_counter += 1;

        while (stack.items.len > 0) {
            var current = &stack.items[stack.items.len - 1];
            const neighbors = try getNeighbors(store, current.node, allocator, scope);
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
        row[0] = safeU64ToValue(bridge.source);
        row[1] = safeU64ToValue(bridge.target);
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-BICONNECTED-001; FEATURE="BiconnectedComponents"; ASPECT=Connectivity; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-04-01
/// Find Biconnected Components using iterative Tarjan's algorithm.
/// A biconnected component is a maximal subgraph such that removing any single
/// vertex does not disconnect it. The algorithm identifies articulation points
/// via DFS discovery/low arrays and an edge stack. Each node is assigned the
/// lowest-numbered biconnected component it belongs to (articulation points
/// participate in multiple components but are reported once with their lowest).
pub fn executeBiconnectedComponents(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    // Collect all node IDs
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    const n = node_list.items.len;

    // Edge case: empty graph
    if (n == 0) {
        const rows = try allocator.alloc([]Value, 0);
        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // disc[v] = discovery time, -1 means unvisited
    var disc = std.AutoHashMap(u64, i32).init(allocator);
    defer disc.deinit();
    // low[v] = lowest discovery time reachable from subtree rooted at v
    var low = std.AutoHashMap(u64, i32).init(allocator);
    defer low.deinit();
    // parent[v] in the DFS tree, null if root or unvisited
    var parent = std.AutoHashMap(u64, ?u64).init(allocator);
    defer parent.deinit();

    for (node_list.items) |node| {
        try disc.put(node, -1);
        try low.put(node, -1);
        try parent.put(node, null);
    }

    // Edge stack entry: (u, v) representing an undirected edge traversed during DFS
    const EdgeEntry = struct { u: u64, v: u64 };
    var edge_stack = std.ArrayList(EdgeEntry).empty;
    defer edge_stack.deinit(allocator);

    // DFS stack frame for iterative DFS
    const DfsFrame = struct {
        node: u64,
        neighbor_idx: usize, // index into neighbor list we're currently processing
        neighbors: []u64, // owned neighbor slice for this frame
        child_count: u32, // number of DFS-tree children (for root articulation check)
    };
    var dfs_stack = std.ArrayList(DfsFrame).empty;
    defer {
        // Free any remaining neighbor slices on the stack
        for (dfs_stack.items) |frame| {
            allocator.free(frame.neighbors);
        }
        dfs_stack.deinit(allocator);
    }

    // component[v] = biconnected component id (lowest component the node belongs to)
    var component = std.AutoHashMap(u64, u64).init(allocator);
    defer component.deinit();

    var timer: i32 = 0;
    var comp_id: u64 = 0;

    // Process all connected components of the graph
    for (node_list.items) |start_node| {
        if (disc.get(start_node).? != -1) continue;

        // Initialize DFS from start_node
        try disc.put(start_node, timer);
        try low.put(start_node, timer);
        timer += 1;

        const start_neighbors = try getNeighbors(store, start_node, allocator, scope);
        try dfs_stack.append(allocator, .{
            .node = start_node,
            .neighbor_idx = 0,
            .neighbors = start_neighbors,
            .child_count = 0,
        });

        while (dfs_stack.items.len > 0) {
            var frame = &dfs_stack.items[dfs_stack.items.len - 1];

            if (frame.neighbor_idx < frame.neighbors.len) {
                const u = frame.node;
                const v = frame.neighbors[frame.neighbor_idx];
                frame.neighbor_idx += 1;

                // Skip the parent edge (undirected graph: avoid going back on the edge we came from)
                if (parent.get(u).? != null and parent.get(u).?.? == v) {
                    // Only skip parent once to handle multi-edges correctly.
                    // After skipping, set parent to a sentinel so we don't skip again.
                    // Actually for simplicity with undirected graphs and single-parent tracking,
                    // we just skip if v == parent[u].
                    continue;
                }

                if (disc.get(v).? == -1) {
                    // Tree edge: v is unvisited
                    try parent.put(v, u);
                    try disc.put(v, timer);
                    try low.put(v, timer);
                    timer += 1;
                    frame.child_count += 1;

                    // Push edge onto edge stack
                    try edge_stack.append(allocator, .{ .u = u, .v = v });

                    // Push new DFS frame for v
                    const v_neighbors = try getNeighbors(store, v, allocator, scope);
                    try dfs_stack.append(allocator, .{
                        .node = v,
                        .neighbor_idx = 0,
                        .neighbors = v_neighbors,
                        .child_count = 0,
                    });
                } else {
                    // Back edge: v is already visited and not parent
                    const disc_v = disc.get(v).?;
                    const disc_u = disc.get(u).?;
                    if (disc_v < disc_u) {
                        // Only push back edges going to ancestors (avoid duplicates)
                        try edge_stack.append(allocator, .{ .u = u, .v = v });
                    }
                    // Update low[u]
                    const low_u = low.get(u).?;
                    if (disc_v < low_u) {
                        try low.put(u, disc_v);
                    }
                }
            } else {
                // All neighbors of frame.node processed; pop this frame
                const finished_node = frame.node;
                const finished_child_count = frame.child_count;
                allocator.free(frame.neighbors);
                _ = dfs_stack.pop();

                if (dfs_stack.items.len > 0) {
                    // We're returning to the parent frame
                    const parent_frame = &dfs_stack.items[dfs_stack.items.len - 1];
                    const p = parent_frame.node;

                    // Update low[p] = min(low[p], low[finished_node])
                    const low_child = low.get(finished_node).?;
                    const low_p = low.get(p).?;
                    if (low_child < low_p) {
                        try low.put(p, low_child);
                    }

                    // Check articulation point condition for non-root:
                    // If low[finished_node] >= disc[p], then p is an articulation point
                    // and edges on the stack down to (p, finished_node) form a biconnected component.
                    const disc_p = disc.get(p).?;
                    if (low_child >= disc_p) {
                        // Pop edges from edge_stack until we pop (p, finished_node)
                        while (edge_stack.items.len > 0) {
                            const e = edge_stack.pop().?;
                            // Assign both endpoints of this edge to this component
                            // (use putNoClobber-like logic: only set if not already assigned)
                            if (!component.contains(e.u)) {
                                try component.put(e.u, comp_id);
                            }
                            if (!component.contains(e.v)) {
                                try component.put(e.v, comp_id);
                            }
                            if (e.u == p and e.v == finished_node) break;
                            if (e.v == p and e.u == finished_node) break;
                        }
                        comp_id += 1;
                    }
                } else {
                    // Root node finished. For the root, check if it's an articulation point
                    // (has 2+ DFS children). But we still need to pop remaining edges.
                    // If root has children but the edge stack still has edges, they form
                    // the last biconnected component(s).
                    // For root with 2+ children, each child subtree's edges were already
                    // popped when the articulation condition triggered. If root has only 1
                    // child, remaining edges form one biconnected component.
                    if (edge_stack.items.len > 0) {
                        while (edge_stack.items.len > 0) {
                            const e = edge_stack.pop().?;
                            if (!component.contains(e.u)) {
                                try component.put(e.u, comp_id);
                            }
                            if (!component.contains(e.v)) {
                                try component.put(e.v, comp_id);
                            }
                        }
                        comp_id += 1;
                    }

                    // Handle isolated root (no edges at all)
                    if (finished_child_count == 0) {
                        if (!component.contains(finished_node)) {
                            try component.put(finished_node, comp_id);
                            comp_id += 1;
                        }
                    }
                }
            }
        }
    }

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node_id, idx| {
        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node_id);
        row[1] = safeU64ToValue(component.get(node_id) orelse 0);
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// ============================================================================
// GRAPH STATISTICS FUNCTIONS (#67)
// ============================================================================

// CANARY: REQ=REQ-GQL-GRAPH-DENSITY-001; FEATURE="GraphDensity"; ASPECT=Statistics; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Graph Density - ratio of actual edges to maximum possible edges
/// For undirected: 2E / (N * (N-1)), for directed: E / (N * (N-1))
pub fn executeGraphDensity(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    // SONNY-1318: density of the graph the session's tenant scope can see.
    const node_count = try visibleNodeCount(store, scope);
    const edge_count = try visibleEdgeCount(store, allocator, scope);

    const density: f64 = if (node_count > 1)
        @as(f64, @floatFromInt(edge_count)) / @as(f64, @floatFromInt(node_count * (node_count - 1)))
    else
        0.0;

    var rows = try allocator.alloc([]Value, 1);
    var row = try allocator.alloc(Value, 1);
    row[0] = scoreToDecimal(density);
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-GRAPH-DIAMETER-001; FEATURE="GraphDiameter"; ASPECT=Statistics; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Graph Diameter - the longest shortest path between any two nodes
pub fn executeGraphDiameter(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    var max_distance: u32 = 0;

    // BFS from each node to find maximum shortest path
    for (node_list.items) |start_node| {
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();

        var queue = std.ArrayList(u64).empty;
        defer queue.deinit(allocator);

        try distances.put(start_node, 0);
        try queue.append(allocator, start_node);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const neighbors = try getNeighbors(store, current, allocator, scope);
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
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-MEAN-DISTANCE-001; FEATURE="MeanDistance"; ASPECT=Statistics; STATUS=EXEMPT; OWNER=graph; UPDATED=2026-01-03
/// Mean Distance (Average Path Length) - average shortest path length between all pairs
pub fn executeMeanDistance(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    var total_distance: f64 = 0.0;
    var pair_count: u64 = 0;

    // BFS from each node
    for (node_list.items) |start_node| {
        var distances = std.AutoHashMap(u64, u32).init(allocator);
        defer distances.deinit();

        var queue = std.ArrayList(u64).empty;
        defer queue.deinit(allocator);

        try distances.put(start_node, 0);
        try queue.append(allocator, start_node);

        var front: usize = 0;
        while (front < queue.items.len) : (front += 1) {
            const current = queue.items[front];
            const current_dist = distances.get(current).?;

            const neighbors = try getNeighbors(store, current, allocator, scope);
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
    row[0] = scoreToDecimal(mean_distance);
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-GLOBAL-CLUSTERING-001; FEATURE="GlobalClusteringCoefficient"; ASPECT=Statistics; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Global Clustering Coefficient - ratio of closed triplets to all triplets
pub fn executeGlobalClusteringCoefficient(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    // Precompute neighbor sets for O(1) adjacency checks instead of
    // O(degree) getNeighbors + linear scan per pair.
    var neighbor_sets = try buildNeighborSets(node_list.items, store, allocator, scope);
    defer deinitNeighborSets(&neighbor_sets);

    var closed_triplets: u64 = 0;
    var total_triplets: u64 = 0;

    for (node_list.items) |node| {
        const neighbors = try getNeighbors(store, node, allocator, scope);
        defer allocator.free(neighbors);

        const degree = neighbors.len;
        if (degree < 2) continue;

        // Number of possible triplets centered at this node
        total_triplets += (degree * (degree - 1)) / 2;

        // Count actual triangles (closed triplets) using O(1) set lookup
        for (neighbors, 0..) |n1, i| {
            const n1_set = neighbor_sets.getPtr(n1) orelse continue;
            for (neighbors[i + 1 ..]) |n2| {
                if (n1_set.contains(n2)) {
                    closed_triplets += 1;
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
    row[0] = scoreToDecimal(clustering);
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// ============================================================================
// KATZ AND HITS CENTRALITY (#69)
// ============================================================================

// CANARY: REQ=REQ-GQL-KATZ-001; FEATURE="KatzCentrality"; ASPECT=Centrality; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Katz Centrality - weighted sum of paths with attenuation factor alpha
/// Katz(i) = sum_k(alpha^k * A^k * 1) where A is adjacency matrix
/// Uses double-buffered flat arrays and precomputed adjacency for O(1) index lookups.
pub fn executeKatzCentrality(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, params: ?std.json.Value, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    const n = node_list.items.len;

    if (n == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
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
                // SONNY-2769: outside u32 the cast aborted the server.
                if (mi == .integer) max_iterations = std.math.cast(u32, mi.integer) orelse return error.InvalidArgs;
            }
            if (p.object.get("tolerance")) |tol| {
                if (tol == .float) tolerance = tol.float;
            }
        }
    }

    // Build node_id -> dense index mapping once
    var node_id_to_index = std.AutoHashMap(u64, usize).init(allocator);
    defer node_id_to_index.deinit();
    for (node_list.items, 0..) |node, idx| {
        try node_id_to_index.put(node, idx);
    }

    // Precompute adjacency once
    var adj = try precomputeAdjacency(store, node_list.items, allocator, scope);
    defer deinitAdjacency(&adj, allocator);

    // Double-buffered flat arrays for Katz scores
    const buf_a = try allocator.alloc(f64, n);
    defer allocator.free(buf_a);
    const buf_b = try allocator.alloc(f64, n);
    defer allocator.free(buf_b);

    // Initialize with beta
    for (buf_a) |*v| v.* = beta;

    var current = buf_a;
    var next = buf_b;

    // Power iteration
    var iteration: u32 = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        for (node_list.items, 0..) |node, idx| {
            var sum: f64 = beta;
            const neighbors = adj.get(node) orelse &[_]u64{};
            for (neighbors) |neighbor| {
                const ni = node_id_to_index.get(neighbor) orelse continue;
                sum += alpha * current[ni];
            }
            next[idx] = sum;
        }

        // Check convergence
        var max_diff: f64 = 0;
        for (0..n) |idx| {
            max_diff = @max(max_diff, @abs(next[idx] - current[idx]));
        }

        // Swap buffers
        const tmp = current;
        current = next;
        next = tmp;

        if (max_diff < tolerance) break;
    }

    var rows = try allocator.alloc([]Value, n);
    for (node_list.items, 0..) |node_id, i| {
        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node_id);
        const score = current[i];
        row[1] = scoreToDecimal(score);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-HITS-001; FEATURE="HITSAlgorithm"; ASPECT=Centrality; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// HITS (Hyperlink-Induced Topic Search) - Kleinberg's algorithm
/// Returns hub and authority scores for each node
pub fn executeHITS(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, params: ?std.json.Value, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    if (node_list.items.len == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    var max_iterations: u32 = 100;
    var tolerance: f64 = 0.0001;

    if (params) |p| {
        if (p == .object) {
            if (p.object.get("maxIterations")) |mi| {
                // SONNY-2769: outside u32 the cast aborted the server.
                if (mi == .integer) max_iterations = std.math.cast(u32, mi.integer) orelse return error.InvalidArgs;
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

    // Build neighbor node-ID lists from adjacency indexes (O(V+E) total,
    // avoids full edge scan that was previously O(E) per call).
    var outgoing = std.AutoHashMap(u64, []const u64).init(allocator);
    defer {
        var out_val_iter = outgoing.valueIterator();
        while (out_val_iter.next()) |val| allocator.free(val.*);
        outgoing.deinit();
    }

    var incoming = std.AutoHashMap(u64, []const u64).init(allocator);
    defer {
        var in_val_iter = incoming.valueIterator();
        while (in_val_iter.next()) |val| allocator.free(val.*);
        incoming.deinit();
    }

    // Temporary lists to collect neighbor node IDs from edge IDs
    var out_tmp = std.ArrayList(u64).empty;
    defer out_tmp.deinit(allocator);
    var in_tmp = std.ArrayList(u64).empty;
    defer in_tmp.deinit(allocator);

    for (node_list.items) |node| {
        out_tmp.clearRetainingCapacity();
        if ((try store.getOutgoingEdgeIdsOrError(node))) |edge_ids| {
            for (edge_ids) |eid| {
                if ((try store.getEdgeHydratedChecked(eid))) |edge| {
                    // SONNY-1318: same visibility rule as getNeighbors.
                    if (!scope.edgeTraversable(store, edge)) continue;
                    try out_tmp.append(allocator, edge.to_id);
                }
            }
        }
        try outgoing.put(node, try allocator.dupe(u64, out_tmp.items));

        in_tmp.clearRetainingCapacity();
        if ((try store.getIncomingEdgeIdsOrError(node))) |edge_ids| {
            for (edge_ids) |eid| {
                if ((try store.getEdgeHydratedChecked(eid))) |edge| {
                    if (!scope.edgeTraversable(store, edge)) continue;
                    try in_tmp.append(allocator, edge.from_id);
                }
            }
        }
        try incoming.put(node, try allocator.dupe(u64, in_tmp.items));
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
            if (incoming.get(node)) |in_nodes| {
                for (in_nodes) |source| {
                    auth_sum += hub.get(source) orelse 1.0;
                }
            }
            try new_authority.put(node, auth_sum);
        }

        // Hub update: hub(p) = sum of auth(q) for all q that p points to
        for (node_list.items) |node| {
            var hub_sum: f64 = 0.0;
            if (outgoing.get(node)) |out_nodes| {
                for (out_nodes) |target| {
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
        row[0] = safeU64ToValue(node_id);
        const hub_score = hub.get(node_id).?;
        const auth_score = authority.get(node_id).?;
        row[1] = scoreToDecimal(hub_score);
        row[2] = scoreToDecimal(auth_score);
        rows[i] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// ============================================================================
// TRIANGLE COUNTING AND CLUSTERING COEFFICIENT (#70)
// ============================================================================

// CANARY: REQ=REQ-GQL-TRIANGLE-COUNT-001; FEATURE="TriangleCounting"; ASPECT=Statistics; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Triangle Counting - count the number of triangles in the graph
pub fn executeTriangleCounting(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    // Precompute neighbor sets for O(1) adjacency checks
    var neighbor_sets = try buildNeighborSets(node_list.items, store, allocator, scope);
    defer deinitNeighborSets(&neighbor_sets);

    var triangle_count: u64 = 0;

    // For each node, check pairs of neighbors using O(1) set lookup
    for (node_list.items) |node| {
        const neighbors = try getNeighbors(store, node, allocator, scope);
        defer allocator.free(neighbors);

        for (neighbors, 0..) |n1, i| {
            // Only count triangles where node < n1 < n2 to avoid triple counting
            if (n1 <= node) continue;

            const n1_set = neighbor_sets.getPtr(n1) orelse continue;
            for (neighbors[i + 1 ..]) |n2| {
                if (n2 <= n1) continue;

                if (n1_set.contains(n2)) {
                    triangle_count += 1;
                }
            }
        }
    }

    var rows = try allocator.alloc([]Value, 1);
    var row = try allocator.alloc(Value, 1);
    row[0] = safeU64ToValue(triangle_count);
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-LOCAL-CLUSTERING-001; FEATURE="LocalClusteringCoefficient"; ASPECT=Statistics; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// Local Clustering Coefficient - for each node, ratio of triangles to possible triangles
pub fn executeLocalClusteringCoefficient(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    // Precompute neighbor sets for O(1) adjacency checks
    var neighbor_sets = try buildNeighborSets(node_list.items, store, allocator, scope);
    defer deinitNeighborSets(&neighbor_sets);

    var rows = try allocator.alloc([]Value, node_list.items.len);
    for (node_list.items, 0..) |node, idx| {
        const neighbors = try getNeighbors(store, node, allocator, scope);
        defer allocator.free(neighbors);

        const degree = neighbors.len;
        var coefficient: f64 = 0.0;

        if (degree >= 2) {
            const possible_triangles = (degree * (degree - 1)) / 2;
            var actual_triangles: u64 = 0;

            // Count edges among neighbors using O(1) set lookup
            for (neighbors, 0..) |n1, i| {
                const n1_set = neighbor_sets.getPtr(n1) orelse continue;
                for (neighbors[i + 1 ..]) |n2| {
                    if (n1_set.contains(n2)) {
                        actual_triangles += 1;
                    }
                }
            }

            coefficient = @as(f64, @floatFromInt(actual_triangles)) / @as(f64, @floatFromInt(possible_triangles));
        }

        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node);
        row[1] = scoreToDecimal(coefficient);
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// ============================================================================
// K-CORE AND K-SHELL DECOMPOSITION (#71)
// ============================================================================

// CANARY: REQ=REQ-GQL-KCORE-001; FEATURE="KCoreDecomposition"; ASPECT=Community; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// K-Core Decomposition using the Batagelj-Zaversnik algorithm: O(V + E).
/// Processes nodes in order of increasing degree using bucket sort. Each node
/// and edge is processed exactly once, replacing the previous O(V * max_degree * V)
/// nested-loop approach.
pub fn executeKCore(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    var node_list = try collectNodeIds(store, allocator, scope);
    defer node_list.deinit(allocator);

    const n = node_list.items.len;

    if (n == 0) {
        return ExecutionResult{
            .columns = columns,
            .rows = try allocator.alloc([]Value, 0),
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    // Precompute adjacency once
    var adj = try precomputeAdjacency(store, node_list.items, allocator, scope);
    defer deinitAdjacency(&adj, allocator);

    // Build dense index mapping
    var node_id_to_index = std.AutoHashMap(u64, usize).init(allocator);
    defer node_id_to_index.deinit();
    for (node_list.items, 0..) |node, idx| {
        try node_id_to_index.put(node, idx);
    }

    // Flat arrays for degree, coreness, and bucket position
    var deg = try allocator.alloc(u32, n);
    defer allocator.free(deg);
    var core = try allocator.alloc(u32, n);
    defer allocator.free(core);
    var pos = try allocator.alloc(usize, n); // position of node in vert array
    defer allocator.free(pos);

    // Initialize degrees
    var max_deg: u32 = 0;
    for (node_list.items, 0..) |node, idx| {
        const neighbors = adj.get(node) orelse &[_]u64{};
        deg[idx] = @intCast(neighbors.len);
        if (deg[idx] > max_deg) max_deg = deg[idx];
    }

    // Bucket sort: bin[d] = count of nodes with degree d
    const bucket_size = max_deg + 1;
    var bin = try allocator.alloc(usize, bucket_size);
    defer allocator.free(bin);
    @memset(bin, 0);

    for (0..n) |idx| {
        bin[deg[idx]] += 1;
    }

    // Prefix sum: bin[d] = starting position in sorted order for degree d
    var start: usize = 0;
    for (0..bucket_size) |d| {
        const count = bin[d];
        bin[d] = start;
        start += count;
    }

    // vert[i] = index of i-th node in sorted order
    var vert = try allocator.alloc(usize, n);
    defer allocator.free(vert);
    for (0..n) |idx| {
        pos[idx] = bin[deg[idx]];
        vert[pos[idx]] = idx;
        bin[deg[idx]] += 1;
    }

    // Restore bin to starting positions (shift right by 1)
    {
        var d: usize = bucket_size;
        while (d > 1) {
            d -= 1;
            bin[d] = bin[d - 1];
        }
        bin[0] = 0;
    }

    // Batagelj-Zaversnik: process nodes in order of increasing degree
    for (0..n) |i| {
        const v_idx = vert[i];
        core[v_idx] = deg[v_idx];
        const v_node = node_list.items[v_idx];
        const neighbors = adj.get(v_node) orelse &[_]u64{};

        for (neighbors) |neighbor| {
            const u_idx = node_id_to_index.get(neighbor) orelse continue;
            if (deg[u_idx] > deg[v_idx]) {
                // Move u to the front of its degree bucket, then shrink the bucket
                const du = deg[u_idx];
                const pu = pos[u_idx];
                const pw = bin[du]; // first position in bucket for degree du
                // Swap vert[pu] and vert[pw]
                if (pu != pw) {
                    const w_idx = vert[pw];
                    vert[pu] = w_idx;
                    vert[pw] = u_idx;
                    pos[w_idx] = pu;
                    pos[u_idx] = pw;
                }
                // Advance the bin boundary and decrement degree
                bin[du] += 1;
                deg[u_idx] -= 1;
            }
        }
    }

    var rows = try allocator.alloc([]Value, n);
    for (node_list.items, 0..) |node_id, idx| {
        var row = try allocator.alloc(Value, 2);
        row[0] = safeU64ToValue(node_id);
        row[1] = Value{ .Int = @intCast(core[idx]) };
        rows[idx] = row;
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-GQL-KSHELL-001; FEATURE="KShellDecomposition"; ASPECT=Community; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=graph; UPDATED=2026-01-03
/// K-Shell Decomposition - nodes are assigned to the shell where they are removed
/// Shell k contains nodes with coreness exactly k (not in k+1 core but in k-core)
pub fn executeKShell(allocator: std.mem.Allocator, store: *graph_store.GraphStore, columns: [][]const u8, scope: *AlgoScope) !ExecutionResult {
    // K-Shell is essentially the same as K-Core but returns shell assignment
    // A node's shell is its coreness value
    return executeKCore(allocator, store, columns, scope);
}
