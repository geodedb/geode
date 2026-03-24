const std = @import("std");
const hnsw_lib = @import("hnsw_lib");

// CANARY: REQ=REQ-PERF-SPICE-014; FEATURE="HNSWSpiceIntegration"; ASPECT=IndexParallelism; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
// Spice fork/join parallelism for batch operations is provided via external caller
// using the SpicePool type. This avoids module import conflicts during build.

// ---------------------------------------------------------------------------
// Compatibility wrapper around the external `hnsw` library.
//
// The external library uses different type names (euclidean vs l2, dot_product
// vs dot) and a Config-based init signature. This module re-exports the
// library under the original Geode API so that no consumers need to change.
// ---------------------------------------------------------------------------

/// Re-export the external library's distance module for direct use.
pub const distance = hnsw_lib.distance;

/// Geode-specific distance metric enum.
/// Preserves the original enum names (.l2, .cosine, .dot, .jaccard).
/// The external library does not support Jaccard natively, so it is
/// computed inline when needed.
pub const DistanceMetric = enum {
    l2,
    cosine,
    dot,
    jaccard,
};

// PERF: PHASE3_HNSW_PREALLOC - Pre-allocate HNSW neighbor lists
// CANARY: REQ=REQ-PERF-PHASE3-002; FEATURE="MemoryOptimization"; ASPECT=HNSW_NEIGHBORS; STATUS=BENCHED; BENCH=benchmarks/phase3_benchmarks.zig; OWNER=performance; UPDATED=2026-01-15
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
    /// Legacy node map keyed by user ID. Kept in sync for persistence (hnsw_persist)
    /// and consumers that iterate or look up by ID.
    nodes: std.AutoHashMap(u64, HnswNode),
    entry_point: ?u64,
    M: u16,
    ef_construction: u16,
    max_level: u8,
    dim: u16,
    seed: u64,
    rng: std.Random.DefaultPrng,

    /// Backing external HNSW index that performs the actual graph search.
    inner: hnsw_lib.Hnsw,

    pub fn init(allocator: std.mem.Allocator, dim: u16, M: u16, ef_construction: u16) Hnsw {
        // The external library validates and may return errors; use sensible
        // clamped defaults so the init signature stays infallible, matching
        // the original Geode API.
        const m_clamped: u16 = if (M < 2) 2 else M;
        const ef_clamped: u16 = if (ef_construction < 1) 1 else ef_construction;
        const dim32: u32 = if (dim == 0) 1 else @as(u32, dim);

        const inner = hnsw_lib.Hnsw.init(allocator, dim32, .euclidean, .{
            .m = m_clamped,
            .ef_construction = ef_clamped,
            .ef_search = ef_clamped,
            .seed = 42,
        }) catch |err| switch (err) {
            // These should not trigger given the clamping above, but
            // handle defensively to keep the non-error return type.
            error.InvalidDimension, error.InvalidConfig => {
                // Fallback: create with safe defaults
                return .{
                    .allocator = allocator,
                    .nodes = std.AutoHashMap(u64, HnswNode).init(allocator),
                    .entry_point = null,
                    .M = m_clamped,
                    .ef_construction = ef_clamped,
                    .max_level = 0,
                    .dim = dim,
                    .seed = 42,
                    .rng = std.Random.DefaultPrng.init(42),
                    .inner = undefined,
                };
            },
            error.OutOfMemory => @panic("OOM during Hnsw.init"),
        };

        return .{
            .allocator = allocator,
            .nodes = std.AutoHashMap(u64, HnswNode).init(allocator),
            .entry_point = null,
            .M = m_clamped,
            .ef_construction = ef_clamped,
            .max_level = 0,
            .dim = dim,
            .seed = 42,
            .rng = std.Random.DefaultPrng.init(42),
            .inner = inner,
        };
    }

    pub fn deinit(self: *Hnsw) void {
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.nodes.deinit();
        self.inner.deinit();
    }

    pub fn insert(self: *Hnsw, id: u64, vector: []const f32) !void {
        if (vector.len != self.dim) return error.DimensionMismatch;

        // Delegate to external library for graph construction.
        try self.inner.insert(id, vector);

        // Mirror into the legacy node map for persistence & ID-based lookup.
        // Use the external library's internal level for the node.
        const level: u8 = blk: {
            // The inner index stores nodes in order of insertion.
            // The node we just inserted is the last one.
            const count = self.inner.count();
            if (count > 0) {
                const node_ref = &self.inner.nodes.items[count - 1];
                break :blk node_ref.level;
            }
            break :blk 0;
        };

        var node = try HnswNode.init(self.allocator, id, vector, level);

        // Copy neighbor lists from the external graph into the legacy format.
        const inner_count = self.inner.count();
        if (inner_count > 0) {
            const inner_node = &self.inner.nodes.items[inner_count - 1];
            for (0..@min(inner_node.connections.len, node.neighbors.len)) |layer| {
                for (inner_node.connections[layer].items) |neighbor_idx| {
                    // Map internal index back to user ID.
                    if (neighbor_idx < inner_count) {
                        const neighbor_id = self.inner.nodes.items[neighbor_idx].id;
                        try node.neighbors[layer].append(self.allocator, neighbor_id);
                    }
                }
            }
        }

        try self.nodes.put(id, node);

        // Sync top-level fields.
        self.max_level = self.inner.max_level;
        if (self.inner.entry_point) |ep_idx| {
            self.entry_point = self.inner.nodes.items[ep_idx].id;
        } else {
            self.entry_point = null;
        }
    }

    // Issue #455: Use external library's knnSearch to avoid recomputing distances
    pub fn knnSearch(self: *const Hnsw, query: []const f32, k: usize, metric: DistanceMetric) ![]struct { id: u64, score: f64 } {
        if (query.len != self.dim) return error.DimensionMismatch;
        if (self.entry_point == null) return &[_]struct { id: u64, score: f64 }{};

        const k_u32: u32 = @intCast(@min(k, std.math.maxInt(u32)));

        // The external library performs search using the metric it was
        // initialised with (euclidean). We get L2 distances back.
        const lib_results = try self.inner.knnSearch(query, k_u32);
        defer self.allocator.free(lib_results);

        const n = @min(k, lib_results.len);
        var results = try self.allocator.alloc(struct { id: u64, score: f64 }, n);

        for (lib_results[0..n], 0..) |r, i| {
            const score: f64 = switch (metric) {
                .cosine => blk: {
                    // Recompute with cosine for correct score.
                    if (self.nodes.get(r.id)) |node| {
                        const d = computeDistanceF64(query, node.vector, .cosine);
                        break :blk 1.0 - d;
                    }
                    break :blk 0.0;
                },
                .dot => blk: {
                    if (self.nodes.get(r.id)) |node| {
                        break :blk computeDistanceF64(query, node.vector, .dot);
                    }
                    break :blk 0.0;
                },
                .jaccard => blk: {
                    if (self.nodes.get(r.id)) |node| {
                        break :blk computeDistanceF64(query, node.vector, .jaccard);
                    }
                    break :blk 0.0;
                },
                .l2 => @as(f64, r.distance),
            };
            results[i] = .{ .id = r.id, .score = score };
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

    /// Batch distance computation for multiple candidate vectors
    /// Uses SIMD for individual distance computations
    /// CANARY: REQ=REQ-PERF-SPICE-015; FEATURE="BatchDistanceSimd"; ASPECT=HNSWBatch; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
    pub fn batchDistanceSimd(
        self: *const Hnsw,
        query: []const f32,
        candidate_ids: []const u64,
        metric: DistanceMetric,
    ) ![]f64 {
        var distances = try self.allocator.alloc(f64, candidate_ids.len);

        for (candidate_ids, 0..) |id, i| {
            if (self.nodes.get(id)) |node| {
                distances[i] = computeDistanceF64(query, node.vector, metric);
            } else {
                distances[i] = std.math.inf(f64);
            }
        }

        return distances;
    }

    /// Parallel batch distance computation - simplified sequential implementation
    /// For full parallel support with spice fork/join, use the spice_wrapper.parallelForEach
    /// CANARY: REQ=REQ-PERF-SPICE-016; FEATURE="ParallelBatchDistance"; ASPECT=HNSWParallel; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
    pub fn batchDistanceParallelSeq(
        self: *const Hnsw,
        query: []const f32,
        candidate_ids: []const u64,
        metric: DistanceMetric,
    ) ![]f64 {
        // Sequential implementation - spice parallelization can be done by the caller
        return self.batchDistanceSimd(query, candidate_ids, metric);
    }

    /// Multi-query kNN search - simplified sequential implementation
    /// For full parallel support with spice fork/join, use spice_wrapper.parallelForEach
    /// CANARY: REQ=REQ-PERF-SPICE-017; FEATURE="ParallelKnnSearch"; ASPECT=HNSWMultiQuery; STATUS=IMPL; OWNER=performance; UPDATED=2026-02-02
    pub fn multiQueryKnnSearch(
        self: *const Hnsw,
        queries: []const []const f32,
        k: usize,
        metric: DistanceMetric,
    ) ![][]struct { id: u64, score: f64 } {
        var all_results = try self.allocator.alloc([]struct { id: u64, score: f64 }, queries.len);

        for (queries, 0..) |query, i| {
            all_results[i] = try self.knnSearch(query, k, metric);
        }

        return all_results;
    }
};

// ---------------------------------------------------------------------------
// Distance helpers
// ---------------------------------------------------------------------------

/// Map Geode DistanceMetric to external library DistanceMetric.
/// Jaccard has no external equivalent and is always computed inline.
pub fn toExternalMetric(metric: DistanceMetric) hnsw_lib.DistanceMetric {
    return switch (metric) {
        .l2 => .euclidean,
        .cosine => .cosine,
        .dot => .dot_product,
        .jaccard => .euclidean, // fallback; Jaccard computed separately
    };
}

/// Compute distance between two f32 vectors returning f64, preserving the
/// original Geode semantics (including Jaccard and SIMD paths).
// CANARY: REQ=REQ-GQL-HNSW-JACCARD-001; FEATURE="Jaccard Distance in HNSW"; ASPECT=IndexMetric; STATUS=TESTED; TEST=tests/test_vector_operations_integration.zig; OWNER=index; UPDATED=2026-01-15
fn computeDistanceF64(a: []const f32, b: []const f32, metric: DistanceMetric) f64 {
    if (a.len != b.len) return std.math.inf(f64);

    switch (metric) {
        .l2 => {
            const d = hnsw_lib.distance.compute(.euclidean, a, b);
            return @as(f64, d);
        },
        .cosine => {
            const d = hnsw_lib.distance.compute(.cosine, a, b);
            return @as(f64, d);
        },
        .dot => {
            const d = hnsw_lib.distance.compute(.dot_product, a, b);
            return @as(f64, d);
        },
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

// ---------------------------------------------------------------------------
// Re-export external library types for consumers that need them directly.
// ---------------------------------------------------------------------------
pub const ExternalHnsw = hnsw_lib.Hnsw;
pub const Config = hnsw_lib.Config;
pub const SearchResult = hnsw_lib.SearchResult;
pub const HnswError = hnsw_lib.HnswError;

// ============================================================================
// Tests
// ============================================================================

test "Hnsw insert and knnSearch basic" {
    const allocator = std.testing.allocator;

    var index = Hnsw.init(allocator, 3, 16, 200);
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1.0, 0.0, 0.0 });
    try index.insert(2, &[_]f32{ 0.0, 1.0, 0.0 });
    try index.insert(3, &[_]f32{ 0.0, 0.0, 1.0 });

    const results = try index.knnSearch(&[_]f32{ 1.0, 0.0, 0.0 }, 2, .l2);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqual(@as(u64, 1), results[0].id);
}

test "Hnsw dimension mismatch on insert" {
    const allocator = std.testing.allocator;

    var index = Hnsw.init(allocator, 3, 16, 200);
    defer index.deinit();

    try std.testing.expectError(error.DimensionMismatch, index.insert(1, &[_]f32{ 1.0, 0.0 }));
}

test "Hnsw dimension mismatch on search" {
    const allocator = std.testing.allocator;

    var index = Hnsw.init(allocator, 3, 16, 200);
    defer index.deinit();

    try std.testing.expectError(error.DimensionMismatch, index.knnSearch(&[_]f32{ 1.0, 0.0 }, 5, .l2));
}

test "Hnsw empty search returns empty" {
    const allocator = std.testing.allocator;

    var index = Hnsw.init(allocator, 3, 16, 200);
    defer index.deinit();

    const results = try index.knnSearch(&[_]f32{ 1.0, 0.0, 0.0 }, 5, .l2);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "Hnsw nodes map maintained" {
    const allocator = std.testing.allocator;

    var index = Hnsw.init(allocator, 2, 4, 50);
    defer index.deinit();

    try index.insert(42, &[_]f32{ 1.0, 2.0 });
    try index.insert(43, &[_]f32{ 3.0, 4.0 });

    try std.testing.expectEqual(@as(u32, 2), index.nodes.count());
    try std.testing.expect(index.nodes.get(42) != null);
    try std.testing.expect(index.nodes.get(43) != null);
    try std.testing.expect(index.entry_point != null);
}

test "Hnsw cosine metric search" {
    const allocator = std.testing.allocator;

    var index = Hnsw.init(allocator, 2, 4, 50);
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1.0, 0.0 });
    try index.insert(2, &[_]f32{ 0.0, 1.0 });
    try index.insert(3, &[_]f32{ 0.707, 0.707 });

    const results = try index.knnSearch(&[_]f32{ 1.0, 0.0 }, 3, .cosine);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 1);
}

