const std = @import("std");

// CANARY: REQ=REQ-GQL-068; FEATURE="Containers"; ASPECT=UnionFind; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_068_UnionFind; BENCH=BenchmarkCANARY_REQ_GQL_068_UnionFind; OWNER=graph; UPDATED=2025-09-21
// Union-Find / Disjoint Set with path compression + union by rank.
// Contract:
//  - create(capacity) initializes n singleton sets 0..n-1
//  - find(x) returns representative id
//  - union(a,b) merges sets if distinct and returns bool indicating merge occurred
//  - componentCount() tracks remaining disjoint sets

pub const UnionFind = struct {
    parents: []u64,
    rank: []u8,
    count: u64,

    pub fn init(alloc: std.mem.Allocator, n: u64) !UnionFind {
        var p = try alloc.alloc(u64, n);
        var r = try alloc.alloc(u8, n);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            p[i] = i;
            r[i] = 0;
        }
        return .{ .parents = p, .rank = r, .count = n };
    }

    pub fn deinit(self: *UnionFind, alloc: std.mem.Allocator) void {
        alloc.free(self.parents);
        alloc.free(self.rank);
        self.* = undefined;
    }

    pub fn find(self: *UnionFind, x: u64) u64 {
        return self.compress(x);
    }

    fn compress(self: *UnionFind, x: u64) u64 {
        if (self.parents[x] != x) self.parents[x] = self.compress(self.parents[x]);
        return self.parents[x];
    }

    pub fn unite(self: *UnionFind, a: u64, b: u64) bool {
        const ra = self.find(a);
        const rb = self.find(b);
        if (ra == rb) return false;
        // union by rank
        const rra = self.rank[ra];
        const rrb = self.rank[rb];
        if (rra < rrb) {
            self.parents[ra] = rb;
        } else if (rrb < rra) {
            self.parents[rb] = ra;
        } else {
            self.parents[rb] = ra;
            self.rank[ra] += 1;
        }
        self.count -= 1;
        return true;
    }

    pub fn componentCount(self: *const UnionFind) u64 {
        return self.count;
    }
};

test "TestCANARY_REQ_GQL_068_UnionFind basic" {
    var uf = try UnionFind.init(std.testing.allocator, 10);
    defer uf.deinit(std.testing.allocator);
    try std.testing.expect(uf.componentCount() == 10);
    try std.testing.expect(uf.unite(1, 2));
    try std.testing.expect(!uf.unite(1, 2)); // already merged
    try std.testing.expect(uf.find(1) == uf.find(2));
    try std.testing.expect(uf.unite(2, 3));
    try std.testing.expect(uf.componentCount() == 8);
}
