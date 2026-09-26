// CANARY: REQ=REQ-SONNY-2685-ALGO-ROW-VISIBILITY; FEATURE="GraphProcedureRowVisibility"; ASPECT=AlgoScope; STATUS=TESTED; TEST=tests/test_sonny2685_algo_rls.zig; OWNER=security; UPDATED=2026-09-26
//
// SONNY-2685: the row visibility every `CALL algo.*` procedure applies.
//
// SONNY-1318 gave the graph procedures (BFS, DFS and Dijkstra in
// `recursion_handler.zig`, and every centrality, community and statistics
// procedure in `centrality_algorithms.zig`) the session's tenant scope, but
// not its RLS policies, and not its graph: they walked `store.nodes`, which
// holds every graph's nodes. So a node or edge a label or expression policy
// hides still took part in every path, distance, degree and score, and a
// node of another graph (the security graph included) could be scored and
// returned.
//
// An `AlgoScope` is the SONNY-2679 traversal scope
// (`match_operations.HopScope`) for one procedure call:
// - a node is visible when it is in the session's graph, passes the tenant
//   scope, and passes the RLS policies (label and expression) of every one
//   of its labels;
// - an edge is traversable when it is in the graph, carries a tenant tag the
//   scope can see, passes the RLS policies on its type, and both of its
//   endpoints are visible (the single edge rule of SONNY-2693).
// A hidden node or edge is neither visited nor returned, so it changes no
// path, distance or score.
//
// `algo_dispatch.execute` makes one per call, before any graph read, and
// every algorithm takes it as a required parameter, so an algorithm that
// forgets it does not compile. Every check runs on the calling thread: the
// RLS checks read the active execution context and the traversal's label
// snapshot, both thread-local, so a worker thread would see neither and
// allow every row. `executeDegreeCentrality` computes every degree the
// scope restricts on the calling thread for that reason.
//
// The v0.8.23 line carries the same scope for the evaluator as
// `eval.RowScope` (SONNY-2691); this one is the execution layer's own,
// reached without the evaluator's indirection.

const std = @import("std");
const graph_store = @import("../graph_store.zig");
const match_operations = @import("match_operations.zig");
const rls = @import("rls");

pub const AlgoScope = struct {
    allocator: std.mem.Allocator,
    /// The RLS scratch row `hop` evaluates each node and edge with.
    rls_row: std.StringHashMap(rls.Value),
    hop: match_operations.HopScope,

    /// The scope of one procedure call on `graph_name` for the session's
    /// tenant scope `tenant_scope` (null: all tenants) and its RLS policies.
    /// It is allocated (`hop` points at `rls_row`); free it with `destroy`.
    pub fn create(allocator: std.mem.Allocator, graph_name: []const u8, tenant_scope: ?[]const u8) std.mem.Allocator.Error!*AlgoScope {
        const self = try allocator.create(AlgoScope);
        self.* = .{
            .allocator = allocator,
            .rls_row = std.StringHashMap(rls.Value).init(allocator),
            .hop = undefined,
        };
        self.hop = match_operations.HopScope.init(allocator, graph_name, tenant_scope, &self.rls_row);
        return self;
    }

    pub fn destroy(self: *AlgoScope) void {
        self.hop.deinit();
        self.rls_row.deinit();
        self.allocator.destroy(self);
    }

    /// The graph the procedure reads.
    pub fn graph(self: *const AlgoScope) []const u8 {
        return self.hop.filter_graph;
    }

    /// The session's tenant scope (null: all tenants).
    pub fn tenant(self: *const AlgoScope) ?[]const u8 {
        return self.hop.filter_tenant;
    }

    /// Does the scope hide anything in the graph (a tenant scope, or an RLS
    /// policy that may deny the session a row)? When it does not, every node
    /// and edge of the graph is visible, and an edge's graph check covers its
    /// endpoints.
    pub fn restricts(self: *const AlgoScope) bool {
        return self.hop.restrictsNodes();
    }

    /// May the procedure visit or return `node`, a node in hand? Decided once
    /// per node and call.
    pub fn nodeVisible(self: *AlgoScope, node: *const graph_store.Node) bool {
        return self.hop.nodeVisibleCached(node);
    }

    /// May the procedure visit or return the node `id`? Decided once per node
    /// and call, on a transient copy that is freed at once (nothing enters the
    /// node cache). A node that resolves nowhere is not visible.
    pub fn nodeIdVisible(self: *AlgoScope, store: *graph_store.GraphStore, id: u64) bool {
        if (self.hop.verdicts.get(id)) |visible| return visible;
        const visible = store.decideOnTransientNode(id, self, decideTransientNode) orelse false;
        // The cache only saves work: a failed insert re-decides next time.
        self.hop.verdicts.put(self.allocator, id, visible) catch {};
        return visible;
    }

    fn decideTransientNode(self: *AlgoScope, node: *const graph_store.Node) bool {
        // The RLS row borrows the transient node's properties: empty it
        // before the node is freed.
        defer self.rls_row.clearRetainingCapacity();
        return self.hop.nodeVisible(node);
    }

    /// May the procedure walk `edge`? Its graph, its tenant tag and the RLS
    /// policies on its type, and both endpoints visible.
    pub fn edgeTraversable(self: *AlgoScope, store: *graph_store.GraphStore, edge: graph_store.Edge) bool {
        if (!self.hop.edgeVisible(&edge)) return false;
        if (!self.restricts()) return true;
        return self.nodeIdVisible(store, edge.from_id) and self.nodeIdVisible(store, edge.to_id);
    }

    /// `edgeTraversable` for an edge id, read by value (`getEdgeHydrated`
    /// copies it under the shard lock). An edge that resolves nowhere is not
    /// traversable.
    pub fn edgeIdTraversable(self: *AlgoScope, store: *graph_store.GraphStore, edge_id: u64) bool {
        const edge = store.getEdgeHydrated(edge_id) orelse return false;
        return self.edgeTraversable(store, edge);
    }
};
