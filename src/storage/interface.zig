const std = @import("std");

pub const PageId = u64;
pub const SlotId = u16;

pub const RecordId = struct { page: PageId, slot: SlotId };

/// Edge information including destination node and edge ID
/// GAP-0084: Extended to support edge collection in path finding
pub const EdgeInfo = struct {
    dest_node: u64,
    edge_id: u64,
    edge_type: u32 = 0,
};

pub const NeighborIter = struct {
    items: []const u64,
    idx: usize = 0,
    pub fn next(self: *NeighborIter) ?u64 {
        if (self.idx >= self.items.len) return null;
        const v = self.items[self.idx];
        self.idx += 1;
        return v;
    }
};

/// Edge iterator with edge IDs
/// GAP-0084: Supports edge collection during path traversal
pub const EdgeIter = struct {
    items: []const EdgeInfo,
    idx: usize = 0,

    pub fn next(self: *EdgeIter) ?EdgeInfo {
        if (self.idx >= self.items.len) return null;
        const v = self.items[self.idx];
        self.idx += 1;
        return v;
    }

    /// Get edge ID connecting to a specific destination
    pub fn getEdgeTo(self: *const EdgeIter, dest: u64) ?u64 {
        for (self.items) |edge| {
            if (edge.dest_node == dest) return edge.edge_id;
        }
        return null;
    }
};

pub const StorageEngine = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
        csrAddEdge: *const fn (ctx: *anyopaque, src: u64, dst: u64) anyerror!void,
        csrNeighbors: *const fn (ctx: *anyopaque, src: u64) anyerror!NeighborIter,
        // GAP-0084: New edge-aware neighbor lookup
        csrEdges: ?*const fn (ctx: *anyopaque, src: u64) anyerror!EdgeIter = null,
    };

    pub fn deinit(self: StorageEngine) void {
        self.vtable.deinit(self.ctx);
    }
    pub fn csrAddEdge(self: StorageEngine, src: u64, dst: u64) !void {
        return self.vtable.csrAddEdge(self.ctx, src, dst);
    }
    pub fn csrNeighbors(self: StorageEngine, src: u64) !NeighborIter {
        return self.vtable.csrNeighbors(self.ctx, src);
    }
    /// Get edges with edge IDs (GAP-0084)
    pub fn csrEdges(self: StorageEngine, src: u64) !?EdgeIter {
        if (self.vtable.csrEdges) |get_edges| {
            return try get_edges(self.ctx, src);
        }
        return null;
    }
};
