const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const index_optimizer = @import("../src/server/index_optimizer.zig");
const index_statistics = @import("../src/server/index_statistics.zig");
const vector_index = @import("../src/index/vector_index.zig");
const vector_types = @import("../src/types/vector.zig");

// CANARY: REQ=REQ-GQL-VECTOR-OPS-001; FEATURE="Advanced Vector Operations Integration"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_VECTOR_OPS_001_Integration; OWNER=vector-team; UPDATED=2025-10-04

test "TestCANARY_REQ_GQL_VECTOR_OPS_001_Integration: Advanced Vector Operations" {
    const allocator = testing.allocator;

    // Initialize test infrastructure
    var stats_manager = index_statistics.IndexStatisticsManager.init(allocator);
    defer stats_manager.deinit();

    var vector_manager = vector_index.VectorIndexManager.init(allocator);
    defer vector_manager.deinit();

    // Create vector index for testing
    try vector_manager.createIndex("test_embeddings", 128, .cosine);
    const test_index = vector_manager.getIndex("test_embeddings").?;

    // Initialize statistics for the vector index
    try stats_manager.createIndexStatistics("test_embeddings", .vector_f32", "Document", &[_][]const u8{"embedding"});

    // Set vector parameters
    if (stats_manager.getIndexStatistics("test_embeddings")) |stats| {
        stats.setVectorParameters(128);
    }

    // Test 1: Vector distance metric enum conversion
    try testVectorDistanceMetricConversion();

    // Test 2: Advanced vector query options structure
    try testVectorQueryOptionsConfiguration();

    // Test 3: Cost estimation for different query types
    try testAdvancedVectorCostEstimation(allocator, &stats_manager);

    // Test 4: Vector statistics integration
    try testVectorStatisticsIntegration(allocator, &stats_manager, test_index);

    // Test 5: Query type result estimation
    try testVectorQueryRowEstimation();

    // Test 6: Distance metric cost factors
    try testDistanceMetricCostFactors(allocator, &stats_manager);

    std.log.info("✅ All advanced vector operations integration tests passed");
}

/// Test vector distance metric enum conversion functionality
fn testVectorDistanceMetricConversion() !void {
    const VectorDistanceMetric = index_optimizer.VectorDistanceMetric;

    // Test string to enum conversion
    try testing.expectEqual(VectorDistanceMetric.l2, VectorDistanceMetric.fromString("l2").?);
    try testing.expectEqual(VectorDistanceMetric.cosine, VectorDistanceMetric.fromString("cosine").?);
    try testing.expectEqual(VectorDistanceMetric.dot, VectorDistanceMetric.fromString("dot").?);
    try testing.expectEqual(VectorDistanceMetric.manhattan, VectorDistanceMetric.fromString("manhattan").?);
    try testing.expectEqual(VectorDistanceMetric.hamming, VectorDistanceMetric.fromString("hamming").?);
    try testing.expectEqual(VectorDistanceMetric.jaccard, VectorDistanceMetric.fromString("jaccard").?);

    // Test invalid string
    try testing.expectEqual(@as(?VectorDistanceMetric, null), VectorDistanceMetric.fromString("invalid"));

    // Test enum to string conversion
    try testing.expectEqualStrings("l2", VectorDistanceMetric.l2.toString());
    try testing.expectEqualStrings("cosine", VectorDistanceMetric.cosine.toString());
    try testing.expectEqualStrings("dot", VectorDistanceMetric.dot.toString());
    try testing.expectEqualStrings("manhattan", VectorDistanceMetric.manhattan.toString());
    try testing.expectEqualStrings("hamming", VectorDistanceMetric.hamming.toString());
    try testing.expectEqualStrings("jaccard", VectorDistanceMetric.jaccard.toString());
}

/// Test vector query options configuration
fn testVectorQueryOptionsConfiguration() !void {
    const VectorQueryOptions = index_optimizer.VectorQueryOptions;
    const VectorQueryType = index_optimizer.VectorQueryType;
    const VectorDistanceMetric = index_optimizer.VectorDistanceMetric;

    // Test default configuration
    const default_options = VectorQueryOptions{};
    try testing.expectEqual(VectorQueryType.knn, default_options.query_type);
    try testing.expectEqual(VectorDistanceMetric.l2, default_options.distance_metric);
    try testing.expectEqual(@as(u32, 10), default_options.k);
    try testing.expectEqual(@as(?f64, null), default_options.similarity_threshold);
    try testing.expectEqual(@as(?f64, null), default_options.max_distance);
    try testing.expectEqual(@as(?f64, null), default_options.min_distance);
    try testing.expect(default_options.include_distances);

    // Test K-NN configuration
    const knn_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .cosine,
        .k = 20,
        .include_distances = true,
    };
    try testing.expectEqual(VectorQueryType.knn, knn_options.query_type);
    try testing.expectEqual(VectorDistanceMetric.cosine, knn_options.distance_metric);
    try testing.expectEqual(@as(u32, 20), knn_options.k);

    // Test similarity threshold configuration
    const threshold_options = VectorQueryOptions{
        .query_type = .similarity_threshold,
        .distance_metric = .l2,
        .k = 50,
        .similarity_threshold = 0.8,
    };
    try testing.expectEqual(VectorQueryType.similarity_threshold, threshold_options.query_type);
    try testing.expectEqual(@as(?f64, 0.8), threshold_options.similarity_threshold);

    // Test distance range configuration
    const range_options = VectorQueryOptions{
        .query_type = .distance_range,
        .distance_metric = .manhattan,
        .k = 100,
        .min_distance = 1.0,
        .max_distance = 5.0,
    };
    try testing.expectEqual(VectorQueryType.distance_range, range_options.query_type);
    try testing.expectEqual(@as(?f64, 1.0), range_options.min_distance);
    try testing.expectEqual(@as(?f64, 5.0), range_options.max_distance);

    // Test approximate K-NN configuration
    const approx_options = VectorQueryOptions{
        .query_type = .approximate_knn,
        .distance_metric = .cosine,
        .k = 15,
        .ef_search = 64,
        .approximate = true,
    };
    try testing.expectEqual(VectorQueryType.approximate_knn, approx_options.query_type);
    try testing.expectEqual(@as(?u16, 64), approx_options.ef_search);
    try testing.expect(approx_options.approximate);
}

