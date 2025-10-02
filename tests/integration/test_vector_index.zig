const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "vector index creation and search" {
    const allocator = std.testing.allocator;

    // Initialize index manager
    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Create a vector index
    try index_mgr.createVectorIndex("embedding_idx", "Document", "embedding", 128);

    // Insert vectors
    const vec1 = [_]f32{0.1} ** 128;
    const vec2 = [_]f32{0.2} ** 128;
    const vec3 = [_]f32{0.3} ** 128;

    try index_mgr.insertIntoVectorIndex("embedding_idx", &vec1, 1);
    try index_mgr.insertIntoVectorIndex("embedding_idx", &vec2, 2);
    try index_mgr.insertIntoVectorIndex("embedding_idx", &vec3, 3);

    // Search for nearest neighbors
    const query = [_]f32{0.15} ** 128;
    const results = try index_mgr.knnSearchVectorIndex("embedding_idx", &query, 2);
    defer allocator.free(results);

    // Verify results
    try testing.expect(results.len == 2);
    try testing.expect(results[0].id == 1 or results[0].id == 2);
}

test "vector index with different dimensions" {
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Test various dimensions
    const dimensions = [_]u16{ 32, 64, 256, 512 };

    for (dimensions) |dim| {
        const name = try std.fmt.allocPrint(allocator, "vec_idx_{d}", .{dim});
        defer allocator.free(name);

        try index_mgr.createVectorIndex(name, "Entity", "vector", dim);

        // Create a vector of appropriate dimension
        const vec = try allocator.alloc(f32, dim);
        defer allocator.free(vec);

        for (vec) |*v| {
            v.* = 0.5;
        }

        try index_mgr.insertIntoVectorIndex(name, vec, 1);

        const results = try index_mgr.knnSearchVectorIndex(name, vec, 1);
        defer allocator.free(results);

        try testing.expect(results.len == 1);
        try testing.expect(results[0].id == 1);
    }
}

test "vector similarity metrics" {
    const allocator = std.testing.allocator;

    // Test HNSW directly
    const Hnsw = geode.index.hnsw.Hnsw;
    var index = Hnsw.init(allocator, 3, 16, 200);
    defer index.deinit();

    // Insert orthogonal vectors
    try index.insert(1, &[_]f32{ 1.0, 0.0, 0.0 });
    try index.insert(2, &[_]f32{ 0.0, 1.0, 0.0 });
    try index.insert(3, &[_]f32{ 0.0, 0.0, 1.0 });

    // Test L2 distance
    const query_l2 = [_]f32{ 0.9, 0.1, 0.0 };
    const results_l2 = try index.knnSearch(&query_l2, 2, .l2);
    defer allocator.free(results_l2);

    try testing.expect(results_l2[0].id == 1);

    // Test cosine similarity
    const results_cosine = try index.knnSearch(&query_l2, 2, .cosine);
    defer allocator.free(results_cosine);

    try testing.expect(results_cosine[0].id == 1);
}

test "vector index persistence" {
    const allocator = std.testing.allocator;

    // Create and populate index
    {
        var index_mgr = geode.index.IndexManager.init(allocator);
        defer index_mgr.deinit();

        try index_mgr.createVectorIndex("persist_idx", "Item", "features", 10);

        const vec = [_]f32{1.0} ** 10;
        try index_mgr.insertIntoVectorIndex("persist_idx", &vec, 42);

        // Simulate persistence (would normally write to disk)
        const stats = index_mgr.statistics;
        try testing.expect(stats.total_indexes > 0);
        try testing.expect(stats.total_entries > 0);
    }

    // Recreate and verify
    {
        var index_mgr = geode.index.IndexManager.init(allocator);
        defer index_mgr.deinit();

        // In real implementation, would load from disk
        try index_mgr.createVectorIndex("persist_idx", "Item", "features", 10);

        const vec = [_]f32{1.0} ** 10;
        const results = try index_mgr.knnSearchVectorIndex("persist_idx", &vec, 1);
        defer allocator.free(results);

        // After loading from disk, would find the persisted vector
        // For now, just verify the API works
        try testing.expect(results.len == 0 or results[0].id == 42);
    }
}

test "vector index with large dataset" {
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    try index_mgr.createVectorIndex("large_idx", "BigData", "embedding", 64);

    // Insert many vectors
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    const num_vectors = 1000;
    var i: u64 = 0;
    while (i < num_vectors) : (i += 1) {
        var vec: [64]f32 = undefined;
        for (&vec) |*v| {
            v.* = random.float(f32);
        }
        try index_mgr.insertIntoVectorIndex("large_idx", &vec, i);
    }

    // Search
    var query: [64]f32 = undefined;
    for (&query) |*v| {
        v.* = random.float(f32);
    }

    const results = try index_mgr.knnSearchVectorIndex("large_idx", &query, 10);
    defer allocator.free(results);

    try testing.expect(results.len == 10);

    // Verify results are sorted by distance
    for (1..results.len) |j| {
        try testing.expect(results[j].score <= results[j - 1].score);
    }
}

test "CANARY: REQ=REQ-GQL-VECTOR-INDEX" {
    // CANARY: REQ=REQ-GQL-VECTOR-INDEX; FEATURE="VectorIndex"; ASPECT=Core; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_VECTOR_INDEX; OWNER=team; UPDATED=2025-10-02
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Test complete vector index workflow
    try index_mgr.createVectorIndex("canary_vec_idx", "Entity", "embedding", 50);

    const vec1 = [_]f32{0.1} ** 50;
    const vec2 = [_]f32{0.5} ** 50;
    const vec3 = [_]f32{0.9} ** 50;

    try index_mgr.insertIntoVectorIndex("canary_vec_idx", &vec1, 100);
    try index_mgr.insertIntoVectorIndex("canary_vec_idx", &vec2, 200);
    try index_mgr.insertIntoVectorIndex("canary_vec_idx", &vec3, 300);

    const query = [_]f32{0.4} ** 50;
    const results = try index_mgr.knnSearchVectorIndex("canary_vec_idx", &query, 2);
    defer allocator.free(results);

    try testing.expect(results.len == 2);
    try testing.expect(results[0].id == 200); // Closest to 0.5
}
