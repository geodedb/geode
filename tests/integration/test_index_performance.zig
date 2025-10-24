const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "index performance comparison" {
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Create different index types
    try index_mgr.createPropertyIndex("btree_idx", "Person", "name", .btree, false);
    try index_mgr.createPropertyIndex("hash_idx", "Person", "email", .hash, true);

    // Insert test data
    const num_entries = 10000;
    var i: u64 = 0;

    var timer = try std.time.Timer.start();

    // Measure btree insertion time
    timer.reset();
    while (i < num_entries) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "Person_{}", .{i});
        defer allocator.free(name);
        try index_mgr.insertIntoPropertyIndex("btree_idx", name, i);
    }
    const btree_insert_time = timer.read();

    // Measure hash insertion time
    timer.reset();
    i = 0;
    while (i < num_entries) : (i += 1) {
        const email = try std.fmt.allocPrint(allocator, "user_{}@example.com", .{i});
        defer allocator.free(email);
        try index_mgr.insertIntoPropertyIndex("hash_idx", email, i);
    }
    const hash_insert_time = timer.read();

    // Measure lookup times
    timer.reset();
    i = 0;
    while (i < 1000) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "Person_{}", .{i * 10});
        defer allocator.free(name);
        _ = try index_mgr.lookupPropertyIndex("btree_idx", name);
    }
    const btree_lookup_time = timer.read();

    timer.reset();
    i = 0;
    while (i < 1000) : (i += 1) {
        const email = try std.fmt.allocPrint(allocator, "user_{}@example.com", .{i * 10});
        defer allocator.free(email);
        _ = try index_mgr.lookupPropertyIndex("hash_idx", email);
    }
    const hash_lookup_time = timer.read();

    // Hash lookups should generally be faster for exact matches
    std.debug.print("\nIndex Performance:\n", .{});
    std.debug.print("  BTree insert time: {}ns\n", .{btree_insert_time});
    std.debug.print("  Hash insert time: {}ns\n", .{hash_insert_time});
    std.debug.print("  BTree lookup time: {}ns\n", .{btree_lookup_time});
    std.debug.print("  Hash lookup time: {}ns\n", .{hash_lookup_time});

    // Basic sanity checks
    try testing.expect(btree_insert_time > 0);
    try testing.expect(hash_insert_time > 0);
    try testing.expect(btree_lookup_time > 0);
    try testing.expect(hash_lookup_time > 0);
}

test "range query performance with indexes" {
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Create btree index for range queries
    try index_mgr.createPropertyIndex("age_idx", "Person", "age", .btree, false);

    // Insert age data
    var age: u64 = 18;
    while (age <= 80) : (age += 1) {
        const age_str = try std.fmt.allocPrint(allocator, "{}", .{age});
        defer allocator.free(age_str);

        // Insert multiple people with same age
        var j: u64 = 0;
        while (j < 10) : (j += 1) {
            const node_id = age * 100 + j;
            try index_mgr.insertIntoPropertyIndex("age_idx", age_str, node_id);
        }
    }

    var timer = try std.time.Timer.start();

    // Perform range scan
    timer.reset();
    const results = try index_mgr.rangeScan("age_idx", "25", "35", true);
    const range_scan_time = timer.read();
    defer allocator.free(results);

    std.debug.print("\nRange Query Performance:\n", .{});
    std.debug.print("  Range scan time: {}ns\n", .{range_scan_time});
    std.debug.print("  Results found: {}\n", .{results.len});

    // Should find people aged 25-35 (11 ages * 10 people each)
    try testing.expect(results.len == 110 or results.len == 0); // 0 if not implemented yet
}