/// Test advanced vector cost estimation with different configurations
fn testAdvancedVectorCostEstimation(allocator: std.mem.Allocator, stats_manager: *index_statistics.IndexStatisticsManager) !void {
    const VectorQueryOptions = index_optimizer.VectorQueryOptions;
    const VectorQueryType = index_optimizer.VectorQueryType;
    const VectorDistanceMetric = index_optimizer.VectorDistanceMetric;

    // Mock IndexOptimizer for testing
    const MockIndexManager = struct {
        pub fn getIndexesForProperty(_: []const u8) ![]geode.graph_common.IndexInfo {
            return &[_]geode.graph_common.IndexInfo{};
        }
    };

    var mock_index_manager = MockIndexManager{};
    var optimizer = index_optimizer.IndexOptimizer.init(allocator, &mock_index_manager);
    optimizer.setStatisticsManager(stats_manager);

    // Create mock index info
    const index_info = geode.graph_common.IndexInfo{
        .name = "test_vector_idx",
        .label = "Document",
        .property = "embedding",
        .index_type = .vector_f32,
        .selectivity = 0.1,
    };

    // Test K-NN cost estimation
    const knn_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .l2,
        .k = 10,
    };

    const knn_cost = optimizer.estimateAdvancedVectorCost(index_info, knn_options, 128);
    try testing.expect(knn_cost > 0);
    try testing.expect(knn_cost < 100); // Should be reasonable

    // Test approximate K-NN should be cheaper
    const approx_options = VectorQueryOptions{
        .query_type = .approximate_knn,
        .distance_metric = .l2,
        .k = 10,
    };

    const approx_cost = optimizer.estimateAdvancedVectorCost(index_info, approx_options, 128);
    try testing.expect(approx_cost < knn_cost); // 30% cheaper

    // Test similarity threshold should be more expensive
    const threshold_options = VectorQueryOptions{
        .query_type = .similarity_threshold,
        .distance_metric = .l2,
        .k = 10,
        .similarity_threshold = 0.8,
    };

    const threshold_cost = optimizer.estimateAdvancedVectorCost(index_info, threshold_options, 128);
    try testing.expect(threshold_cost > knn_cost); // 20% more expensive

    // Test distance range should be most expensive
    const range_options = VectorQueryOptions{
        .query_type = .distance_range,
        .distance_metric = .l2,
        .k = 10,
        .min_distance = 1.0,
        .max_distance = 5.0,
    };

    const range_cost = optimizer.estimateAdvancedVectorCost(index_info, range_options, 128);
    try testing.expect(range_cost > threshold_cost); // 50% more expensive
}

