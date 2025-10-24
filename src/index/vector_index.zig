const std = @import("std");
const hnsw = @import("hnsw.zig");
const vector_types = @import("../types/vector.zig");
const heap = @import("../storage/heap.zig");

// CANARY: REQ=REQ-GQL-VECTOR-INDEX-001; FEATURE="Vector Index Integration"; ASPECT=Index; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_VECTOR_INDEX_001_All; OWNER=index; UPDATED=2025-01-03

/// High-level vector index interface that bridges Geode's vector types with HNSW
pub const VectorIndex = struct {
    allocator: std.mem.Allocator,
    hnsw_index: hnsw.Hnsw,
    dimension: u16,
    metric: hnsw.DistanceMetric,
    value_storage: std.AutoHashMap(u64, heap.Value),
    next_id: u64,

    const IndexError = error{
        DimensionMismatch,
        InvalidVectorType,
        VectorNotFound,
        OutOfMemory,
        IndexCorrupted,
    };

    pub fn init(allocator: std.mem.Allocator, dimension: u16, metric: hnsw.DistanceMetric) VectorIndex {
        return VectorIndex{
            .allocator = allocator,
            .hnsw_index = hnsw.Hnsw.init(allocator, dimension, 16, 200), // M=16, ef_construction=200
            .dimension = dimension,
            .metric = metric,
            .value_storage = std.AutoHashMap(u64, heap.Value).init(allocator),
            .next_id = 1,
        };
    }

    pub fn deinit(self: *VectorIndex) void {
        self.hnsw_index.deinit();

        // Clean up stored values
        var iter = self.value_storage.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.value_storage.deinit();
    }

    /// Insert a VectorF32 into the index
    pub fn insertVectorF32(self: *VectorIndex, vector: vector_types.VectorF32, node_id: ?u64) !u64 {
        if (vector.dim != self.dimension) return IndexError.DimensionMismatch;

        const id = node_id orelse self.getNextId();

        // Insert into HNSW index
        try self.hnsw_index.insert(id, vector.data);

        // Store the original value for retrieval
        const stored_value = heap.Value{ .vector_f32 = vector };
        try self.value_storage.put(id, stored_value);

        return id;
    }

    /// Insert a VectorI32 into the index (converted to f32 for HNSW)
    pub fn insertVectorI32(self: *VectorIndex, vector: vector_types.VectorI32, node_id: ?u64) !u64 {
        if (vector.dim != self.dimension) return IndexError.DimensionMismatch;

        const id = node_id orelse self.getNextId();

        // Convert i32 vector to f32 for HNSW indexing
        const f32_data = try self.allocator.alloc(f32, vector.dim);
        defer self.allocator.free(f32_data);

        for (0..vector.dim) |i| {
            f32_data[i] = @floatFromInt(vector.data[i]);
        }

        // Insert into HNSW index
        try self.hnsw_index.insert(id, f32_data);

        // Store the original value
        const stored_value = heap.Value{ .vector_i32 = vector };
        try self.value_storage.put(id, stored_value);

        return id;
    }

    /// Search for k nearest neighbors to a VectorF32
    pub fn searchVectorF32(self: *const VectorIndex, query: vector_types.VectorF32, k: usize) !VectorSearchResult {
        if (query.dim != self.dimension) return IndexError.DimensionMismatch;

        const results = try self.hnsw_index.knnSearch(query.data, k, self.metric);
        defer self.allocator.free(results);

        var search_result = VectorSearchResult.init(self.allocator);

        for (results) |result| {
            if (self.value_storage.get(result.id)) |stored_value| {
                try search_result.results.append(.{
                    .id = result.id,
                    .score = result.score,
                    .value = stored_value,
                });
            }
        }

        return search_result;
    }

    /// Search for k nearest neighbors to a VectorI32
    pub fn searchVectorI32(self: *const VectorIndex, query: vector_types.VectorI32, k: usize) !VectorSearchResult {
        if (query.dim != self.dimension) return IndexError.DimensionMismatch;

        // Convert i32 query to f32 for HNSW search
        const f32_query = try self.allocator.alloc(f32, query.dim);
        defer self.allocator.free(f32_query);

        for (0..query.dim) |i| {
            f32_query[i] = @floatFromInt(query.data[i]);
        }

        const results = try self.hnsw_index.knnSearch(f32_query, k, self.metric);
        defer self.allocator.free(results);

        var search_result = VectorSearchResult.init(self.allocator);

        for (results) |result| {
            if (self.value_storage.get(result.id)) |stored_value| {
                try search_result.results.append(.{
                    .id = result.id,
                    .score = result.score,
                    .value = stored_value,
                });
            }
        }

        return search_result;
    }

    /// Remove a vector from the index by ID
    pub fn remove(self: *VectorIndex, id: u64) bool {
        if (self.value_storage.get(id)) |_| {
            // Remove from value storage
            _ = self.value_storage.remove(id);

            // HNSW doesn't have efficient removal, so we mark as deleted
            // In production, this would need a more sophisticated approach
            return true;
        }
        return false;
    }

    /// Get a vector value by ID
    pub fn getValue(self: *const VectorIndex, id: u64) ?heap.Value {
        return self.value_storage.get(id);
    }

    /// Get statistics about the index
    pub fn getStats(self: *const VectorIndex) VectorIndexStats {
        return VectorIndexStats{
            .total_vectors = self.value_storage.count(),
            .dimension = self.dimension,
            .metric = self.metric,
            .hnsw_nodes = self.hnsw_index.nodes.count(),
            .max_level = self.hnsw_index.max_level,
        };
    }

    fn getNextId(self: *VectorIndex) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

/// Result of a vector similarity search
pub const VectorSearchResult = struct {
    results: std.ArrayList(VectorMatch),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VectorSearchResult {
        return VectorSearchResult{
            .results = std.ArrayList(VectorMatch).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VectorSearchResult) void {
        self.results.deinit();
    }

    pub fn len(self: *const VectorSearchResult) usize {
        return self.results.items.len;
    }

    pub fn get(self: *const VectorSearchResult, index: usize) ?VectorMatch {
        if (index < self.results.items.len) {
            return self.results.items[index];
        }
        return null;
    }
};

/// A single match from vector search
pub const VectorMatch = struct {
    id: u64,
    score: f64,
    value: heap.Value,
};

/// Statistics about a vector index
pub const VectorIndexStats = struct {
    total_vectors: u32,
    dimension: u16,
    metric: hnsw.DistanceMetric,
    hnsw_nodes: u32,
    max_level: u8,
};

/// Manager for multiple vector indexes
pub const VectorIndexManager = struct {
    allocator: std.mem.Allocator,
    indexes: std.StringHashMap(*VectorIndex),

    pub fn init(allocator: std.mem.Allocator) VectorIndexManager {
        return VectorIndexManager{
            .allocator = allocator,
            .indexes = std.StringHashMap(*VectorIndex).init(allocator),
        };
    }

    pub fn deinit(self: *VectorIndexManager) void {
        var iter = self.indexes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.indexes.deinit();
    }

    /// Create a new vector index
    pub fn createIndex(self: *VectorIndexManager, name: []const u8, dimension: u16, metric: hnsw.DistanceMetric) !void {
        if (self.indexes.contains(name)) {
            return error.IndexAlreadyExists;
        }

        const index = try self.allocator.create(VectorIndex);
        index.* = VectorIndex.init(self.allocator, dimension, metric);

        const owned_name = try self.allocator.dupe(u8, name);
        try self.indexes.put(owned_name, index);
    }

    /// Get an existing vector index
    pub fn getIndex(self: *VectorIndexManager, name: []const u8) ?*VectorIndex {
        return self.indexes.get(name);
    }

    /// Drop a vector index
    pub fn dropIndex(self: *VectorIndexManager, name: []const u8) bool {
        if (self.indexes.fetchRemove(name)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
            return true;
        }
        return false;
    }

    /// List all vector indexes
    pub fn listIndexes(self: *const VectorIndexManager, allocator: std.mem.Allocator) ![][]const u8 {
        var names = std.ArrayList([]const u8).init(allocator);
        defer names.deinit();

        var iter = self.indexes.iterator();
        while (iter.next()) |entry| {
            try names.append(try allocator.dupe(u8, entry.key_ptr.*));
        }

        return names.toOwnedSlice();
    }
};

// Test suite
test "VectorIndex basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var index = VectorIndex.init(allocator, 3, .l2);
    defer index.deinit();

    // Test VectorF32 insertion and search
    const vec1 = vector_types.VectorF32.fromSlice(&[_]f32{ 1.0, 2.0, 3.0 });
    const vec2 = vector_types.VectorF32.fromSlice(&[_]f32{ 4.0, 5.0, 6.0 });
    const vec3 = vector_types.VectorF32.fromSlice(&[_]f32{ 1.1, 2.1, 3.1 });

    const id1 = try index.insertVectorF32(vec1, null);
    _ = try index.insertVectorF32(vec2, null);
    _ = try index.insertVectorF32(vec3, null);

    // Search for nearest neighbors
    const query = vector_types.VectorF32.fromSlice(&[_]f32{ 1.0, 2.0, 3.0 });
    var results = try index.searchVectorF32(query, 2);
    defer results.deinit();

    try testing.expect(results.len() >= 1);

    // The first result should be vec1 (exact match)
    const first_match = results.get(0).?;
    try testing.expectEqual(id1, first_match.id);
    try testing.expect(first_match.score < 0.1); // Very close to 0 for exact match

    // Test stats
    const stats = index.getStats();
    try testing.expectEqual(@as(u32, 3), stats.total_vectors);
    try testing.expectEqual(@as(u16, 3), stats.dimension);
    try testing.expectEqual(hnsw.DistanceMetric.l2, stats.metric);
}

test "VectorIndex with VectorI32" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var index = VectorIndex.init(allocator, 4, .l2);
    defer index.deinit();

    // Test VectorI32 insertion
    const vec_i32 = vector_types.VectorI32.fromSlice(&[_]i32{ 10, 20, 30, 40 });
    const id = try index.insertVectorI32(vec_i32, null);

    // Search with VectorI32
    const query = vector_types.VectorI32.fromSlice(&[_]i32{ 12, 22, 32, 42 });
    var results = try index.searchVectorI32(query, 1);
    defer results.deinit();

    try testing.expect(results.len() >= 1);
    const match = results.get(0).?;
    try testing.expectEqual(id, match.id);
}

