const std = @import("std");
const heap = @import("../storage/heap.zig");

pub const MBR = struct {
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,

    pub fn contains(self: MBR, other: MBR) bool {
        return self.min_x <= other.min_x and self.min_y <= other.min_y and
            self.max_x >= other.max_x and self.max_y >= other.max_y;
    }

    pub fn intersects(self: MBR, other: MBR) bool {
        return !(self.max_x < other.min_x or self.min_x > other.max_x or
            self.max_y < other.min_y or self.min_y > other.max_y);
    }

    pub fn area(self: MBR) f64 {
        return (self.max_x - self.min_x) * (self.max_y - self.min_y);
    }

    pub fn union_mbr(self: MBR, other: MBR) MBR {
        return .{
            .min_x = @min(self.min_x, other.min_x),
            .min_y = @min(self.min_y, other.min_y),
            .max_x = @max(self.max_x, other.max_x),
            .max_y = @max(self.max_y, other.max_y),
        };
    }

    pub fn enlargement(self: MBR, other: MBR) f64 {
        const combined = self.union_mbr(other);
        return combined.area() - self.area();
    }
};

pub const RTreeEntry = struct {
    mbr: MBR,
    id: u64,
    child: ?*RTreeNode = null,
};

pub const RTreeNode = struct {
    entries: std.ArrayList(RTreeEntry),
    is_leaf: bool,
    level: u16,

    pub fn init(allocator: std.mem.Allocator, is_leaf: bool, level: u16) RTreeNode {
        return .{
            .entries = std.ArrayList(RTreeEntry).init(allocator),
            .is_leaf = is_leaf,
            .level = level,
        };
    }

    pub fn deinit(self: *RTreeNode, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn computeMBR(self: *const RTreeNode) ?MBR {
        if (self.entries.items.len == 0) return null;

        var mbr = self.entries.items[0].mbr;
        for (self.entries.items[1..]) |entry| {
            mbr = mbr.union_mbr(entry.mbr);
        }
        return mbr;
    }
};

pub const RTree = struct {
    allocator: std.mem.Allocator,
    root: ?*RTreeNode,
    M: u16,
    height: u16,
    count: u64,

    pub fn init(allocator: std.mem.Allocator, M: u16) RTree {
        return .{
            .allocator = allocator,
            .root = null,
            .M = M,
            .height = 0,
            .count = 0,
        };
    }

    pub fn deinit(self: *RTree) void {
        if (self.root) |root| {
            self.deinitNode(root);
        }
    }

    fn deinitNode(self: *RTree, node: *RTreeNode) void {
        if (!node.is_leaf) {
            for (node.entries.items) |entry| {
                if (entry.child) |child| {
                    self.deinitNode(child);
                }
            }
        }
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }

    pub fn insert(self: *RTree, mbr: MBR, id: u64) !void {
        if (self.root == null) {
            self.root = try self.allocator.create(RTreeNode);
            self.root.?.* = RTreeNode.init(self.allocator, true, 0);
            self.height = 1;
        }

        const entry = RTreeEntry{ .mbr = mbr, .id = id };

        if (try self.insertEntry(self.root.?, entry)) |split_entry| {
            var new_root = try self.allocator.create(RTreeNode);
            new_root.* = RTreeNode.init(self.allocator, false, self.root.?.level + 1);

            const old_root_mbr = self.root.?.computeMBR() orelse mbr;
            try new_root.entries.append(.{ .mbr = old_root_mbr, .id = 0, .child = self.root });
            try new_root.entries.append(split_entry);

            self.root = new_root;
            self.height += 1;
        }

        self.count += 1;
    }

    fn insertEntry(self: *RTree, node: *RTreeNode, entry: RTreeEntry) !?RTreeEntry {
        if (node.is_leaf) {
            try node.entries.append(entry);

            if (node.entries.items.len > self.M) {
                return try self.splitNode(node);
            }
            return null;
        }

        var best_idx: usize = 0;
        var best_enlargement = std.math.inf(f64);

        for (node.entries.items, 0..) |e, i| {
            const enlargement = e.mbr.enlargement(entry.mbr);
            if (enlargement < best_enlargement) {
                best_enlargement = enlargement;
                best_idx = i;
            }
        }

        var chosen = &node.entries.items[best_idx];

        if (try self.insertEntry(chosen.child.?, entry)) |split_entry| {
            chosen.mbr = chosen.child.?.computeMBR() orelse entry.mbr;
            try node.entries.append(split_entry);

            if (node.entries.items.len > self.M) {
                return try self.splitNode(node);
            }
        } else {
            chosen.mbr = chosen.mbr.union_mbr(entry.mbr);
        }

        return null;
    }

    fn splitNode(self: *RTree, node: *RTreeNode) !RTreeEntry {
        const m = node.entries.items.len / 2;

        var new_node = try self.allocator.create(RTreeNode);
        new_node.* = RTreeNode.init(self.allocator, node.is_leaf, node.level);

        while (node.entries.items.len > m) {
            try new_node.entries.append(node.entries.pop());
        }

        const new_mbr = new_node.computeMBR() orelse MBR{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 };
        return RTreeEntry{ .mbr = new_mbr, .id = 0, .child = new_node };
    }

    pub fn search(self: *const RTree, query_mbr: MBR, results: *std.ArrayList(u64)) !void {
        if (self.root) |root| {
            try self.searchNode(root, query_mbr, results);
        }
    }

    fn searchNode(self: *const RTree, node: *RTreeNode, query_mbr: MBR, results: *std.ArrayList(u64)) !void {
        for (node.entries.items) |entry| {
            if (entry.mbr.intersects(query_mbr)) {
                if (node.is_leaf) {
                    try results.append(entry.id);
                } else if (entry.child) |child| {
                    try self.searchNode(child, query_mbr, results);
                }
            }
        }
    }

    pub fn remove(self: *RTree, mbr: MBR, id: u64) bool {
        if (self.root == null) return false;

        if (self.removeFromNode(self.root.?, mbr, id)) {
            self.count -= 1;

            if (self.root.?.entries.items.len == 0) {
                self.root.?.deinit();
                self.allocator.destroy(self.root.?);
                self.root = null;
                self.height = 0;
            }

            return true;
        }

        return false;
    }

    fn removeFromNode(self: *RTree, node: *RTreeNode, mbr: MBR, id: u64) bool {
        if (node.is_leaf) {
            for (node.entries.items, 0..) |entry, i| {
                if (entry.id == id and entry.mbr.intersects(mbr)) {
                    _ = node.entries.swapRemove(i);
                    return true;
                }
            }
            return false;
        }

        for (node.entries.items, 0..) |entry, i| {
            if (entry.mbr.intersects(mbr)) {
                if (entry.child) |child| {
                    if (self.removeFromNode(child, mbr, id)) {
                        if (child.entries.items.len == 0) {
                            child.deinit();
                            self.allocator.destroy(child);
                            _ = node.entries.swapRemove(i);
                        } else {
                            node.entries.items[i].mbr = child.computeMBR() orelse mbr;
                        }
                        return true;
                    }
                }
            }
        }

        return false;
    }
};
