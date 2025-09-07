const std = @import("std");
const iface = @import("interface.zig");

pub const InMemory = struct {
    allocator: std.mem.Allocator,
    // adjacency: src -> sorted unique neighbors
    adj: std.AutoHashMap(u64, std.ArrayList(u64)),
    // labels: node id -> set of labels
    labels: std.AutoHashMap(u64, std.StringHashMap(void)),

    pub fn init(ally: std.mem.Allocator) InMemory {
        return .{ .allocator = ally, .adj = std.AutoHashMap(u64, std.ArrayList(u64)).init(ally), .labels = std.AutoHashMap(u64, std.StringHashMap(void)).init(ally) };
    }

    pub fn deinit(self: *InMemory) void {
        var it = self.adj.valueIterator();
        while (it.next()) |lst| lst.*.deinit();
        self.adj.deinit();
        var itl = self.labels.valueIterator();
        while (itl.next()) |m| m.*.deinit();
        self.labels.deinit();
    }

    pub fn addEdge(self: *InMemory, src: u64, dst: u64) !void {
        var gop = try self.adj.getOrPut(src);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        }
        // ensure uniqueness and sorted order on finalize; for now just append
        try gop.value_ptr.append(self.allocator, dst);
    }

    pub fn neighbors(self: *InMemory, src: u64) iface.NeighborIter {
        if (self.adj.get(src)) |lst| {
            var slice = lst.items;
            std.mem.sort(u64, slice, {}, std.sort.asc(u64));
            var w: usize = 0;
            var i: usize = 0;
            while (i < slice.len) : (i += 1) {
                if (w == 0 or slice[i] != slice[w - 1]) {
                    slice[w] = slice[i];
                    w += 1;
                }
            }
            return .{ .items = slice[0..w] };
        }
        return .{ .items = &.{} };
    }

    pub fn addNodeLabel(self: *InMemory, node: u64, label: []const u8) !void {
        var gop = try self.labels.getOrPut(node);
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(self.allocator);
        try gop.value_ptr.put(label, {});
    }

    pub fn hasLabel(self: *InMemory, node: u64, label: []const u8) bool {
        if (self.labels.get(node)) |m| return m.contains(label) else return false;
    }

    pub fn expandLabeled(self: *InMemory, src: u64, label: []const u8) iface.NeighborIter {
        if (self.adj.get(src)) |lst| {
            var tmp = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return .{ .items = &.{} };
            for (lst.items) |nid| {
                if (self.hasLabel(nid, label)) tmp.append(self.allocator, nid) catch {};
            }
            std.mem.sort(u64, tmp.items, {}, std.sort.asc(u64));
            return .{ .items = tmp.toOwnedSlice(self.allocator) catch &.{} };
        }
        return .{ .items = &.{} };
    }

    pub fn expandNHop(self: *InMemory, seed: u64, hops: u32) iface.NeighborIter {
        if (hops == 0) return .{ .items = &.{} };
        var frontier = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return .{ .items = &.{} };
        var next = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return .{ .items = &.{} };
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer frontier.deinit(self.allocator);
        defer next.deinit(self.allocator);
        defer visited.deinit();
        frontier.append(self.allocator, seed) catch {};
        var h: u32 = 0;
        while (h < hops) : (h += 1) {
            next.clearRetainingCapacity();
            var i: usize = 0;
            while (i < frontier.items.len) : (i += 1) {
                const s = frontier.items[i];
                const it = self.neighbors(s);
                var j: usize = 0;
                while (j < it.items.len) : (j += 1) {
                    const nid = it.items[j];
                    if (visited.get(nid) == null) {
                        visited.put(nid, {}) catch {};
                        next.append(self.allocator, nid) catch {};
                    }
                }
            }
            frontier.items = next.items;
        }
        std.mem.sort(u64, frontier.items, {}, std.sort.asc(u64));
        return .{ .items = frontier.toOwnedSlice(self.allocator) catch &.{} };
    }
};