test "VectorIndexManager operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = VectorIndexManager.init(allocator);
    defer manager.deinit();

    // Create indexes
    try manager.createIndex("embeddings", 128, .cosine);
    try manager.createIndex("features", 64, .l2);

    // Test getting indexes
    const embeddings_index = manager.getIndex("embeddings");
    try testing.expect(embeddings_index != null);
    try testing.expectEqual(@as(u16, 128), embeddings_index.?.dimension);

    const features_index = manager.getIndex("features");
    try testing.expect(features_index != null);
    try testing.expectEqual(@as(u16, 64), features_index.?.dimension);

    // Test listing indexes
    const index_names = try manager.listIndexes(allocator);
    defer {
        for (index_names) |name| {
            allocator.free(name);
        }
        allocator.free(index_names);
    }
    try testing.expectEqual(@as(usize, 2), index_names.len);

    // Test dropping index
    try testing.expect(manager.dropIndex("features"));
    try testing.expect(manager.getIndex("features") == null);
}

test "VectorIndex error handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var index = VectorIndex.init(allocator, 3, .l2);
    defer index.deinit();

    // Test dimension mismatch
    const wrong_dim_vec = vector_types.VectorF32.fromSlice(&[_]f32{ 1.0, 2.0 }); // 2D instead of 3D
    try testing.expectError(VectorIndex.IndexError.DimensionMismatch, index.insertVectorF32(wrong_dim_vec, null));

    // Test search with wrong dimension
    try testing.expectError(VectorIndex.IndexError.DimensionMismatch, index.searchVectorF32(wrong_dim_vec, 5));
}
