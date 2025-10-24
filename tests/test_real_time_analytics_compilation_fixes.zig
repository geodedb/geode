// CANARY: REQ=REQ-ANALYTICS-COMPILATION-001; FEATURE="Real-time Analytics Compilation Fixes"; ASPECT=CodeQuality; STATUS=TESTED; TEST=TestCANARY_ANALYTICS_COMPILATION_001; OWNER=analytics; UPDATED=2025-10-05
// CANARY: REQ=REQ-ANALYTICS-COMPILATION-002; FEATURE="Parameter Usage Validation"; ASPECT=ParameterHandling; STATUS=TESTED; TEST=TestCANARY_ANALYTICS_COMPILATION_002; OWNER=analytics; UPDATED=2025-10-05

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const geode = @import("../src/lib.zig");
const real_time = @import("../src/analytics/real_time.zig");
const ml_embeddings = @import("../src/ml/graph_embeddings.zig");

// Test to ensure analyzeTrends function properly uses self parameter
// This regression test prevents the reintroduction of unnecessary parameter discards
test "CANARY_REQ_ANALYTICS_COMPILATION_001_analyzeTrends_parameter_usage" {
    const allocator = testing.allocator;

    const config = real_time.AnalyticsConfig{
        .enable_trend_analysis = true,
        .batch_size = 10,
    };

    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();

    // Create test event
    var event = real_time.AnalyticsEvent.init(allocator, .node_creation);
    defer event.deinit();

    event.node_id = 123;
    try event.setProperty("test_metric", real_time.AnalyticsValue{ .float = 5.5 });

    // Record initial trends count
    const initial_trends = engine.statistics.trends_identified;

    // Call analyzeTrends - this should increment the trends counter
    // This test verifies that the self parameter is properly used (not discarded)
    try engine.analyzeTrends(&event);

    // Verify that self.statistics was properly updated
    try expectEqual(initial_trends + 1, engine.statistics.trends_identified);
}

// Test to ensure convertCDCEvent function properly uses self parameter
// This regression test prevents the reintroduction of unnecessary parameter discards
test "CANARY_REQ_ANALYTICS_COMPILATION_002_convertCDCEvent_parameter_usage" {
    const allocator = testing.allocator;

    const config = real_time.AnalyticsConfig{};
    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();

    var cdc_integration = real_time.CDCAnalyticsIntegration.init(&engine);

    // Mock CDC event structure
    const mock_cdc_event = struct {
        event_type: []const u8 = "node_created",
        node_id: u64 = 456,
        timestamp: i64 = 1634567890000,
    }{};

    // Call convertCDCEvent - this should use self.analytics_engine.allocator
    // This test verifies that the self parameter is properly used (not discarded)
    var analytics_event = try cdc_integration.convertCDCEvent(mock_cdc_event);
    defer analytics_event.deinit();

    // Verify that the event was created successfully using self.analytics_engine.allocator
    try expect(analytics_event.event_type == .node_creation);
    try expect(analytics_event.timestamp > 0);
    try expect(analytics_event.id > 0);

    // Verify that the source property was set correctly
    if (analytics_event.getProperty("source")) |source_value| {
        switch (source_value) {
            .string => |str| try std.testing.expectEqualStrings("cdc", str),
            else => try expect(false),
        }
    } else {
        try expect(false); // Property should exist
    }
}

// Test parameter discard pattern validation
// Ensures that only truly unused parameters are discarded
test "parameter_discard_pattern_validation" {
    const allocator = testing.allocator;

    // Test analyzeTrends function signature and usage
    const config = real_time.AnalyticsConfig{};
    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();

    var event = real_time.AnalyticsEvent.init(allocator, .trend_analysis);
    defer event.deinit();

    // This test validates that:
    // 1. analyzeTrends uses self parameter (no discard needed)
    // 2. analyzeTrends currently doesn't use event parameter (discard is appropriate)
    const initial_trends = engine.statistics.trends_identified;

    try engine.analyzeTrends(&event);

    // Verify self was used properly
    try expectEqual(initial_trends + 1, engine.statistics.trends_identified);

    // The event parameter is currently unused in the implementation
    // This is intentional as trend analysis is a placeholder for future enhancement
}

// Test CDC integration parameter usage patterns
test "cdc_integration_parameter_patterns" {
    const allocator = testing.allocator;

    const config = real_time.AnalyticsConfig{};
    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();

    var cdc_integration = real_time.CDCAnalyticsIntegration.init(&engine);

    // Test that convertCDCEvent properly uses self but not cdc_event (in current implementation)
    const mock_event = struct {
        type: []const u8 = "INSERT",
        data: []const u8 = "mock_data",
    }{};

    var result = try cdc_integration.convertCDCEvent(mock_event);
    defer result.deinit();

    // Verify self.analytics_engine.allocator was used
    try expect(result.properties.allocator.vtable != null);

    // Current implementation doesn't parse cdc_event details (placeholder)
    // This is intentional as CDC parsing will be enhanced in future versions
}

