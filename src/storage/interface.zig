const std = @import("std");

pub const RecordId = struct {
    page: u32,
    slot: u16,
};

pub const NodeLocation = struct {
    page: u32,
    slot: u16,
};

pub const PageId = u32;

// Stub for StorageEngine to allow compilation of dependent modules (e.g. match.zig)
pub const NeighborIter = struct {
    items: []const u64,
};

pub const StorageEngine = struct {
    ctx: *anyopaque = undefined,
    vtable: *const VTable = &default_vtable,
    allocator: std.mem.Allocator = undefined,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
        csrAddEdge: *const fn (ctx: *anyopaque, src: u64, dst: u64) anyerror!void,
        csrNeighbors: *const fn (ctx: *anyopaque, src: u64) anyerror!NeighborIter,
    };

    const default_vtable = VTable{
        .deinit = noopDeinit,
        .csrAddEdge = noopAddEdge,
        .csrNeighbors = noopNeighbors,
    };

    fn noopDeinit(ctx: *anyopaque) void {
        _ = ctx;
    }
    fn noopAddEdge(ctx: *anyopaque, src: u64, dst: u64) anyerror!void {
        _ = ctx;
        _ = src;
        _ = dst;
        return error.NotImplemented;
    }
    fn noopNeighbors(ctx: *anyopaque, src: u64) anyerror!NeighborIter {
        _ = ctx;
        _ = src;
        return NeighborIter{ .items = &[_]u64{} };
    }

    pub fn deinit(self: *StorageEngine) void {
        self.vtable.deinit(self.ctx);
    }

    pub fn csrAddEdge(self: *StorageEngine, src: u64, dst: u64) !void {
        return self.vtable.csrAddEdge(self.ctx, src, dst);
    }

    pub fn csrNeighbors(self: *StorageEngine, src: u64) !NeighborIter {
        return self.vtable.csrNeighbors(self.ctx, src);
    }

    pub fn createNode(self: *StorageEngine, tx: *anyopaque, label: []const u8, props: anytype) !u64 {
        _ = self;
        _ = tx;
        _ = label;
        _ = props;
        return 0;
    }

    pub fn createEdge(self: *StorageEngine, tx: *anyopaque, src: u64, dst: u64, edge_type: []const u8, props: anytype) !u64 {
        _ = self;
        _ = tx;
        _ = src;
        _ = dst;
        _ = edge_type;
        _ = props;
        return 0;
    }

    pub const EntityInfo = struct { entity_type: []const u8, label: []const u8 };
    pub fn getEntityInfo(self: *StorageEngine, tx: *anyopaque, id: anytype) !EntityInfo {
        _ = self;
        _ = tx;
        _ = id;
        return EntityInfo{ .entity_type = "node", .label = "default" };
    }

    pub fn getProperties(self: *StorageEngine, tx: *anyopaque, id: anytype) !std.StringHashMap([]const u8) {
        _ = self;
        _ = tx;
        _ = id;
        return error.NotImplemented;
    }

    pub fn updateProperties(self: *StorageEngine, tx: *anyopaque, id: anytype, patch: anytype) !void {
        _ = self;
        _ = tx;
        _ = id;
        _ = patch;
    }

    pub fn deleteEntity(self: *StorageEngine, tx: *anyopaque, id: anytype) !void {
        _ = self;
        _ = tx;
        _ = id;
    }
};
