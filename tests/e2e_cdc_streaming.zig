const std = @import("std");
const testing = std.testing;
const cdc = @import("../src/streaming/cdc_enhanced.zig");

test "CDC engine basic operations" {
    const allocator = testing.allocator;
    
    const config = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 10,
        .flush_interval_ms = 100,
        .retention_period_ms = 1000,
    };
    
    var engine = try cdc.CDCEngine.init(allocator, config);
    defer engine.deinit();
    
    try engine.start();
    defer engine.stop();
    
    // Capture various change events
    try engine.captureChange(
        .insert,
        .node,
        1,
        null,
        "{\"id\": 1, \"name\": \"Alice\"}"
    );
    
    try engine.captureChange(
        .update,
        .node,
        1,
        "{\"id\": 1, \"name\": \"Alice\"}",
        "{\"id\": 1, \"name\": \"Alice Smith\"}"
    );
    
    try engine.captureChange(
        .insert,
        .edge,
        100,
        null,
        "{\"source\": 1, \"target\": 2, \"type\": \"KNOWS\"}"
    );
    
    try engine.captureChange(
        .delete,
        .node,
        2,
        "{\"id\": 2, \"name\": \"Bob\"}",
        null
    );
    
    // Check status
    const status = engine.getStatus();
    try testing.expect(status.is_running);
    try testing.expectEqual(@as(u64, 4), status.total_events);
    try testing.expect(status.buffer_size <= 4);
}

test "CDC batch flushing" {
    const allocator = testing.allocator;
    
    const config = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 3,
        .flush_interval_ms = 10000, // Long interval to test batch trigger
    };
    
    var engine = try cdc.CDCEngine.init(allocator, config);
    defer engine.deinit();
    
    try engine.start();
    defer engine.stop();
    
    // Add events up to batch size
    try engine.captureChange(.insert, .node, 1, null, "{\"id\": 1}");
    try engine.captureChange(.insert, .node, 2, null, "{\"id\": 2}");
    
    // Buffer should have 2 events
    var status = engine.getStatus();
    try testing.expectEqual(@as(usize, 2), status.buffer_size);
    
    // Add one more to trigger batch flush
    try engine.captureChange(.insert, .node, 3, null, "{\"id\": 3}");
    
    // Buffer should be flushed
    status = engine.getStatus();
    try testing.expectEqual(@as(usize, 0), status.buffer_size);
    try testing.expectEqual(@as(u64, 3), status.total_events);
}

test "CDC retention policy" {
    const allocator = testing.allocator;
    
    const config = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 100,
        .flush_interval_ms = 100,
        .retention_period_ms = 500, // 500ms retention
    };
    
    var engine = try cdc.CDCEngine.init(allocator, config);
    defer engine.deinit();
    
    try engine.start();
    defer engine.stop();
    
    // Add some events
    for (1..6) |i| {
        const json = try std.fmt.allocPrint(allocator, "{{\"id\": {}}}", .{i});
        defer allocator.free(json);
        try engine.captureChange(.insert, .node, i, null, json);
    }
    
    // Wait for retention period
    std.time.sleep(600_000_000); // 600ms
    
    // Trigger cleanup
    engine.mutex.lock();
    try engine.cleanupOldEvents();
    engine.mutex.unlock();
    
    // Old events should be removed
    const status = engine.getStatus();
    try testing.expect(status.buffer_size < 5);
}

test "Multiple CDC sinks" {
    const allocator = testing.allocator;
    
    const config = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{ .memory, .file },
        .batch_size = 5,
        .flush_interval_ms = 100,
    };
    
    var engine = try cdc.CDCEngine.init(allocator, config);
    defer engine.deinit();
    
    try testing.expectEqual(@as(usize, 2), engine.sinks.items.len);
    
    try engine.start();
    defer engine.stop();
    
    // Capture changes
    for (1..6) |i| {
        const json = try std.fmt.allocPrint(allocator, "{{\"id\": {}}}", .{i});
        defer allocator.free(json);
        try engine.captureChange(.insert, .node, i, null, json);
    }
    
    // Both sinks should receive events
    const status = engine.getStatus();
    try testing.expectEqual(@as(usize, 2), status.sinks_count);
}