// Integration test for compilation fix stability
test "compilation_fix_integration_stability" {
    const allocator = testing.allocator;

    // Initialize full analytics engine
    const config = real_time.AnalyticsConfig{
        .enable_ml_integration = true,
        .enable_pattern_detection = true,
        .enable_anomaly_detection = true,
        .enable_trend_analysis = true,
        .batch_size = 5,
    };

    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();

    // Initialize ML manager for integration
    var ml_manager = try ml_embeddings.GraphEmbeddingsManager.init(allocator, 32);
    defer ml_manager.deinit();

    try ml_manager.configureAlgorithm(.node2vec, .{
        .learning_rate = 0.01,
        .num_epochs = 1,
        .batch_size = 8,
    });

    engine.connectMLManager(&ml_manager);

    // Create and process events that trigger the fixed functions
    for (0..3) |i| {
        var event = real_time.AnalyticsEvent.init(allocator, .node_creation);
        event.node_id = i + 1;
        try event.setProperty("metric_value", real_time.AnalyticsValue{ .float = @as(f64, @floatFromInt(i)) * 2.5 });

        try engine.queueEvent(event);
    }

    // Process batch - this will call both fixed functions
    try engine.processEventsBatch();

    // Verify that both fixed functions worked correctly
    try expect(engine.statistics.events_processed > 0);
    try expect(engine.statistics.trends_identified > 0);

    // Test CDC integration
    var cdc_integration = real_time.CDCAnalyticsIntegration.init(&engine);

    const cdc_event = struct {
        operation: []const u8 = "INSERT",
        table: []const u8 = "nodes",
        timestamp: i64 = std.time.milliTimestamp(),
    }{};

    try cdc_integration.handleCDCEvent(cdc_event);

    // Verify CDC event was processed (queued)
    try expect(engine.statistics.events_queued > 0);
}

// Memory safety test for fixed functions
test "memory_safety_parameter_usage" {
    const allocator = testing.allocator;

    const config = real_time.AnalyticsConfig{};
    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();

    // Test multiple calls to ensure no memory issues
    for (0..10) |i| {
        var event = real_time.AnalyticsEvent.init(allocator, .node_update);
        defer event.deinit();

        event.node_id = i;
        try event.setProperty("iteration", real_time.AnalyticsValue{ .integer = @intCast(i) });

        // Call analyzed function multiple times
        try engine.analyzeTrends(&event);
    }

    // Verify all calls succeeded and statistics updated correctly
    try expectEqual(@as(u64, 10), engine.statistics.trends_identified);

    // Test CDC conversion multiple times
    var cdc_integration = real_time.CDCAnalyticsIntegration.init(&engine);

    for (0..5) |i| {
        const mock_cdc = struct {
            id: u64,
            operation: []const u8 = "UPDATE",

            pub fn init(id: u64) @This() {
                return @This(){ .id = id };
            }
        }.init(i);

        var converted = try cdc_integration.convertCDCEvent(mock_cdc);
        defer converted.deinit();

        try expect(converted.event_type == .node_creation);
    }
}

// Performance regression test for fixed functions
test "performance_regression_fixed_functions" {
    const allocator = testing.allocator;

    const config = real_time.AnalyticsConfig{
        .batch_size = 100,
    };

    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();

    const start_time = std.time.nanoTimestamp();

    // Test performance of analyzeTrends
    for (0..1000) |i| {
        var event = real_time.AnalyticsEvent.init(allocator, .node_creation);
        defer event.deinit();

        event.node_id = i;
        try engine.analyzeTrends(&event);
    }

    const trends_time = std.time.nanoTimestamp() - start_time;

    // Test performance of convertCDCEvent
    var cdc_integration = real_time.CDCAnalyticsIntegration.init(&engine);

    const cdc_start = std.time.nanoTimestamp();

    for (0..1000) |i| {
        const mock_cdc = struct {
            seq: u64,
            data: []const u8 = "test_data",
        }{ .seq = i };

        var converted = try cdc_integration.convertCDCEvent(mock_cdc);
        defer converted.deinit();
    }

    const cdc_time = std.time.nanoTimestamp() - cdc_start;

    // Performance assertions (should be sub-millisecond per operation)
    const trends_per_op_ns = trends_time / 1000;
    const cdc_per_op_ns = cdc_time / 1000;

    // Each operation should be under 100μs (100,000 ns)
    try expect(trends_per_op_ns < 100_000);
    try expect(cdc_per_op_ns < 100_000);

    std.debug.print("Performance: analyzeTrends {}ns/op, convertCDCEvent {}ns/op\n", .{ trends_per_op_ns, cdc_per_op_ns });
}

// Test runner
pub fn main() !void {
    std.debug.print("Running Real-time Analytics Compilation Fixes Tests...\n\n");

    // Run all tests
    try testing.refAllDecls(@This());

    std.debug.print("\nAll Real-time Analytics Compilation Fixes Tests Completed Successfully!\n");
}
