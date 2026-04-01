const std = @import("std");
const heap = @import("../storage/heap.zig");

pub const PatriciaNode = struct {
    bit_index: u16,
    prefix_len: u16,
    child0: ?*PatriciaNode = null,
    child1: ?*PatriciaNode = null,
    payload: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) PatriciaNode {
        _ = allocator;
        return .{
            .bit_index = 0,
            .prefix_len = 0,
            .child0 = null,
            .child1 = null,
            .payload = .empty,
        };
    }

    pub fn deinit(self: *PatriciaNode, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }
};

pub const PatriciaTrie = struct {
    allocator: std.mem.Allocator,
    root: ?*PatriciaNode,
    family: Family,
    node_count: u64,
    key_count: u64,

    pub const Family = enum(u8) {
        v4 = 4,
        v6 = 6,
        both = 255,
    };

    pub const SearchMatch = struct {
        value: u64,
    };

    pub fn init(allocator: std.mem.Allocator, family: Family) PatriciaTrie {
        return .{
            .allocator = allocator,
            .root = null,
            .family = family,
            .node_count = 0,
            .key_count = 0,
        };
    }

    pub fn deinit(self: *PatriciaTrie) void {
        if (self.root) |root| {
            self.deinitNode(root);
        }
    }

    fn deinitNode(self: *PatriciaTrie, node: *PatriciaNode) void {
        if (node.child0) |child| self.deinitNode(child);
        if (node.child1) |child| self.deinitNode(child);
        node.deinit(self.allocator);
        self.allocator.destroy(node);
    }

    pub fn insert(self: *PatriciaTrie, subnet: heap.Subnet, payload: u64) !void {
        const key = switch (subnet.addr) {
            .v4 => |bytes| bytes[0..],
            .v6 => |bytes| bytes[0..],
        };

        if (self.root == null) {
            self.root = try self.allocator.create(PatriciaNode);
            self.root.?.* = PatriciaNode.init(self.allocator);
            self.node_count += 1;
        }

        var current = self.root.?;
        var bit_pos: u16 = 0;

        while (bit_pos < subnet.prefix_len) {
            const byte_idx = bit_pos / 8;
            const bit_idx = @as(u3, @intCast(bit_pos % 8));
            const bit = (key[byte_idx] >> (7 - bit_idx)) & 1;

            if (bit == 0) {
                if (current.child0 == null) {
                    current.child0 = try self.allocator.create(PatriciaNode);
                    current.child0.?.* = PatriciaNode.init(self.allocator);
                    self.node_count += 1;
                }
                current = current.child0.?;
            } else {
                if (current.child1 == null) {
                    current.child1 = try self.allocator.create(PatriciaNode);
                    current.child1.?.* = PatriciaNode.init(self.allocator);
                    self.node_count += 1;
                }
                current = current.child1.?;
            }
            bit_pos += 1;
        }

        try current.payload.append(self.allocator, payload);
        self.key_count += 1;
    }

    pub fn longestPrefixMatch(self: *const PatriciaTrie, ip: heap.IpAddr) ?heap.Subnet {
        if (self.root == null) return null;

        const key = switch (ip) {
            .v4 => |bytes| bytes[0..],
            .v6 => |bytes| bytes[0..],
        };

        var current = self.root.?;
        var best_match: ?heap.Subnet = null;
        var bit_pos: u16 = 0;
        const max_bits: u16 = if (ip == .v4) 32 else 128;

        while (bit_pos < max_bits) {
            if (current.payload.items.len > 0) {
                best_match = .{ .addr = ip, .prefix_len = @intCast(bit_pos) };
            }

            const byte_idx = bit_pos / 8;
            const bit_idx = @as(u3, @intCast(bit_pos % 8));
            const bit = (key[byte_idx] >> (7 - bit_idx)) & 1;

            if (bit == 0) {
                if (current.child0) |child| {
                    current = child;
                } else break;
            } else {
                if (current.child1) |child| {
                    current = child;
                } else break;
            }
            bit_pos += 1;
        }

        if (current.payload.items.len > 0) {
            best_match = .{ .addr = ip, .prefix_len = @intCast(bit_pos) };
        }

        return best_match;
    }

    pub fn searchPrefix(self: *const PatriciaTrie, prefix: []const u8, allocator: std.mem.Allocator) ![]SearchMatch {
        if (self.root == null) return try allocator.alloc(SearchMatch, 0);

        var current = self.root.?;
        var bit_pos: usize = 0;
        const max_bits = prefix.len * 8;

        while (bit_pos < max_bits) : (bit_pos += 1) {
            const byte_idx = bit_pos / 8;
            const bit_idx = @as(u3, @intCast(bit_pos % 8));
            const bit = (prefix[byte_idx] >> (7 - bit_idx)) & 1;

            if (bit == 0) {
                current = current.child0 orelse return try allocator.alloc(SearchMatch, 0);
            } else {
                current = current.child1 orelse return try allocator.alloc(SearchMatch, 0);
            }
        }

        var results = std.ArrayList(SearchMatch).empty;
        defer results.deinit(allocator);
        try collectMatches(current, &results, allocator);
        return results.toOwnedSlice(allocator);
    }

    fn collectMatches(node: *const PatriciaNode, results: *std.ArrayList(SearchMatch), allocator: std.mem.Allocator) !void {
        for (node.payload.items) |payload| {
            try results.append(allocator, .{ .value = payload });
        }

        if (node.child0) |child| try collectMatches(child, results, allocator);
        if (node.child1) |child| try collectMatches(child, results, allocator);
    }

    pub fn remove(self: *PatriciaTrie, subnet: heap.Subnet, payload: u64) bool {
        if (self.root == null) return false;

        const key = switch (subnet.addr) {
            .v4 => |bytes| bytes[0..],
            .v6 => |bytes| bytes[0..],
        };

        var current = self.root.?;
        var bit_pos: u16 = 0;

        while (bit_pos < subnet.prefix_len) {
            const byte_idx = bit_pos / 8;
            const bit_idx = @as(u3, @intCast(bit_pos % 8));
            const bit = (key[byte_idx] >> (7 - bit_idx)) & 1;

            if (bit == 0) {
                if (current.child0) |child| {
                    current = child;
                } else return false;
            } else {
                if (current.child1) |child| {
                    current = child;
                } else return false;
            }
            bit_pos += 1;
        }

        for (current.payload.items, 0..) |item, i| {
            if (item == payload) {
                _ = current.payload.swapRemove(i);
                self.key_count -= 1;
                return true;
            }
        }
        return false;
    }
};