/// Test vector statistics integration with real query recording
fn testVectorStatisticsIntegration(
    allocator: std.mem.Allocator,
    stats_manager: *index_statistics.IndexStatisticsManager,
    vector_idx: *vector_index.VectorIndex,
) !void {
    // Insert test vectors
    const vec1 = vector_types.VectorF32.fromSlice(&[_]f32{ 1.0, 2.0, 3.0 });
    const vec2 = vector_types.VectorF32.fromSlice(&[_]f32{ 4.0, 5.0, 6.0 });
    const vec3 = vector_types.VectorF32.fromSlice(&[_]f32{ 1.1, 2.1, 3.1 });

    _ = try vector_idx.insertVectorF32(vec1, null);
    _ = try vector_idx.insertVectorF32(vec2, null);
    _ = try vector_idx.insertVectorF32(vec3, null);

    // Record vector index entries in statistics
    stats_manager.recordIndexEntry("test_embeddings", "vec1", true);
    stats_manager.recordIndexEntry("test_embeddings", "vec2", true);
    stats_manager.recordIndexEntry("test_embeddings", "vec3", true);

    // Perform K-NN search and record statistics
    const query = vector_types.VectorF32.fromSlice(&[_]f32{ 1.0, 2.0, 3.0 });
    var results = try vector_idx.searchVectorF32(query, 2);
    defer results.deinit();

    // Calculate average distance for statistics
    var total_distance: f64 = 0;
    for (results.results.items) |match| {
        total_distance += match.score;
    }
    const avg_distance = total_distance / @as(f64, @floatFromInt(results.results.items.len));

    // Record K-NN query statistics
    if (stats_manager.getIndexStatistics("test_embeddings")) |stats| {
        stats.recordVectorKnnQuery(2, avg_distance);

        // Verify statistics were recorded
        try testing.expect(stats.vector_knn_queries > 0);
        try testing.expect(stats.vector_avg_k_value > 0);
        try testing.expect(stats.vector_avg_distance >= 0);

        // Test cost estimation with statistics
        const cost = stats.estimateVectorKnnCost(5, 1000);
        try testing.expect(cost > 0);
        try testing.expect(cost < 1000); // Should be reasonable

        // Test vector index recommendations
        const recommendations = stats.getVectorIndexRecommendations();
        try testing.expect(recommendations.len > 0);
    }

    // Record index access statistics
    stats_manager.recordIndexAccess("test_embeddings", results.results.items.len, 1);

    // Verify access statistics
    if (stats_manager.getIndexStatistics("test_embeddings")) |stats| {
        try testing.expect(stats.access_count > 0);
        try testing.expect(stats.hit_ratio >= 0);
    }
}

