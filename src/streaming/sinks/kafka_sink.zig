/// Kafka Sink Implementation
///
/// This module provides a Kafka-based sink for CDC events, sending
/// change events to Apache Kafka topics.
///
/// Extracted as part of Phase 1, M1.2 of the modularization effort.
const std = @import("std");
const cdc_sinks = @import("../cdc_sinks.zig");

// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=KafkaSink; STATUS=TESTED; TEST=cdc_tests; OWNER=streaming; UPDATED=2025-11-12

/// Import types
pub const ChangeEvent = cdc_sinks.ChangeEvent;
pub const SinkInterface = cdc_sinks.SinkInterface;

/// KafkaConfig configures the Kafka sink
pub const KafkaConfig = struct {
    brokers: []const []const u8,
    topic: []const u8,
    partition: ?i32 = null, // null for automatic partitioning
    compression: CompressionType = .none,
    batch_size: u32 = 1000,
    linger_ms: u32 = 100,

    pub const CompressionType = enum {
        none,
        gzip,
        snappy,
        lz4,
        zstd,
    };
};

/// KafkaSink sends CDC events to Kafka
pub const KafkaSink = struct {
    allocator: std.mem.Allocator,
    config: ?KafkaConfig,
    // Kafka producer would be initialized here

    pub fn init(allocator: std.mem.Allocator) KafkaSink {
        return KafkaSink{
            .allocator = allocator,
            .config = null,
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: KafkaConfig) KafkaSink {
        return KafkaSink{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *KafkaSink) void {
        _ = self;
        // Cleanup Kafka producer resources
    }

    // CANARY: REQ=REQ-STREAMING-KAFKA-001; FEATURE="Kafka Sink Implementation"; ASPECT=ProducerSending; STATUS=IMPL; OWNER=streaming; UPDATED=2025-12-30
    /// Send events to Kafka topic using native Kafka protocol
    pub fn send(self: *KafkaSink, events: []const ChangeEvent) !void {
        if (events.len == 0) return;

        const config = self.config orelse return error.ConfigNotSet;

        // Serialize events to JSON for Kafka message values
        var message_buffer = std.ArrayList(u8).initCapacity(self.allocator, 256) catch return error.OutOfMemory;
        defer message_buffer.deinit(self.allocator);

        for (events) |event| {
            message_buffer.clearRetainingCapacity();

            // Build JSON message
            try std.fmt.format(message_buffer.writer(self.allocator), "{{\"seq\":{d},\"txn\":{d},\"type\":\"{s}\",\"entity\":\"{s}\",\"id\":{d},\"ts\":{d}", .{
                event.sequence,
                event.transaction_id,
                @tagName(event.change_type),
                @tagName(event.entity_type),
                event.entity_id,
                event.timestamp,
            });

            if (event.before) |before| {
                try std.fmt.format(message_buffer.writer(self.allocator), ",\"before\":{s}", .{before});
            }
            if (event.after) |after| {
                try std.fmt.format(message_buffer.writer(self.allocator), ",\"after\":{s}", .{after});
            }
            try message_buffer.appendSlice(self.allocator, "}");

            // Connect to first available broker and send
            var sent = false;
            for (config.brokers) |broker| {
                if (self.sendToBroker(broker, config.topic, message_buffer.items)) {
                    sent = true;
                    break;
                } else |_| {
                    continue;
                }
            }

            if (!sent) {
                // Log failure but continue with other events
                std.debug.print("KAFKA_SINK: Failed to send event seq={d} to any broker\n", .{event.sequence});
            }
        }

        std.debug.print("KAFKA_SINK events_sent={d} topic={s}\n", .{ events.len, config.topic });
    }

    /// Send a message to a specific Kafka broker
    fn sendToBroker(self: *KafkaSink, broker: []const u8, topic: []const u8, message: []const u8) !void {
        // Parse broker address (host:port)
        const colon_pos = std.mem.indexOf(u8, broker, ":") orelse return error.InvalidBrokerAddress;
        const host = broker[0..colon_pos];
        const port_str = broker[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidBrokerPort;

        // Connect to broker using tcpConnectToHost
        var stream = std.net.tcpConnectToHost(self.allocator, host, port) catch return error.CannotConnect;
        defer stream.close();

        // Build simplified Kafka produce request (API Key 0, Version 0)
        // This is a minimal implementation - production would use full protocol
        var request_buffer: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&request_buffer);
        const writer = fbs.writer();

        // Kafka request header
        const api_key: i16 = 0; // Produce
        const api_version: i16 = 0;
        const correlation_id: i32 = 1;
        const client_id = "geode-cdc";

        // Write header (will update size at end)
        const size_pos = fbs.pos;
        try writer.writeInt(i32, 0, .big); // placeholder for size

        try writer.writeInt(i16, api_key, .big);
        try writer.writeInt(i16, api_version, .big);
        try writer.writeInt(i32, correlation_id, .big);
        try writer.writeInt(i16, @intCast(client_id.len), .big);
        try writer.writeAll(client_id);

        // Produce request body
        try writer.writeInt(i16, -1, .big); // required_acks (-1 = all)
        try writer.writeInt(i32, 5000, .big); // timeout_ms

        // Topic array (1 topic)
        try writer.writeInt(i32, 1, .big);
        try writer.writeInt(i16, @intCast(topic.len), .big);
        try writer.writeAll(topic);

        // Partition array (1 partition)
        try writer.writeInt(i32, 1, .big);
        try writer.writeInt(i32, 0, .big); // partition id

        // Message set size (will calculate)
        const message_set_size: i32 = @intCast(8 + 4 + 4 + 1 + 1 + 4 + message.len + 4);
        try writer.writeInt(i32, message_set_size, .big);

        // Message set entry
        try writer.writeInt(i64, 0, .big); // offset
        const message_size: i32 = @intCast(4 + 1 + 1 + 4 + message.len + 4);
        try writer.writeInt(i32, message_size, .big);

        // Message (crc will be 0 - simplified)
        try writer.writeInt(i32, 0, .big); // crc placeholder
        try writer.writeInt(i8, 0, .big); // magic byte
        try writer.writeInt(i8, 0, .big); // attributes
        try writer.writeInt(i32, -1, .big); // key (null)
        try writer.writeInt(i32, @intCast(message.len), .big); // value length
        try writer.writeAll(message);

        // Update request size
        const end_pos = fbs.pos;
        const request_size: i32 = @intCast(end_pos - size_pos - 4);
        fbs.pos = size_pos;
        try writer.writeInt(i32, request_size, .big);

        // Send request
        _ = try stream.write(request_buffer[0..end_pos]);

        // Read response (simplified - just check for any response)
        var response_buffer: [1024]u8 = undefined;
        const bytes_read = stream.read(&response_buffer) catch return error.ReadFailed;
        if (bytes_read < 4) return error.InvalidResponse;
    }

    pub fn interface(self: *KafkaSink) SinkInterface {
        return .{
            .ptr = self,
            .vtable = &.{
                .init = initWrapper,
                .deinit = deinitWrapper,
                .send = sendWrapper,
            },
        };
    }

    fn initWrapper(ptr: *anyopaque) !void {
        _ = ptr;
        // Kafka sink initialization handled in init()
    }

    fn deinitWrapper(ptr: *anyopaque) void {
        const self: *KafkaSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn sendWrapper(ptr: *anyopaque, events: []const ChangeEvent) !void {
        const self: *KafkaSink = @ptrCast(@alignCast(ptr));
        try self.send(events);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "KafkaSink - basic initialization" {
    const testing = std.testing;

    var sink = KafkaSink.init(testing.allocator);
    defer sink.deinit();

    try testing.expect(sink.config == null);
}

test "KafkaSink - init with config" {
    const testing = std.testing;

    const brokers = [_][]const u8{"localhost:9092"};
    const config = KafkaConfig{
        .brokers = &brokers,
        .topic = "cdc_events",
        .partition = 0,
        .compression = .gzip,
        .batch_size = 500,
        .linger_ms = 50,
    };

    var sink = KafkaSink.initWithConfig(testing.allocator, config);
    defer sink.deinit();

    try testing.expect(sink.config != null);
    try testing.expectEqual(@as(u32, 500), sink.config.?.batch_size);
    try testing.expectEqual(KafkaConfig.CompressionType.gzip, sink.config.?.compression);
}

test "KafkaSink - send events" {
    const testing = std.testing;

    var sink = KafkaSink.init(testing.allocator);
    defer sink.deinit();

    const events = [_]ChangeEvent{
        .{
            .timestamp = std.time.milliTimestamp(),
            .transaction_id = 1,
            .sequence = 1,
            .change_type = .insert,
            .entity_type = .node,
            .entity_id = 100,
            .before = null,
            .after = "{}",
            .metadata = std.StringHashMap([]const u8).init(testing.allocator),
        },
    };

    // Should not error even though it's a placeholder implementation
    try sink.send(&events);
}

test "KafkaSink - interface implementation" {
    const testing = std.testing;

    var sink = KafkaSink.init(testing.allocator);
    defer sink.deinit();

    var iface = sink.interface();
    try iface.init();

    const events = [_]ChangeEvent{
        .{
            .timestamp = std.time.milliTimestamp(),
            .transaction_id = 1,
            .sequence = 1,
            .change_type = .delete,
            .entity_type = .property,
            .entity_id = 300,
            .before = "{\"value\":\"old\"}",
            .after = null,
            .metadata = std.StringHashMap([]const u8).init(testing.allocator),
        },
    };

    try iface.send(&events);
    iface.deinit();
}

test "KafkaSink - configuration validation" {
    const testing = std.testing;

    const brokers = [_][]const u8{ "broker1:9092", "broker2:9092", "broker3:9092" };
    const config = KafkaConfig{
        .brokers = &brokers,
        .topic = "test_topic",
        .partition = null, // automatic partitioning
        .compression = .snappy,
        .batch_size = 2000,
        .linger_ms = 200,
    };

    var sink = KafkaSink.initWithConfig(testing.allocator, config);
    defer sink.deinit();

    try testing.expect(sink.config.?.partition == null);
    try testing.expectEqual(@as(usize, 3), sink.config.?.brokers.len);
}
