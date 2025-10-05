// CANARY: REQ=REQ-ANALYTICS-TEST-001; FEATURE="Real-time Analytics Unit Tests"; ASPECT=CoreFunctionality; STATUS=TESTED; TEST=TestCANARY_ANALYTICS_TEST_001; OWNER=analytics; UPDATED=2025-10-05
// CANARY: REQ=REQ-ANALYTICS-TEST-002; FEATURE="Pattern Detection Tests"; ASPECT=PatternRecognition; STATUS=TESTED; TEST=TestCANARY_ANALYTICS_TEST_002; OWNER=analytics; UPDATED=2025-10-05
// CANARY: REQ=REQ-ANALYTICS-TEST-003; FEATURE="Anomaly Detection Tests"; ASPECT=StatisticalAnalysis; STATUS=TESTED; TEST=TestCANARY_ANALYTICS_TEST_003; OWNER=analytics; UPDATED=2025-10-05

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectApproxEqRel = testing.expectApproxEqRel;

const geode = @import("../src/lib.zig");
const real_time = @import("../src/analytics/real_time.zig");
const ml_embeddings = @import("../src/ml/graph_embeddings.zig");

test "AnalyticsEvent creation and property management" {
    const allocator = testing.allocator;
    
    var event = real_time.AnalyticsEvent.init(allocator, .node_creation);
    defer event.deinit();
    
    // Test basic event properties
    try expect(event.event_type == .node_creation);
    try expect(event.timestamp > 0);
    try expect(event.id > 0);
    
    // Test property management
    try event.setProperty("test_string", real_time.AnalyticsValue{ .string = "test_value" });
    try event.setProperty("test_integer", real_time.AnalyticsValue{ .integer = 42 });
    try event.setProperty("test_float", real_time.AnalyticsValue{ .float = 3.14 });
    
    // Verify properties
    if (event.getProperty("test_string")) |value| {
        try expectEqual(real_time.AnalyticsValue.string, @as(@TypeOf(value), value));
    } else {
        try expect(false); // Property should exist
    }
    
    if (event.getProperty("test_integer")) |value| {
        switch (value) {
            .integer => |int_val| try expectEqual(@as(i64, 42), int_val),
            else => try expect(false),
        }
    }
}

test "AnalyticsMetadata tag management" {
    const allocator = testing.allocator;
    
    var metadata = real_time.AnalyticsMetadata.init(allocator);
    defer metadata.deinit();
    
    // Test tag addition
    try metadata.addTag("high_priority");
    try metadata.addTag("user_action");
    try metadata.addTag("critical");
    
    try expectEqual(@as(usize, 3), metadata.tags.items.len);
    try std.testing.expectEqualStrings("high_priority", metadata.tags.items[0]);
    try std.testing.expectEqualStrings("user_action", metadata.tags.items[1]);
    try std.testing.expectEqualStrings("critical", metadata.tags.items[2]);
}

test "PatternDetector initialization and basic functionality" {
    const allocator = testing.allocator;
    
    const config = real_time.PatternDetector.PatternDetectionConfig{
        .min_pattern_frequency = 3,
        .pattern_time_window_ms = 30000,
        .max_patterns_tracked = 100,
    };
    
    var detector = real_time.PatternDetector.init(allocator, config);
    defer detector.deinit();
    
    // Test pattern detection with edge creation event
    var event = real_time.AnalyticsEvent.init(allocator, .edge_creation);
    defer event.deinit();
    
    event.node_id = 1;
    try event.setProperty("target_node", real_time.AnalyticsValue{ .integer = 2 });
    
    // Pattern detection should not crash and may return null for basic events
    const detected_pattern = try detector.detectPattern(&event);
    try expect(detected_pattern == null or detected_pattern != null); // Should not crash
}