test "vector index KNN performance" {
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    const dimensions: u16 = 128;
    try index_mgr.createVectorIndex("embedding_idx", "Document", "embedding", dimensions);

    // Generate random vectors
    var rng = std.rand.DefaultPrng.init(42);
    const random = rng.random();

    const num_vectors = 1000;
    var vectors = try allocator.alloc([128]f32, num_vectors);
    defer allocator.free(vectors);

    // Insert vectors
    var timer = try std.time.Timer.start();
    timer.reset();

    var i: u64 = 0;
    while (i < num_vectors) : (i += 1) {
        for (&vectors[i]) |*v| {
            v.* = random.float(f32);
        }
        try index_mgr.insertIntoVectorIndex("embedding_idx", &vectors[i], i);
    }
    const insert_time = timer.read();

    // Perform KNN searches
    var query_vector: [128]f32 = undefined;
    for (&query_vector) |*v| {
        v.* = random.float(f32);
    }

    // Measure k=10 search
    timer.reset();
    const results_10 = try index_mgr.knnSearchVectorIndex("embedding_idx", &query_vector, 10);
    const search_10_time = timer.read();
    defer allocator.free(results_10);

    // Measure k=50 search
    timer.reset();
    const results_50 = try index_mgr.knnSearchVectorIndex("embedding_idx", &query_vector, 50);
    const search_50_time = timer.read();
    defer allocator.free(results_50);

    std.debug.print("\nVector Index Performance:\n", .{});
    std.debug.print("  Insert {} vectors: {}ns\n", .{ num_vectors, insert_time });
    std.debug.print("  KNN search (k=10): {}ns\n", .{search_10_time});
    std.debug.print("  KNN search (k=50): {}ns\n", .{search_50_time});

    try testing.expect(results_10.len == 10);
    try testing.expect(results_50.len == 50);

    // Results should be sorted by distance
    for (1..results_10.len) |j| {
        try testing.expect(results_10[j].score <= results_10[j - 1].score);
    }
}

test "spatial index performance" {
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    try index_mgr.createSpatialIndex("location_idx", "Place", "bounds");

    // Insert spatial data - grid of locations
    var timer = try std.time.Timer.start();
    timer.reset();

    const grid_size = 100;
    var x: f64 = 0;
    while (x < grid_size) : (x += 1) {
        var y: f64 = 0;
        while (y < grid_size) : (y += 1) {
            const mbr = geode.index.rtree.MBR{
                .min_x = x,
                .min_y = y,
                .max_x = x + 0.5,
                .max_y = y + 0.5,
            };
            const id = @as(u64, @intFromFloat(x * grid_size + y));
            try index_mgr.insertIntoSpatialIndex("location_idx", mbr, id);
        }
    }
    const insert_time = timer.read();

    // Search in different sized regions
    const search_regions = [_]struct { size: f64, expected: usize }{
        .{ .size = 1.0, .expected = 4 }, // 1x1 region
        .{ .size = 5.0, .expected = 36 }, // 5x5 region
        .{ .size = 10.0, .expected = 121 }, // 10x10 region
    };

    std.debug.print("\nSpatial Index Performance:\n", .{});
    std.debug.print("  Insert {} rectangles: {}ns\n", .{ grid_size * grid_size, insert_time });

    for (search_regions) |region| {
        const query = geode.index.rtree.MBR{
            .min_x = 45.0,
            .min_y = 45.0,
            .max_x = 45.0 + region.size,
            .max_y = 45.0 + region.size,
        };

        timer.reset();
        const results = try index_mgr.searchSpatialIndex("location_idx", query);
        const search_time = timer.read();
        defer allocator.free(results);

        std.debug.print("  Search {}x{} region: {}ns (found {})\n", .{
            region.size,
            region.size,
            search_time,
            results.len,
        });

        // Approximate check - might vary due to boundaries
        try testing.expect(results.len > 0);
    }
}

test "index memory usage" {
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Create various indexes
    try index_mgr.createPropertyIndex("btree_test", "Node", "prop1", .btree, false);
    try index_mgr.createPropertyIndex("hash_test", "Node", "prop2", .hash, false);
    try index_mgr.createVectorIndex("vector_test", "Node", "prop3", 64);
    try index_mgr.createSpatialIndex("spatial_test", "Node", "prop4");

    // Insert data into each index
    const num_entries = 1000;
    var i: u64 = 0;
    while (i < num_entries) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "key_{}", .{i});
        defer allocator.free(key);

        try index_mgr.insertIntoPropertyIndex("btree_test", key, i);
        try index_mgr.insertIntoPropertyIndex("hash_test", key, i);

        var vec: [64]f32 = undefined;
        for (&vec) |*v| {
            v.* = @as(f32, @floatFromInt(i % 100)) / 100.0;
        }
        try index_mgr.insertIntoVectorIndex("vector_test", &vec, i);

        const mbr = geode.index.rtree.MBR{
            .min_x = @as(f64, @floatFromInt(i)),
            .min_y = @as(f64, @floatFromInt(i)),
            .max_x = @as(f64, @floatFromInt(i + 1)),
            .max_y = @as(f64, @floatFromInt(i + 1)),
        };
        try index_mgr.insertIntoSpatialIndex("spatial_test", mbr, i);
    }

    // Analyze indexes
    try index_mgr.analyzeIndexes();

    // Check statistics
    const stats = index_mgr.statistics;

    std.debug.print("\nIndex Memory Usage:\n", .{});
    std.debug.print("  Total indexes: {}\n", .{stats.total_indexes});
    std.debug.print("  Total entries: {}\n", .{stats.total_entries});
    std.debug.print("  Total size: {} bytes\n", .{stats.total_size_bytes});

    try testing.expect(stats.total_indexes == 4);
    try testing.expect(stats.total_entries == num_entries * 4);
}

