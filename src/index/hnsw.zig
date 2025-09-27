const std = @import("std");
const heap = @import("../storage/heap.zig");

pub const DistanceMetric = enum {
    l2,
    cosine,
    dot,
};

pub const HnswNode = struct {
    id: u64,
    vector: []f32,
    neighbors: []std.ArrayList(u64),
    level: u8,

    pub fn init(allocator: std.mem.Allocator, id: u64, vector: []const f32, level: u8) !HnswNode {
        const vec_copy = try allocator.dupe(f32, vector);
        const neighbors = try allocator.alloc(std.ArrayList(u64), level + 1);
        for (neighbors) |*list| {
            list.* = std.ArrayList(u64).init(allocator);
        }

        return .{
            .id = id,
            .vector = vec_copy,
            .neighbors = neighbors,
            .level = level,
        };
    }

    pub fn deinit(self: *HnswNode, allocator: std.mem.Allocator) void {
        for (self.neighbors) |*list| {
            list.deinit();
        }
        allocator.free(self.neighbors);
        allocator.free(self.vector);
    }
};

pub const Hnsw = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(u64, HnswNode),
    entry_point: ?u64,
    M: u16,
    ef_construction: u16,
    max_level: u8,
    dim: u16,
    seed: u64,
    rng: std.rand.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, dim: u16, M: u16, ef_construction: u16) Hnsw {
        return .{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u64, HnswNode).init(allocator),
            .entry_point = null,
            .M = M,
            .ef_construction = ef_construction,
            .max_level = 0,
            .dim = dim,
            .seed = 42,
            .rng = std.rand.DefaultPrng.init(42),
        };
    }

    pub fn deinit(self: *Hnsw) void {
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    fn selectLevel(self: *Hnsw) u8 {
        var level: u8 = 0;
        const ml = 1.0 / @log(@as(f64, 2.0));
        while (self.rng.random().float(f64) < ml and level < 16) {
            level += 1;
        }
        return level;
    }

    fn distance(self: *const Hnsw, a: []const f32, b: []const f32, metric: DistanceMetric) f64 {
        // CANARY NOTE: metric parameter now actively influences switch below; self reserved for future per-index metric weighting.
        _ = self; // currently unused; kept for potential future use (per-index normalization factors)
        if (a.len != b.len) return std.math.inf(f64);

        switch (metric) {
            .l2 => {
                var sum: f64 = 0;
                for (a, b) |av, bv| {
                    const diff = av - bv;
                    sum += diff * diff;
                }
                return @sqrt(sum);
            },
            .dot => {
                var sum: f64 = 0;
                for (a, b) |av, bv| {
                    sum += av * bv;
                }
                return -sum;
            },
            .cosine => {
                var dot_product: f64 = 0;
                var norm_a: f64 = 0;
                var norm_b: f64 = 0;

                for (a, b) |av, bv| {
                    dot_product += av * bv;
                    norm_a += av * av;
                    norm_b += bv * bv;
                }

                if (norm_a == 0 or norm_b == 0) return std.math.inf(f64);

                const similarity = dot_product / (@sqrt(norm_a) * @sqrt(norm_b));
                return 1.0 - similarity;
            },
        }
    }

    fn distanceSimd(self: *const Hnsw, a: []const f32, b: []const f32, metric: DistanceMetric) f64 {
        if (a.len != b.len or a.len % 4 != 0) {
            return self.distance(a, b, metric);
        }

        const VecType = @Vector(4, f32);
        const n_vecs = a.len / 4;

        switch (metric) {
            .l2 => {
                var sum_vec: VecType = @splat(0);
                var i: usize = 0;
                while (i < n_vecs) : (i += 1) {
                    const a_vec: VecType = a[i * 4 ..][0..4].*;
                    const b_vec: VecType = b[i * 4 ..][0..4].*;
                    const diff = a_vec - b_vec;
                    sum_vec += diff * diff;
                }

                var sum: f64 = 0;
                const sum_arr: [4]f32 = sum_vec;
                for (sum_arr) |v| sum += v;

                return @sqrt(sum);
            },
            else => return self.distance(a, b, metric),
        }
    }

    pub fn insert(self: *Hnsw, id: u64, vector: []const f32) !void {
        if (vector.len != self.dim) return error.DimensionMismatch;

        const level = self.selectLevel();
        var node = try HnswNode.init(self.allocator, id, vector, level);

        if (self.entry_point == null) {
            try self.nodes.put(id, node);
            self.entry_point = id;
            if (level > self.max_level) self.max_level = level;
            return;
        }

        var candidates = std.ArrayList(u64).init(self.allocator);
        defer candidates.deinit();

        var w = std.ArrayList(u64).init(self.allocator);
        defer w.deinit();

        try candidates.append(self.entry_point.?);

        var lc: i32 = @intCast(self.max_level);
        while (lc >= 0) : (lc -= 1) {
            const layer = @as(u8, @intCast(lc));

            if (layer > level) {
                const nearest = try self.searchLayer(vector, candidates.items, 1, layer);
                candidates.clearAndFree();
                for (nearest) |n| try candidates.append(n);
            } else {
                const nearest = try self.searchLayer(vector, candidates.items, self.ef_construction, layer);

                const M = if (layer == 0) self.M * 2 else self.M;
                const neighbors = try self.selectNeighbors(vector, nearest, M);

                for (neighbors) |neighbor| {
                    try node.neighbors[layer].append(neighbor);

                    if (self.nodes.getPtr(neighbor)) |neighbor_node| {
                        try neighbor_node.neighbors[@min(layer, neighbor_node.level)].append(id);

                        const max_neighbors = if (layer == 0) self.M * 2 else self.M;
                        if (neighbor_node.neighbors[@min(layer, neighbor_node.level)].items.len > max_neighbors) {
                            const pruned = try self.selectNeighbors(neighbor_node.vector, neighbor_node.neighbors[@min(layer, neighbor_node.level)].items, max_neighbors);
                            neighbor_node.neighbors[@min(layer, neighbor_node.level)].clearAndFree();
                            for (pruned) |p| {
                                try neighbor_node.neighbors[@min(layer, neighbor_node.level)].append(p);
                            }
                        }
                    }
                }

                candidates.clearAndFree();
                for (nearest) |n| try candidates.append(n);
            }
        }

        try self.nodes.put(id, node);

        if (level > self.max_level) {
            self.max_level = level;
            self.entry_point = id;
        }
    }

    fn searchLayer(self: *const Hnsw, query: []const f32, entry_points: []const u64, ef: u16, layer: u8) ![]u64 {
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var candidates = std.PriorityQueue(struct { id: u64, dist: f64 }, void, struct {
            fn lessThan(_: void, a: @This(), b: @This()) std.math.Order {
                return std.math.order(b.dist, a.dist);
            }
        }.lessThan).init(self.allocator, {});
        defer candidates.deinit();

        var w = std.PriorityQueue(struct { id: u64, dist: f64 }, void, struct {
            fn lessThan(_: void, a: @This(), b: @This()) std.math.Order {
                return std.math.order(a.dist, b.dist);
            }
        }.lessThan).init(self.allocator, {});
        defer w.deinit();

        for (entry_points) |ep| {
            if (self.nodes.get(ep)) |ep_node| {
                const d = self.distanceSimd(query, ep_node.vector, .l2);
                try candidates.add(.{ .id = ep, .dist = d });
                try w.add(.{ .id = ep, .dist = d });
                try visited.put(ep, {});
            }
        }

        while (candidates.count() > 0) {
            const current = candidates.remove();

            if (current.dist > w.peek().?.dist) break;

            if (self.nodes.get(current.id)) |current_node| {
                if (layer <= current_node.level) {
                    for (current_node.neighbors[@min(layer, current_node.level)].items) |neighbor| {
                        if (!visited.contains(neighbor)) {
                            try visited.put(neighbor, {});

                            if (self.nodes.get(neighbor)) |neighbor_node| {
                                const d = self.distanceSimd(query, neighbor_node.vector, .l2);

                                if (d < w.peek().?.dist or w.count() < ef) {
                                    try candidates.add(.{ .id = neighbor, .dist = d });
                                    try w.add(.{ .id = neighbor, .dist = d });

                                    if (w.count() > ef) {
                                        _ = w.remove();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        var result = try self.allocator.alloc(u64, w.count());
        var i: usize = 0;
        while (w.count() > 0) : (i += 1) {
            result[i] = w.remove().id;
        }

        return result;
    }

    fn selectNeighbors(self: *const Hnsw, query: []const f32, candidates: []const u64, M: u16) ![]u64 {
        var sorted = try self.allocator.alloc(struct { id: u64, dist: f64 }, candidates.len);
        defer self.allocator.free(sorted);

        for (candidates, 0..) |c, i| {
            if (self.nodes.get(c)) |node| {
                sorted[i] = .{ .id = c, .dist = self.distanceSimd(query, node.vector, .l2) };
            }
        }

        std.sort.pdq(
            @TypeOf(sorted[0]),
            sorted,
            {},
            struct {
                fn lessThan(_: void, a: @TypeOf(sorted[0]), b: @TypeOf(sorted[0])) bool {
                    return a.dist < b.dist;
                }
            }.lessThan,
        );

        const n = @min(M, sorted.len);
        var result = try self.allocator.alloc(u64, n);
        for (sorted[0..n], 0..) |item, i| {
            result[i] = item.id;
        }

        return result;
    }

    pub fn knnSearch(self: *const Hnsw, query: []const f32, k: usize, metric: DistanceMetric) ![]struct { id: u64, score: f64 } {
        if (query.len != self.dim) return error.DimensionMismatch;
        if (self.entry_point == null) return &[_]struct { id: u64, score: f64 }{};

        const ef = @max(self.ef_construction, @as(u16, @intCast(k)));

        var entry_points = [_]u64{self.entry_point.?};
        const candidates = try self.searchLayer(query, &entry_points, ef, 0);
        defer self.allocator.free(candidates);

        var results = try self.allocator.alloc(struct { id: u64, score: f64 }, @min(k, candidates.len));

        for (candidates[0..results.len], 0..) |c, i| {
            if (self.nodes.get(c)) |node| {
                const dist = self.distanceSimd(query, node.vector, metric);
                results[i] = .{ .id = c, .score = if (metric == .cosine) 1.0 - dist else dist };
            }
        }

        std.sort.pdq(
            @TypeOf(results[0]),
            results,
            {},
            struct {
                fn lessThan(_: void, a: @TypeOf(results[0]), b: @TypeOf(results[0])) bool {
                    return a.score > b.score;
                }
            }.lessThan,
        );

        return results;
    }
};