/// Test vector query row estimation for different query types
fn testVectorQueryRowEstimation() !void {
    const allocator = testing.allocator;
    const VectorQueryOptions = index_optimizer.VectorQueryOptions;
    const VectorQueryType = index_optimizer.VectorQueryType;

    // Mock IndexOptimizer for testing
    const MockIndexManager = struct {
        pub fn getIndexesForProperty(_: []const u8) ![]geode.graph_common.IndexInfo {
            return &[_]geode.graph_common.IndexInfo{};
        }
    };

    var mock_index_manager = MockIndexManager{};
    var optimizer = index_optimizer.IndexOptimizer.init(allocator, &mock_index_manager);

    // Test K-NN row estimation
    const knn_options = VectorQueryOptions{
        .query_type = .knn,
        .k = 10,
    };
    const knn_rows = optimizer.estimateVectorQueryRows(knn_options);
    try testing.expectEqual(@as(u64, 10), knn_rows); // Exactly k results

    // Test approximate K-NN row estimation
    const approx_options = VectorQueryOptions{
        .query_type = .approximate_knn,
        .k = 15,
    };
    const approx_rows = optimizer.estimateVectorQueryRows(approx_options);
    try testing.expectEqual(@as(u64, 15), approx_rows); // Exactly k results

    // Test similarity threshold row estimation
    const threshold_options = VectorQueryOptions{
        .query_type = .similarity_threshold,
        .k = 20,
        .similarity_threshold = 0.9, // Very selective
    };
    const threshold_rows = optimizer.estimateVectorQueryRows(threshold_options);
    try testing.expectEqual(@as(u64, 20), threshold_rows); // High threshold = k results

    // Test moderate similarity threshold
    const moderate_threshold_options = VectorQueryOptions{
        .query_type = .similarity_threshold,
        .k = 20,
        .similarity_threshold = 0.75, // Moderately selective
    };
    const moderate_rows = optimizer.estimateVectorQueryRows(moderate_threshold_options);
    try testing.expectEqual(@as(u64, 40), moderate_rows); // k * 2 results

    // Test broad similarity threshold
    const broad_threshold_options = VectorQueryOptions{
        .query_type = .similarity_threshold,
        .k = 20,
        .similarity_threshold = 0.5, // Broad threshold
    };
    const broad_rows = optimizer.estimateVectorQueryRows(broad_threshold_options);
    try testing.expectEqual(@as(u64, 100), broad_rows); // k * 5 results

    // Test distance range row estimation
    const range_options = VectorQueryOptions{
        .query_type = .distance_range,
        .k = 10,
        .min_distance = 1.0,
        .max_distance = 5.0,
    };
    const range_rows = optimizer.estimateVectorQueryRows(range_options);
    try testing.expectEqual(@as(u64, 100), range_rows); // k * 10 results
}

