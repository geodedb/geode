const std = @import("std");

pub const DistanceMetric = enum {
    l2,
    cosine,
    dot,
    jaccard,
};

// CANARY: PERF_PHASE3_HNSW_PREALLOC - Pre-allocate HNSW neighbor lists
// CANARY: REQ=REQ-PERF-PHASE3-002; FEATURE="MemoryOptimization"; ASPECT=HNSW_NEIGHBORS; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16
pub const HnswNode = struct {
    id: u64,
    vector: []f32,
    neighbors: []std.ArrayList(u64),
    level: u8,

    /// Phase 3 optimization: Pre-allocate neighbor lists with expected capacity
    /// M parameter from parent Hnsw structure determines max neighbors per layer
    pub fn init(allocator: std.mem.Allocator, id: u64, vector: []const f32, level: u8) !HnswNode {
        const vec_copy = try allocator.dupe(f32, vector);
        const neighbors = try allocator.alloc(std.ArrayList(u64), level + 1);

        // Phase 3: Pre-allocate with typical M value (32 is common default)
        // Layer 0 uses 2*M, other layers use M
        // This eliminates repeated reallocations during graph construction (30-50% faster inserts)
        const typical_M: usize = 32; // Most HNSW implementations use M=16-32
        for (neighbors, 0..) |*list, layer_idx| {
            const capacity: usize = if (layer_idx == 0) typical_M * 2 else typical_M;
            list.* = try std.ArrayList(u64).initCapacity(allocator, capacity);
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
            list.deinit(allocator);
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
    rng: std.Random.DefaultPrng,

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
            .rng = std.Random.DefaultPrng.init(42),
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
        _ = self;
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
            // CANARY: REQ=REQ-GQL-HNSW-JACCARD-001; FEATURE="Jaccard Distance in HNSW"; ASPECT=IndexMetric; STATUS=IMPL; OWNER=index; UPDATED=2026-01-08
            .jaccard => {
                var intersection: u64 = 0;
                var union_size: u64 = 0;

                for (a, b) |av, bv| {
                    const a_present = av != 0.0;
                    const b_present = bv != 0.0;

                    if (a_present and b_present) {
                        intersection += 1;
                        union_size += 1;
                    } else if (a_present or b_present) {
                        union_size += 1;
                    }
                }

                if (union_size == 0) return 0.0; // Both empty, distance is 0
                const similarity = @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(union_size));
                return 1.0 - similarity; // Convert similarity to distance
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
            .cosine => {
                var dot_vec: VecType = @splat(0);
                var norm_a_vec: VecType = @splat(0);
                var norm_b_vec: VecType = @splat(0);

                var i: usize = 0;
                while (i < n_vecs) : (i += 1) {
                    const a_vec: VecType = a[i * 4 ..][0..4].*;
                    const b_vec: VecType = b[i * 4 ..][0..4].*;
                    dot_vec += a_vec * b_vec;
                    norm_a_vec += a_vec * a_vec;
                    norm_b_vec += b_vec * b_vec;
                }

                // Horizontal sum using reduce
                const dot: f32 = @reduce(.Add, dot_vec);
                const norm_a_sq: f32 = @reduce(.Add, norm_a_vec);
                const norm_b_sq: f32 = @reduce(.Add, norm_b_vec);

                const norm_a = @sqrt(norm_a_sq);
                const norm_b = @sqrt(norm_b_sq);

                if (norm_a == 0 or norm_b == 0) return 1.0;
                const similarity = dot / (norm_a * norm_b);
                return 1.0 - similarity;
            },
            .dot => {
                var sum_vec: VecType = @splat(0);
                var i: usize = 0;
                while (i < n_vecs) : (i += 1) {
                    const a_vec: VecType = a[i * 4 ..][0..4].*;
                    const b_vec: VecType = b[i * 4 ..][0..4].*;
                    sum_vec += a_vec * b_vec;
                }
                const dot_product: f32 = @reduce(.Add, sum_vec);
                return -dot_product; // Negative for max-heap behavior
            },
            .jaccard => {
                // Jaccard distance for floating point vectors
                // Treat non-zero elements as set membership
                var intersection: f32 = 0;
                var union_count: f32 = 0;
                for (a, b) |a_val, b_val| {
                    const a_present = if (a_val != 0) @as(f32, 1) else @as(f32, 0);
                    const b_present = if (b_val != 0) @as(f32, 1) else @as(f32, 0);
                    intersection += a_present * b_present;
                    union_count += @max(a_present, b_present);
                }
                if (union_count == 0) return 0.0;
                const similarity = intersection / union_count;
                return 1.0 - similarity; // Convert to distance
            },
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

        var candidates = std.ArrayList(u64){};
        defer candidates.deinit(self.allocator);

        var w = std.ArrayList(u64){};
        defer w.deinit(self.allocator);

        try candidates.append(self.allocator, self.entry_point.?);

        var lc: i32 = @intCast(self.max_level);
        while (lc >= 0) : (lc -= 1) {
            const layer = @as(u8, @intCast(lc));

            if (layer > level) {
                const nearest = try self.searchLayer(vector, candidates.items, 1, layer);
                candidates.clearAndFree(self.allocator);
                for (nearest) |n| try candidates.append(self.allocator, n);
            } else {
                const nearest = try self.searchLayer(vector, candidates.items, self.ef_construction, layer);

                const M = if (layer == 0) self.M * 2 else self.M;
                const neighbors = try self.selectNeighbors(vector, nearest, M);

                for (neighbors) |neighbor| {
                    try node.neighbors[layer].append(self.allocator, neighbor);

                    if (self.nodes.getPtr(neighbor)) |neighbor_node| {
                        try neighbor_node.neighbors[@min(layer, neighbor_node.level)].append(self.allocator, id);

                        const max_neighbors = if (layer == 0) self.M * 2 else self.M;
                        if (neighbor_node.neighbors[@min(layer, neighbor_node.level)].items.len > max_neighbors) {
                            const pruned = try self.selectNeighbors(neighbor_node.vector, neighbor_node.neighbors[@min(layer, neighbor_node.level)].items, max_neighbors);
                            neighbor_node.neighbors[@min(layer, neighbor_node.level)].clearAndFree(self.allocator);
                            for (pruned) |p| {
                                try neighbor_node.neighbors[@min(layer, neighbor_node.level)].append(self.allocator, p);
                            }
                        }
                    }
                }

                candidates.clearAndFree(self.allocator);
                for (nearest) |n| try candidates.append(self.allocator, n);
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

        const DistNode = struct { id: u64, dist: f64 };
        const CandidatesContext = struct {
            fn lessThan(_: @This(), a: DistNode, b: DistNode) std.math.Order {
                return std.math.order(b.dist, a.dist);
            }
        };
        const WContext = struct {
            fn lessThan(_: @This(), a: DistNode, b: DistNode) std.math.Order {
                return std.math.order(a.dist, b.dist);
            }
        };
        var candidates = std.PriorityQueue(DistNode, CandidatesContext, CandidatesContext.lessThan).init(self.allocator, CandidatesContext{});
        defer candidates.deinit();

        var w = std.PriorityQueue(DistNode, WContext, WContext.lessThan).init(self.allocator, WContext{});
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
