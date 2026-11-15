// SONNY-6594: make a node or edge body READ fail on demand in a real store.
//
// A store with a data directory keeps every body in its storage engine and
// a bounded cache of the resident ones; a body the cache does not hold is
// rebuilt from the engine on its next read (`getOrHydratePtr`), with the
// cache's own allocator. `BodyFault` evicts bodies (the engine keeps them)
// and wraps both caches' allocators in a `FailingAllocator`, so a rebuild
// fails from a chosen allocation on: the body exists and cannot be read
// (the hydrated getters' error path). Frees still reach the real allocator.
// Nothing is simulated: the store, the engine and the executor are real.

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;

pub const BodyFault = struct {
    st: *graph_store.GraphStore,
    nodes: std.testing.FailingAllocator,
    edges: std.testing.FailingAllocator,
    /// SONNY-6607: the adjacency caches (`outgoing_edges` / `incoming_edges`),
    /// failed only by `adjacencyOn`.
    adj_out: std.testing.FailingAllocator,
    adj_in: std.testing.FailingAllocator,

    /// `self` must not move afterwards (the caches point into it while on).
    pub fn init(self: *BodyFault, st: *graph_store.GraphStore) void {
        self.* = .{
            .st = st,
            .nodes = std.testing.FailingAllocator.init(st.nodes.allocator, .{}),
            .edges = std.testing.FailingAllocator.init(st.edges.allocator, .{}),
            .adj_out = std.testing.FailingAllocator.init(st.outgoing_edges.allocator, .{}),
            .adj_in = std.testing.FailingAllocator.init(st.incoming_edges.allocator, .{}),
        };
    }

    /// Evict every node and edge body (the engine keeps them).
    pub fn evictAll(self: *BodyFault) !void {
        const a = std.testing.allocator;
        const node_ids = try self.st.getAllNodesForTenant(a, null);
        defer a.free(node_ids);
        for (node_ids) |id| self.st.nodes.remove(id);
        const edge_ids = try self.st.allEdgeIds(a);
        defer a.free(edge_ids);
        for (edge_ids) |id| self.st.edges.remove(id);
    }

    /// Evict every other node body carrying `label` in `graph` (the rest stay
    /// resident and readable). Returns how many were evicted.
    pub fn evictHalfOfLabel(self: *BodyFault, graph: []const u8, label: []const u8) usize {
        const ids = self.st.getNodesByLabel(graph, label) orelse return 0;
        var n: usize = 0;
        for (ids, 0..) |id, i| {
            if (i % 2 == 0) continue;
            self.st.nodes.remove(id);
            n += 1;
        }
        return n;
    }

    /// Evict every edge body only.
    pub fn evictEdges(self: *BodyFault) !void {
        const a = std.testing.allocator;
        const edge_ids = try self.st.allEdgeIds(a);
        defer a.free(edge_ids);
        for (edge_ids) |id| self.st.edges.remove(id);
    }

    /// SONNY-6607: evict every node's adjacency lists (the engine keeps them).
    pub fn evictAdjacency(self: *BodyFault) !void {
        const a = std.testing.allocator;
        const node_ids = try self.st.getAllNodesForTenant(a, null);
        defer a.free(node_ids);
        for (node_ids) |id| {
            self.st.outgoing_edges.remove(id);
            self.st.incoming_edges.remove(id);
        }
    }

    /// SONNY-6607: every adjacency rebuild fails from now on (until `off`);
    /// node and edge bodies still rebuild.
    pub fn adjacencyOn(self: *BodyFault) void {
        inline for (.{ &self.adj_out, &self.adj_in }) |f| {
            f.has_induced_failure = false;
            f.fail_index = f.alloc_index;
        }
        self.st.outgoing_edges.allocator = self.adj_out.allocator();
        self.st.incoming_edges.allocator = self.adj_in.allocator();
    }

    /// Every body rebuild fails from now on (until `off`).
    pub fn on(self: *BodyFault) void {
        self.onFrom(0);
    }

    /// Body rebuilds fail from the `k`-th allocation they make on.
    pub fn onFrom(self: *BodyFault, k: usize) void {
        inline for (.{ &self.nodes, &self.edges }) |f| {
            f.has_induced_failure = false;
            f.fail_index = f.alloc_index + k;
        }
        self.st.nodes.allocator = self.nodes.allocator();
        self.st.edges.allocator = self.edges.allocator();
    }

    /// Back to the real allocators. True when a rebuild failed while on.
    pub fn off(self: *BodyFault) bool {
        self.st.nodes.allocator = self.nodes.internal_allocator;
        self.st.edges.allocator = self.edges.internal_allocator;
        self.st.outgoing_edges.allocator = self.adj_out.internal_allocator;
        self.st.incoming_edges.allocator = self.adj_in.internal_allocator;
        inline for (.{ &self.nodes, &self.edges, &self.adj_out, &self.adj_in }) |f| f.fail_index = std.math.maxInt(usize);
        return self.nodes.has_induced_failure or self.edges.has_induced_failure or
            self.adj_out.has_induced_failure or self.adj_in.has_induced_failure;
    }
};