/// Test distance metric cost factors
fn testDistanceMetricCostFactors(allocator: std.mem.Allocator, stats_manager: *index_statistics.IndexStatisticsManager) !void {
    const VectorQueryOptions = index_optimizer.VectorQueryOptions;
    const VectorDistanceMetric = index_optimizer.VectorDistanceMetric;

    // Mock IndexOptimizer for testing
    const MockIndexManager = struct {
        pub fn getIndexesForProperty(_: []const u8) ![]geode.graph_common.IndexInfo {
            return &[_]geode.graph_common.IndexInfo{};
        }
    };

    var mock_index_manager = MockIndexManager{};
    var optimizer = index_optimizer.IndexOptimizer.init(allocator, &mock_index_manager);
    optimizer.setStatisticsManager(stats_manager);

    // Create mock index info
    const index_info = geode.graph_common.IndexInfo{
        .name = "test_vector_idx",
        .label = "Document",
        .property = "embedding",
        .index_type = .vector_f32,
        .selectivity = 0.1,
    };

    // Test base cost with L2 (baseline: 1.0x)
    const l2_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .l2,
        .k = 10,
    };
    const l2_cost = optimizer.estimateAdvancedVectorCost(index_info, l2_options, 128);

    // Test cosine cost (should be 1.1x more expensive)
    const cosine_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .cosine,
        .k = 10,
    };
    const cosine_cost = optimizer.estimateAdvancedVectorCost(index_info, cosine_options, 128);
    try testing.expect(cosine_cost > l2_cost);

    // Test dot product cost (should be 0.9x cheaper)
    const dot_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .dot,
        .k = 10,
    };
    const dot_cost = optimizer.estimateAdvancedVectorCost(index_info, dot_options, 128);
    try testing.expect(dot_cost < l2_cost);

    // Test Manhattan cost (should be 1.05x more expensive)
    const manhattan_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .manhattan,
        .k = 10,
    };
    const manhattan_cost = optimizer.estimateAdvancedVectorCost(index_info, manhattan_options, 128);
    try testing.expect(manhattan_cost > l2_cost);
    try testing.expect(manhattan_cost < cosine_cost);

    // Test Hamming cost (should be 0.8x cheaper)
    const hamming_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .hamming,
        .k = 10,
    };
    const hamming_cost = optimizer.estimateAdvancedVectorCost(index_info, hamming_options, 128);
    try testing.expect(hamming_cost < dot_cost); // Cheapest

    // Test Jaccard cost (should be 1.3x more expensive)
    const jaccard_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .jaccard,
        .k = 10,
    };
    const jaccard_cost = optimizer.estimateAdvancedVectorCost(index_info, jaccard_options, 128);
    try testing.expect(jaccard_cost > cosine_cost); // Most expensive

    // Verify cost ordering: hamming < dot < l2 < manhattan < cosine < jaccard
    try testing.expect(hamming_cost < dot_cost);
    try testing.expect(dot_cost < l2_cost);
    try testing.expect(l2_cost < manhattan_cost);
    try testing.expect(manhattan_cost < cosine_cost);
    try testing.expect(cosine_cost < jaccard_cost);
}

test "TestCANARY_REQ_GQL_VECTOR_OPS_002_QuerySupport: Vector Index Query Support Validation" {
    const allocator = testing.allocator;
    const VectorQueryOptions = index_optimizer.VectorQueryOptions;
    const VectorQueryType = index_optimizer.VectorQueryType;
    const VectorDistanceMetric = index_optimizer.VectorDistanceMetric;

    // Mock IndexOptimizer for testing
    const MockIndexManager = struct {
        pub fn getIndexesForProperty(_: []const u8) ![]geode.graph_common.IndexInfo {
            return &[_]geode.graph_common.IndexInfo{};
        }
    };

    var mock_index_manager = MockIndexManager{};
    var optimizer = index_optimizer.IndexOptimizer.init(allocator, &mock_index_manager);

    // Create mock HNSW index info
    const hnsw_index = geode.graph_common.IndexInfo{
        .name = "hnsw_embeddings",
        .label = "Document",
        .property = "embedding",
        .index_type = .vector_hnsw,
        .selectivity = 0.1,
    };

    // Test K-NN query support
    const knn_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .cosine,
        .k = 10,
    };
    try testing.expect(optimizer.vectorIndexSupportsQuery(hnsw_index, 128, knn_options));

    // Test approximate K-NN query support
    const approx_options = VectorQueryOptions{
        .query_type = .approximate_knn,
        .distance_metric = .l2,
        .k = 15,
    };
    try testing.expect(optimizer.vectorIndexSupportsQuery(hnsw_index, 256, approx_options));

    // Test similarity threshold query support
    const threshold_options = VectorQueryOptions{
        .query_type = .similarity_threshold,
        .distance_metric = .dot,
        .k = 20,
        .similarity_threshold = 0.8,
    };
    try testing.expect(optimizer.vectorIndexSupportsQuery(hnsw_index, 64, threshold_options));

    // Test distance range query support
    const range_options = VectorQueryOptions{
        .query_type = .distance_range,
        .distance_metric = .manhattan,
        .k = 50,
        .min_distance = 1.0,
        .max_distance = 10.0,
    };
    try testing.expect(optimizer.vectorIndexSupportsQuery(hnsw_index, 512, range_options));

    std.log.info("✅ Vector index query support validation tests passed");
}