test "Hnsw jaccard metric search" {
    const allocator = std.testing.allocator;

    var index = Hnsw.init(allocator, 4, 4, 50);
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1.0, 1.0, 0.0, 0.0 });
    try index.insert(2, &[_]f32{ 1.0, 0.0, 1.0, 0.0 });
    try index.insert(3, &[_]f32{ 0.0, 0.0, 1.0, 1.0 });

    const results = try index.knnSearch(&[_]f32{ 1.0, 1.0, 0.0, 0.0 }, 3, .jaccard);
    defer allocator.free(results);

    try std.testing.expect(results.len >= 1);
}

test "Hnsw batchDistanceSimd" {
    const allocator = std.testing.allocator;

    var index = Hnsw.init(allocator, 3, 4, 50);
    defer index.deinit();

    try index.insert(1, &[_]f32{ 1.0, 0.0, 0.0 });
    try index.insert(2, &[_]f32{ 0.0, 1.0, 0.0 });

    const distances = try index.batchDistanceSimd(&[_]f32{ 1.0, 0.0, 0.0 }, &[_]u64{ 1, 2 }, .l2);
    defer allocator.free(distances);

    try std.testing.expectEqual(@as(usize, 2), distances.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), distances[0], 1e-6);
    try std.testing.expect(distances[1] > 0.0);
}

test "DistanceMetric enum values" {
    // Ensure all expected variants exist
    try std.testing.expect(@intFromEnum(DistanceMetric.l2) != @intFromEnum(DistanceMetric.cosine));
    try std.testing.expect(@intFromEnum(DistanceMetric.dot) != @intFromEnum(DistanceMetric.jaccard));
}

test "HnswNode init and deinit" {
    const allocator = std.testing.allocator;

    var node = try HnswNode.init(allocator, 1, &[_]f32{ 1.0, 2.0, 3.0 }, 2);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1), node.id);
    try std.testing.expectEqual(@as(u8, 2), node.level);
    try std.testing.expectEqual(@as(usize, 3), node.neighbors.len);
    try std.testing.expectEqual(@as(usize, 3), node.vector.len);
}