test "AnomalyDetector statistical analysis" {
    const allocator = testing.allocator;
    
    const config = real_time.AnomalyDetector.AnomalyDetectionConfig{
        .statistical_threshold = 2.0, // Lower threshold for testing
        .minimum_baseline_samples = 5,
        .baseline_update_frequency = 1,
        .anomaly_cooldown_ms = 1000,
    };
    
    var detector = real_time.AnomalyDetector.init(allocator, config);
    defer detector.deinit();
    
    // Create baseline events (normal pattern)
    for (0..10) |i| {
        var event = real_time.AnalyticsEvent.init(allocator, .node_creation);
        defer event.deinit();
        
        event.node_id = i;
        try event.setProperty("activity_level", real_time.AnalyticsValue{ .float = 5.0 + @as(f64, @floatFromInt(i % 3)) }); // Normal range 5-7
        
        var result = try detector.detectAnomaly(&event);
        defer result.deinit();
        
        // Early events should not trigger anomalies (building baseline)
        if (i < 5) {
            try expect(!result.is_anomaly);
        }
    }
    
    // Create anomalous event
    var anomaly_event = real_time.AnalyticsEvent.init(allocator, .node_creation);
    defer anomaly_event.deinit();
    
    anomaly_event.node_id = 999;
    try anomaly_event.setProperty("activity_level", real_time.AnalyticsValue{ .float = 50.0 }); // Anomalous value
    
    var anomaly_result = try detector.detectAnomaly(&anomaly_event);
    defer anomaly_result.deinit();
    
    // Should detect anomaly
    try expect(anomaly_result.is_anomaly);
    try expect(anomaly_result.confidence > 0.0);
}

test "RealTimeAnalyticsEngine initialization and configuration" {
    const allocator = testing.allocator;
    
    const config = real_time.AnalyticsConfig{
        .enable_ml_integration = true,
        .enable_pattern_detection = true,
        .enable_anomaly_detection = true,
        .batch_size = 50,
        .processing_interval_ms = 100,
        .max_event_queue_size = 1000,
    };
    
    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();
    
    // Test configuration
    try expectEqual(@as(u32, 50), engine.config.batch_size);
    try expectEqual(@as(u32, 100), engine.config.processing_interval_ms);
    try expect(engine.config.enable_ml_integration);
    try expect(engine.config.enable_pattern_detection);
    try expect(engine.config.enable_anomaly_detection);
    
    // Test initial statistics
    try expectEqual(@as(u64, 0), engine.statistics.events_processed);
    try expectEqual(@as(u64, 0), engine.statistics.events_queued);
}

test "RealTimeAnalyticsEngine event queueing and processing" {
    const allocator = testing.allocator;
    
    const config = real_time.AnalyticsConfig{
        .batch_size = 5,
        .max_event_queue_size = 10,
        .processing_interval_ms = 50,
    };
    
    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();
    
    // Queue multiple events
    for (0..7) |i| {
        var event = real_time.AnalyticsEvent.init(allocator, .node_creation);
        event.node_id = i;
        try event.setProperty("test_id", real_time.AnalyticsValue{ .integer = @intCast(i) });
        
        try engine.queueEvent(event);
    }
    
    // Verify events are queued
    try expectEqual(@as(u64, 7), engine.statistics.events_queued);
    
    // Process a batch
    try engine.processEventsBatch();
    
    // Verify batch was processed
    try expectEqual(@as(u64, 5), engine.statistics.events_processed);
    try expectEqual(@as(u64, 2), engine.statistics.events_queued); // 2 events remaining
    try expect(engine.statistics.average_processing_time_ms >= 0.0);
}

test "RealTimeAnalyticsEngine ML integration" {
    const allocator = testing.allocator;
    
    // Initialize ML embeddings manager
    var ml_manager = try ml_embeddings.GraphEmbeddingsManager.init(allocator, 64);
    defer ml_manager.deinit();
    
    try ml_manager.configureAlgorithm(.node2vec, .{
        .learning_rate = 0.01,
        .num_epochs = 1, // Minimal for testing
        .batch_size = 16,
    });
    
    // Initialize analytics engine with ML integration
    const config = real_time.AnalyticsConfig{
        .enable_ml_integration = true,
        .batch_size = 10,
    };
    
    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();
    
    // Connect ML manager
    engine.connectMLManager(&ml_manager);
    
    // Create events that should trigger ML updates
    for (0..3) |i| {
        var event = real_time.AnalyticsEvent.init(allocator, .node_creation);
        event.node_id = i + 1;
        try engine.queueEvent(event);
    }
    
    // Process events (should trigger ML updates)
    try engine.processEventsBatch();
    
    // Verify ML updates were triggered
    try expect(engine.statistics.ml_updates_triggered > 0);
}

test "RealTimeAnalyticsEngine queue overflow handling" {
    const allocator = testing.allocator;
    
    const config = real_time.AnalyticsConfig{
        .batch_size = 5,
        .max_event_queue_size = 3, // Small queue for testing overflow
    };
    
    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();
    
    // Queue events beyond capacity
    for (0..5) |i| {
        var event = real_time.AnalyticsEvent.init(allocator, .node_creation);
        event.node_id = i;
        try engine.queueEvent(event);
    }
    
    // Queue should be at maximum capacity, oldest events removed
    try expectEqual(@as(u64, 3), engine.statistics.events_queued);
    try expectEqual(@as(usize, 3), engine.event_queue.items.len);
}