test "Streaming query creation and management" {
    const allocator = testing.allocator;
    
    const cdc_config = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
    };
    
    var cdc_engine = try cdc.CDCEngine.init(allocator, cdc_config);
    defer cdc_engine.deinit();
    
    var streaming = cdc.StreamingEngine.init(allocator, &cdc_engine);
    defer streaming.deinit();
    
    // Create tumbling window query
    const tumbling_window = cdc.WindowConfig{
        .window_type = .tumbling,
        .size_ms = 60000, // 1 minute windows
        .late_arrival_ms = 5000,
        .watermark_ms = 1000,
    };
    
    const aggregations = [_]cdc.AggregationSpec{
        .{ .field = "count", .function = .count, .alias = "total_count" },
        .{ .field = "value", .function = .sum, .alias = "total_value" },
        .{ .field = "value", .function = .avg, .alias = "avg_value" },
    };
    
    try streaming.createQuery(
        "tumbling_aggregation",
        "MATCH (n:Event) RETURN n.value",
        tumbling_window,
        &aggregations
    );
    
    // Create sliding window query
    const sliding_window = cdc.WindowConfig{
        .window_type = .sliding,
        .size_ms = 60000,
        .slide_ms = 10000, // Slide every 10 seconds
    };
    
    try streaming.createQuery(
        "sliding_aggregation",
        "MATCH (n:Event) WHERE n.type = 'purchase' RETURN n.amount",
        sliding_window,
        &aggregations
    );
    
    // Create session window query
    const session_window = cdc.WindowConfig{
        .window_type = .session,
        .gap_ms = 30000, // 30 second gap defines session boundary
    };
    
    try streaming.createQuery(
        "session_aggregation",
        "MATCH (u:User)-[:ACTION]->(a) RETURN u.id, a.type",
        session_window,
        &aggregations
    );
    
    // Verify queries were created
    try testing.expectEqual(@as(usize, 3), streaming.queries.count());
    try testing.expectEqual(@as(usize, 3), streaming.windows.count());
}

test "Streaming engine lifecycle" {
    const allocator = testing.allocator;
    
    const cdc_config = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
    };
    
    var cdc_engine = try cdc.CDCEngine.init(allocator, cdc_config);
    defer cdc_engine.deinit();
    
    var streaming = cdc.StreamingEngine.init(allocator, &cdc_engine);
    defer streaming.deinit();
    
    // Create a query
    const window = cdc.WindowConfig{
        .window_type = .tumbling,
        .size_ms = 1000,
    };
    
    const aggregations = [_]cdc.AggregationSpec{
        .{ .field = "count", .function = .count },
    };
    
    try streaming.createQuery("test_query", "MATCH (n) RETURN n", window, &aggregations);
    
    // Start streaming
    try streaming.start();
    try testing.expect(streaming.is_running);
    
    // Verify query state
    const query = streaming.queries.get("test_query").?;
    try testing.expect(query.state == .running);
    
    // Stop streaming
    streaming.stop();
    try testing.expect(!streaming.is_running);
    try testing.expect(query.state == .stopped);
}

test "CDC event serialization" {
    const allocator = testing.allocator;
    
    const event = cdc.ChangeEvent{
        .timestamp = 1234567890,
        .transaction_id = 42,
        .change_type = .update,
        .entity_type = .node,
        .entity_id = 100,
        .before = "{\"name\": \"old\"}",
        .after = "{\"name\": \"new\"}",
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    
    const json = try cdc.serializeEvent(allocator, event);
    defer allocator.free(json);
    
    // Verify JSON contains expected fields
    try testing.expect(std.mem.indexOf(u8, json, "\"timestamp\": 1234567890") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"transaction_id\": 42") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"change_type\": \"update\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"entity_type\": \"node\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"entity_id\": 100") != null);
}

