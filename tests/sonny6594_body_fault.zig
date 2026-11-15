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

    /// `self` must not move afterwards (the caches point into it while on).
    pub fn init(self: *BodyFault, st: *graph_store.GraphStore) void {
        self.* = .{
            .st = st,
            .nodes = std.testing.FailingAllocator.init(st.nodes.allocator, .{}),
            .edges = std.testing.FailingAllocator.init(st.edges.allocator, .{}),
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

    /// Evict every edge body only.
    pub fn evictEdges(self: *BodyFault) !void {
        const a = std.testing.allocator;
        const edge_ids = try self.st.allEdgeIds(a);
        defer a.free(edge_ids);
        for (edge_ids) |id| self.st.edges.remove(id);
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
        self.nodes.fail_index = std.math.maxInt(usize);
        self.edges.fail_index = std.math.maxInt(usize);
        return self.nodes.has_induced_failure or self.edges.has_induced_failure;
    }
};