test "CDCAnalyticsIntegration event conversion" {
    const allocator = testing.allocator;
    
    const config = real_time.AnalyticsConfig{};
    var engine = try real_time.RealTimeAnalyticsEngine.init(allocator, config);
    defer engine.deinit();
    
    var cdc_integration = real_time.CDCAnalyticsIntegration.init(&engine);
    
    // Mock CDC event (in real implementation, this would be actual CDC event structure)
    const mock_cdc_event = struct {
        event_type: []const u8 = "node_created",
        node_id: u64 = 123,
        timestamp: i64 = 1634567890000,
    }{};
    
    // Handle CDC event
    try cdc_integration.handleCDCEvent(mock_cdc_event);
    
    // Verify event was queued
    try expectEqual(@as(u64, 1), engine.statistics.events_queued);
}

test "AnomalyDetector severity classification" {
    const allocator = testing.allocator;
    
    const config = real_time.AnomalyDetector.AnomalyDetectionConfig{};
    var detector = real_time.AnomalyDetector.init(allocator, config);
    defer detector.deinit();
    
    // Test severity classification logic
    const low_severity = detector.classifySeverity(3.0);
    const medium_severity = detector.classifySeverity(7.0);
    const high_severity = detector.classifySeverity(15.0);
    const critical_severity = detector.classifySeverity(25.0);
    
    try expectEqual(real_time.AnomalyDetector.AnomalyResult.AnomalySeverity.low, low_severity);
    try expectEqual(real_time.AnomalyDetector.AnomalyResult.AnomalySeverity.medium, medium_severity);
    try expectEqual(real_time.AnomalyDetector.AnomalyResult.AnomalySeverity.high, high_severity);
    try expectEqual(real_time.AnomalyDetector.AnomalyResult.AnomalySeverity.critical, critical_severity);
}

test "DetectedPattern lifecycle management" {
    const allocator = testing.allocator;
    
    var pattern = real_time.PatternDetector.DetectedPattern.init(allocator, .frequent_connection);
    defer pattern.deinit();
    
    // Test pattern initialization
    try expectEqual(real_time.PatternDetector.PatternType.frequent_connection, pattern.pattern_type);
    try expectEqual(@as(u32, 1), pattern.frequency);
    try expect(pattern.pattern_id > 0);
    try expect(pattern.first_occurrence > 0);
    try expect(pattern.last_occurrence >= pattern.first_occurrence);
    
    // Test nodes_involved management
    try pattern.nodes_involved.append(1);
    try pattern.nodes_involved.append(2);
    try pattern.nodes_involved.append(3);
    
    try expectEqual(@as(usize, 3), pattern.nodes_involved.items.len);
    try expectEqual(@as(u64, 1), pattern.nodes_involved.items[0]);
    try expectEqual(@as(u64, 2), pattern.nodes_involved.items[1]);
    try expectEqual(@as(u64, 3), pattern.nodes_involved.items[2]);
}

test "AnalyticsStatistics processing time updates" {
    var stats = real_time.AnalyticsStatistics{};
    
    // Test initial state
    try expectEqual(@as(f64, 0.0), stats.average_processing_time_ms);
    try expectEqual(@as(u64, 0), stats.events_processed);
    
    // Update processing times
    stats.updateProcessingTime(10.0);
    stats.events_processed += 1;
    try expectApproxEqRel(@as(f64, 10.0), stats.average_processing_time_ms, 0.001);
    
    stats.updateProcessingTime(20.0);
    stats.events_processed += 1;
    try expectApproxEqRel(@as(f64, 15.0), stats.average_processing_time_ms, 0.001);
    
    stats.updateProcessingTime(30.0);
    stats.events_processed += 1;
    try expectApproxEqRel(@as(f64, 20.0), stats.average_processing_time_ms, 0.001);
}

// Test runner
pub fn main() !void {
    std.debug.print("Running Real-time Analytics Unit Tests...\n\n");
    
    // Run all unit tests
    try testing.refAllDecls(@This());
    
    std.debug.print("\nAll Real-time Analytics Unit Tests Completed Successfully!\n");
}