test "Kafka sink configuration" {
    const allocator = testing.allocator;
    
    const kafka_config = cdc.KafkaConfig{
        .brokers = "localhost:9092,localhost:9093",
        .topic = "graph-changes",
        .compression = .snappy,
        .batch_size = 16384,
        .linger_ms = 100,
        .acks = .all,
    };
    
    // Verify configuration
    try testing.expectEqualStrings("localhost:9092,localhost:9093", kafka_config.brokers);
    try testing.expectEqualStrings("graph-changes", kafka_config.topic);
    try testing.expect(kafka_config.compression == .snappy);
    try testing.expect(kafka_config.acks == .all);
}

test "Webhook sink configuration" {
    const allocator = testing.allocator;
    
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    
    try headers.put("Content-Type", "application/json");
    try headers.put("Authorization", "Bearer token123");
    
    const webhook_config = cdc.WebhookConfig{
        .url = "https://example.com/webhook",
        .method = .POST,
        .headers = headers,
        .retry_count = 3,
        .timeout_ms = 5000,
    };
    
    try testing.expectEqualStrings("https://example.com/webhook", webhook_config.url);
    try testing.expect(webhook_config.method == .POST);
    try testing.expectEqual(@as(u32, 3), webhook_config.retry_count);
}

test "System procedures for CDC control" {
    const allocator = testing.allocator;
    
    const config = cdc.CDCConfig{
        .enabled = true,
        .sinks = &[_]cdc.CDCSink{.memory},
        .batch_size = 10,
        .flush_interval_ms = 100,
    };
    
    // Start CDC using system procedure
    const engine = try cdc.startCDC(allocator, config);
    defer {
        cdc.stopCDC(engine);
        engine.deinit();
        allocator.destroy(engine);
    }
    
    // Get status using system procedure
    const status = cdc.getCDCStatus(engine);
    try testing.expect(status.is_running);
    
    // Capture some changes
    try engine.captureChange(.insert, .node, 1, null, "{\"id\": 1}");
    try engine.captureChange(.insert, .node, 2, null, "{\"id\": 2}");
    
    // Check updated status
    const new_status = cdc.getCDCStatus(engine);
    try testing.expectEqual(@as(u64, 2), new_status.total_events);
}

test "Window bucket management" {
    const allocator = testing.allocator;
    
    const window_config = cdc.WindowConfig{
        .window_type = .tumbling,
        .size_ms = 1000,
    };
    
    var window = try cdc.Window.init(allocator, window_config);
    defer window.deinit();
    
    // Add buckets
    var bucket1 = cdc.WindowBucket{
        .start_time = 0,
        .end_time = 1000,
        .events = std.ArrayList(cdc.ChangeEvent).init(allocator),
        .aggregates = std.StringHashMap(f64).init(allocator),
    };
    defer bucket1.deinit();
    
    try window.buckets.append(bucket1);
    
    try testing.expectEqual(@as(usize, 1), window.buckets.items.len);
}

test "Trigger configuration" {
    const processing_trigger = cdc.TriggerConfig{
        .mode = .processing_time,
        .interval_ms = 1000,
        .max_delay_ms = null,
    };
    
    const event_trigger = cdc.TriggerConfig{
        .mode = .event_time,
        .interval_ms = null,
        .max_delay_ms = 5000,
    };
    
    const continuous_trigger = cdc.TriggerConfig{
        .mode = .continuous,
        .interval_ms = null,
        .max_delay_ms = null,
    };
    
    try testing.expect(processing_trigger.mode == .processing_time);
    try testing.expect(event_trigger.mode == .event_time);
    try testing.expect(continuous_trigger.mode == .continuous);
}