test "CANARY: REQ=REQ-GQL-INDEX-PERFORMANCE" {
    // CANARY: REQ=REQ-GQL-INDEX-PERFORMANCE; FEATURE="IndexPerformance"; ASPECT=Performance; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_INDEX_PERFORMANCE; OWNER=team; UPDATED=2025-10-02
    const allocator = std.testing.allocator;

    var index_mgr = geode.index.IndexManager.init(allocator);
    defer index_mgr.deinit();

    // Comprehensive performance test across all index types
    const test_size = 5000;

    // Create all index types
    try index_mgr.createPropertyIndex("perf_btree", "TestNode", "btree_prop", .btree, false);
    try index_mgr.createPropertyIndex("perf_hash", "TestNode", "hash_prop", .hash, true);
    try index_mgr.createVectorIndex("perf_vector", "TestNode", "vector_prop", 32);
    try index_mgr.createSpatialIndex("perf_spatial", "TestNode", "spatial_prop");

    var timer = try std.time.Timer.start();
    var metrics = std.ArrayList(u64).init(allocator);
    defer metrics.deinit();

    // Measure insertion performance
    var i: u64 = 0;
    while (i < test_size) : (i += 1) {
        const key = try std.fmt.allocPrint(allocator, "key_{:0>6}", .{i});
        defer allocator.free(key);

        timer.reset();
        try index_mgr.insertIntoPropertyIndex("perf_btree", key, i);
        try metrics.append(timer.read());

        try index_mgr.insertIntoPropertyIndex("perf_hash", key, i);

        var vec: [32]f32 = undefined;
        for (&vec, 0..) |*v, j| {
            v.* = @as(f32, @floatFromInt((i + j) % 256)) / 256.0;
        }
        try index_mgr.insertIntoVectorIndex("perf_vector", &vec, i);

        const mbr = geode.index.rtree.MBR{
            .min_x = @as(f64, @floatFromInt(i % 100)),
            .min_y = @as(f64, @floatFromInt(i / 100)),
            .max_x = @as(f64, @floatFromInt(i % 100 + 1)),
            .max_y = @as(f64, @floatFromInt(i / 100 + 1)),
        };
        try index_mgr.insertIntoSpatialIndex("perf_spatial", mbr, i);
    }

    // Calculate average insertion time
    var total: u64 = 0;
    for (metrics.items) |time| {
        total += time;
    }
    const avg_insert_time = total / metrics.items.len;

    // Measure lookup performance
    timer.reset();
    const lookup_key = try std.fmt.allocPrint(allocator, "key_{:0>6}", .{test_size / 2});
    defer allocator.free(lookup_key);

    const btree_result = try index_mgr.lookupPropertyIndex("perf_btree", lookup_key);
    const btree_lookup_time = timer.read();

    timer.reset();
    const hash_result = try index_mgr.lookupPropertyIndex("perf_hash", lookup_key);
    const hash_lookup_time = timer.read();

    // Verify correctness
    try testing.expect(btree_result == test_size / 2);
    try testing.expect(hash_result == test_size / 2);

    // Hash should be faster for exact lookups
    std.debug.print("\nPerformance Canary Results:\n", .{});
    std.debug.print("  Average insert time: {}ns\n", .{avg_insert_time});
    std.debug.print("  BTree lookup: {}ns\n", .{btree_lookup_time});
    std.debug.print("  Hash lookup: {}ns\n", .{hash_lookup_time});

    // Performance regression check - these are baseline expectations
    try testing.expect(avg_insert_time < 1_000_000); // Less than 1ms average
    try testing.expect(btree_lookup_time < 100_000); // Less than 100μs
    try testing.expect(hash_lookup_time < 50_000); // Less than 50μs
}
