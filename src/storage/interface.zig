const std = @import("std");

pub const PageId = u64;
pub const SlotId = u16;

pub const RecordId = struct { page: PageId, slot: SlotId };

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

pub const StorageEngine = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
        csrAddEdge: *const fn (ctx: *anyopaque, src: u64, dst: u64) anyerror!void,
        csrNeighbors: *const fn (ctx: *anyopaque, src: u64) anyerror!NeighborIter,
    };

    pub fn deinit(self: StorageEngine) void { self.vtable.deinit(self.ctx); }
    pub fn csrAddEdge(self: StorageEngine, src: u64, dst: u64) !void { return self.vtable.csrAddEdge(self.ctx, src, dst); }
    pub fn csrNeighbors(self: StorageEngine, src: u64) !NeighborIter { return self.vtable.csrNeighbors(self.ctx, src); }
};
