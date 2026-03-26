// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// UnionFind (Disjoint Set Union) with path compression and union by rank.
/// Elements are addressed by string IDs (e.g., Vertex.ID()).
///
/// Internally uses integer-indexed flat arrays for O(1) parent lookups and
/// allocation-free path compression. A StringArrayHashMap provides the
/// string-to-index mapping; the reverse mapping (index-to-string) is obtained
/// via the keys() slice of the ArrayHashMap which is stable and ordered by
/// insertion index.
pub const UnionFind = struct {
    /// Maps string ID -> dense integer index.
    index_map: std.StringArrayHashMap(usize),
    /// parent[i] = index of parent; root when parent[i] == i.
    parent: std.ArrayListUnmanaged(usize),
    /// rank[i] for union by rank heuristic.
    rank: std.ArrayListUnmanaged(u32),
    /// set_size[i] = size of set rooted at i (only meaningful when i is a root).
    set_size: std.ArrayListUnmanaged(usize),
    allocator: Allocator,

    pub fn init(allocator: Allocator) UnionFind {
        return .{
            .index_map = std.StringArrayHashMap(usize).init(allocator),
            .parent = .{},
            .rank = .{},
            .set_size = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UnionFind) void {
        // Free all duplicated key strings owned by the index_map.
        for (self.index_map.keys()) |key| {
            self.allocator.free(key);
        }
        self.index_map.deinit();
        self.parent.deinit(self.allocator);
        self.rank.deinit(self.allocator);
        self.set_size.deinit(self.allocator);
    }

    /// Make ensures an element exists.
    pub fn make(self: *UnionFind, x: []const u8) !void {
        if (self.index_map.contains(x)) return;

        const idx = self.index_map.count();
        const x_copy = try self.allocator.dupe(u8, x);
        try self.index_map.put(x_copy, idx);
        try self.parent.append(self.allocator, idx); // parent[idx] = idx (self-root)
        try self.rank.append(self.allocator, 0);
        try self.set_size.append(self.allocator, 1);
    }

    /// Internal: find root index with iterative path compression.
    /// No allocations -- just integer array writes.
    fn findIndex(self: *UnionFind, idx: usize) usize {
        // Walk to root.
        var current = idx;
        while (self.parent.items[current] != current) {
            current = self.parent.items[current];
        }
        const root = current;

        // Path compression: point every node on the path directly to root.
        current = idx;
        while (self.parent.items[current] != root) {
            const next = self.parent.items[current];
            self.parent.items[current] = root;
            current = next;
        }

        return root;
    }

    /// Find returns representative of x (creating it if absent).
    /// The returned slice is valid until the next mutation of this UnionFind.
    pub fn find(self: *UnionFind, x: []const u8) ![]const u8 {
        if (!self.index_map.contains(x)) {
            try self.make(x);
        }

        const idx = self.index_map.get(x) orelse return error.KeyNotFound;
        const root_idx = self.findIndex(idx);

        // Return the string key at root_idx. The keys() slice of
        // StringArrayHashMap is ordered by insertion index, so keys()[root_idx]
        // gives the string for that index.
        return self.index_map.keys()[root_idx];
    }

    /// Union merges sets containing a and b; returns true if merged.
    pub fn unite(self: *UnionFind, a: []const u8, b: []const u8) !bool {
        // Ensure both exist (find will call make if needed).
        _ = try self.find(a);
        _ = try self.find(b);

        var ra = self.findIndex(self.index_map.get(a).?);
        var rb = self.findIndex(self.index_map.get(b).?);

        if (ra == rb) return false;

        const rank_a = self.rank.items[ra];
        const rank_b = self.rank.items[rb];

        // Union by rank: attach smaller-rank tree under larger-rank root.
        if (rank_a < rank_b) {
            const tmp = ra;
            ra = rb;
            rb = tmp;
        }

        // rb's root becomes ra.
        self.parent.items[rb] = ra;

        // Merge sizes.
        self.set_size.items[ra] += self.set_size.items[rb];

        // If ranks were equal, increment the winner's rank.
        if (rank_a == rank_b) {
            self.rank.items[ra] = rank_a + 1;
        }

        return true;
    }

    /// Size returns size of set containing x.
    pub fn size(self: *UnionFind, x: []const u8) !usize {
        _ = try self.find(x);
        const idx = self.index_map.get(x) orelse return error.KeyNotFound;
        const root_idx = self.findIndex(idx);
        return self.set_size.items[root_idx];
    }
};