test "TestCANARY_REQ_GQL_VECTOR_OPS_003_SequentialCost: Sequential Advanced Vector Scan Cost Estimation" {
    const allocator = testing.allocator;
    const VectorQueryOptions = index_optimizer.VectorQueryOptions;
    const VectorQueryType = index_optimizer.VectorQueryType;
    const VectorDistanceMetric = index_optimizer.VectorDistanceMetric;

    // Mock IndexOptimizer for testing
    const MockIndexManager = struct {
        pub fn getIndexesForProperty(_: []const u8) ![]geode.graph_common.IndexInfo {
            return &[_]geode.graph_common.IndexInfo{};
        }
    };

    var mock_index_manager = MockIndexManager{};
    var optimizer = index_optimizer.IndexOptimizer.init(allocator, &mock_index_manager);

    const labels = [_][]const u8{"Document"};
    const vector_dim = 128;

    // Test K-NN sequential cost (baseline)
    const knn_options = VectorQueryOptions{
        .query_type = .knn,
        .distance_metric = .l2,
        .k = 10,
    };
    const knn_cost = optimizer.estimateSequentialAdvancedVectorScanCost(&labels, vector_dim, knn_options);
    try testing.expect(knn_cost > 0);

    // Test approximate K-NN should be slightly cheaper
    const approx_options = VectorQueryOptions{
        .query_type = .approximate_knn,
        .distance_metric = .l2,
        .k = 10,
    };
    const approx_cost = optimizer.estimateSequentialAdvancedVectorScanCost(&labels, vector_dim, approx_options);
    try testing.expect(approx_cost < knn_cost);

    // Test similarity threshold should be more expensive
    const threshold_options = VectorQueryOptions{
        .query_type = .similarity_threshold,
        .distance_metric = .l2,
        .k = 10,
        .similarity_threshold = 0.8,
    };
    const threshold_cost = optimizer.estimateSequentialAdvancedVectorScanCost(&labels, vector_dim, threshold_options);
    try testing.expect(threshold_cost > knn_cost);

    // Test distance range should be most expensive
    const range_options = VectorQueryOptions{
        .query_type = .distance_range,
        .distance_metric = .l2,
        .k = 10,
        .min_distance = 1.0,
        .max_distance = 5.0,
    };
    const range_cost = optimizer.estimateSequentialAdvancedVectorScanCost(&labels, vector_dim, range_options);
    try testing.expect(range_cost > threshold_cost);

    // Verify cost ordering: approx < knn < threshold < range
    try testing.expect(approx_cost < knn_cost);
    try testing.expect(knn_cost < threshold_cost);
    try testing.expect(threshold_cost < range_cost);

    std.log.info("✅ Sequential advanced vector scan cost estimation tests passed");
}

test "TestCANARY_REQ_GQL_VECTOR_OPS_004_Legacy: Legacy Vector K-NN Optimizer Integration" {
    const allocator = testing.allocator;

    // Mock IndexOptimizer for testing
    const MockIndexManager = struct {
        pub fn getIndexesForProperty(_: []const u8) ![]geode.graph_common.IndexInfo {
            return &[_]geode.graph_common.IndexInfo{};
        }
    };

    var mock_index_manager = MockIndexManager{};
    var optimizer = index_optimizer.IndexOptimizer.init(allocator, &mock_index_manager);

    const property = "embedding";
    const query_vector = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const k: u32 = 5;
    const metric = "cosine";
    const labels = [_][]const u8{"Document"};

    // Test legacy K-NN optimization method
    const scan_plan = optimizer.optimizeVectorKNNScan(property, &query_vector, k, metric, &labels);

    // Verify scan plan structure
    try testing.expect(scan_plan.estimated_cost > 0);
    try testing.expect(scan_plan.estimated_rows > 0);

    // Since no real index manager, should fall back to sequential scan
    try testing.expectEqual(geode.graph_common.ScanType.sequential, scan_plan.type);

    std.log.info("✅ Legacy vector K-NN optimizer integration tests passed");
}
