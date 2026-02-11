// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// UnionFind (Disjoint Set Union) with path compression and union by rank.
/// Elements are addressed by string IDs (e.g., Vertex.ID()).
pub const UnionFind = struct {
    parent: std.StringHashMap([]const u8),
    rank: std.StringHashMap(u32),
    set_size: std.StringHashMap(usize),
    allocator: Allocator,

    pub fn init(allocator: Allocator) UnionFind {
        return .{
            .parent = std.StringHashMap([]const u8).init(allocator),
            .rank = std.StringHashMap(u32).init(allocator),
            .set_size = std.StringHashMap(usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UnionFind) void {
        // Free all duplicated strings in parent map
        var it = self.parent.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.parent.deinit();
        self.rank.deinit();
        self.set_size.deinit();
    }

    /// Make ensures an element exists.
    pub fn make(self: *UnionFind, x: []const u8) !void {
        if (self.parent.contains(x)) return;

        const x_copy = try self.allocator.dupe(u8, x);
        const x_parent = try self.allocator.dupe(u8, x);
        try self.parent.put(x_copy, x_parent);
        try self.rank.put(x_copy, 0);
        try self.set_size.put(x_copy, 1);
    }

    /// Find returns representative of x (creating it if absent).
    /// The returned slice is valid until the next mutation of this UnionFind.
    pub fn find(self: *UnionFind, x: []const u8) ![]const u8 {
        if (!self.parent.contains(x)) {
            try self.make(x);
        }

        // Get the stable key pointer from the map
        const x_key = self.parent.getKey(x) orelse return error.KeyNotFound;
        const parent_val = self.parent.get(x_key) orelse return error.KeyNotFound;

        if (!std.mem.eql(u8, parent_val, x_key)) {
            // Path compression - find root first
            const root = try self.find(parent_val);

            // Now do path compression: point x directly to root
            // Get current parent value to free it
            const old_parent = self.parent.get(x_key) orelse return error.KeyNotFound;

            // Only update if not already pointing to root
            if (!std.mem.eql(u8, old_parent, root)) {
                self.allocator.free(old_parent);
                const root_copy = try self.allocator.dupe(u8, root);
                try self.parent.put(x_key, root_copy);
            }

            // Return the stable key of the root (not the value which may be freed)
            return self.parent.getKey(root) orelse return error.KeyNotFound;
        }

        // x is its own parent (it's a root), return the stable key
        return x_key;
    }

    /// Union merges sets containing a and b; returns true if merged.
    pub fn unite(self: *UnionFind, a: []const u8, b: []const u8) !bool {
        var ra = try self.find(a);
        var rb = try self.find(b);

        if (std.mem.eql(u8, ra, rb)) return false;

        const rank_a = self.rank.get(ra) orelse return error.KeyNotFound;
        const rank_b = self.rank.get(rb) orelse return error.KeyNotFound;

        // Union by rank
        if (rank_a < rank_b) {
            const tmp = ra;
            ra = rb;
            rb = tmp;
        }

        // Update parent - rb now points to ra
        const rb_key = self.parent.getKey(rb) orelse return error.KeyNotFound;
        const old_parent = self.parent.get(rb_key) orelse return error.KeyNotFound;
        self.allocator.free(old_parent);
        const ra_copy = try self.allocator.dupe(u8, ra);
        try self.parent.put(rb_key, ra_copy);

        // Update size
        const ra_key = self.parent.getKey(ra) orelse return error.KeyNotFound;
        const size_a = self.set_size.get(ra_key) orelse return error.KeyNotFound;
        const size_b = self.set_size.get(rb_key) orelse return error.KeyNotFound;
        try self.set_size.put(ra_key, size_a + size_b);

        // Update rank if needed
        if (rank_a == rank_b) {
            try self.rank.put(ra_key, rank_a + 1);
        }

        return true;
    }

    /// Size returns size of set containing x.
    pub fn size(self: *UnionFind, x: []const u8) !usize {
        const root = try self.find(x);
        return self.set_size.get(root) orelse 1;
    }
};
