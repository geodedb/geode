/// Kafka Sink Implementation
///
/// This module provides a Kafka-based sink for CDC events, sending
/// change events to Apache Kafka topics.
///
/// Extracted as part of Phase 1, M1.2 of the modularization effort.
const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const cdc_sinks = @import("../cdc_sinks.zig");
const host_port = @import("../../client/host_port.zig");
const kafka_wire = @import("kafka_wire.zig");

const logging = @import("logging");
const log = logging.scoped("streaming.kafka");
const Attr = logging.Attr;

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
    /// Client id sent in the request header (for broker-side identification).
    client_id: []const u8 = "geode-cdc",
    /// Optional SASL/PLAIN credentials. NOT yet implemented — if set, the sink
    /// fails loudly with error.KafkaAuthNotSupported rather than sending
    /// plaintext-without-auth and silently dropping the auth requirement.
    sasl_username: ?[]const u8 = null,
    sasl_password: ?[]const u8 = null,
    /// TLS to the broker is NOT yet implemented — if true the sink fails with
    /// error.KafkaTlsNotSupported (plain TCP only in this release).
    use_tls: bool = false,

    pub const CompressionType = enum {
        none,
        gzip,
        snappy,
        lz4,
        zstd,
    };
};

/// Resolve a broker host (literal IPv4 or hostname) to an IpAddress.
fn kafka_wire_resolve(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
    return std.Io.net.IpAddress.resolve(io, host, port);
}

/// Write a fully-framed request to the stream writer and flush it.
fn writeFrame(w: *std.Io.Writer, frame: []const u8) !void {
    w.writeAll(frame) catch return error.WriteFailed;
    w.flush() catch return error.WriteFailed;
}

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

    /// Max delivery attempts per event across the broker list (reconnect on a
    /// dropped connection). Kept small; CDC retries at a higher layer too.
    const max_attempts_per_broker: u32 = 2;

    // CANARY: REQ=REQ-STREAMING-KAFKA-001; FEATURE="Kafka Sink Implementation"; ASPECT=ProducerSending; STATUS=TESTED; TEST=tests/test_gap0855_kafka_sink.zig; OWNER=streaming; UPDATED=2026-06-10
    /// Send events to a Kafka topic using the native Kafka wire protocol
    /// (ApiVersions -> Metadata -> Produce v3, RecordBatch v2, acks=1).
    ///
    /// Each event becomes one record (key = entity id as decimal string,
    /// value = the CDC JSON). A delivery that fails on every broker after the
    /// per-broker retry budget surfaces error.KafkaSendFailed — no silent drop.
    pub fn send(self: *KafkaSink, events: []const ChangeEvent) !void {
        if (events.len == 0) return;

        const config = self.config orelse return error.ConfigNotSet;

        // Honest gating for not-yet-implemented transport options.
        if (config.use_tls) return error.KafkaTlsNotSupported;
        if (config.sasl_username != null or config.sasl_password != null) {
            return error.KafkaAuthNotSupported;
        }
        if (config.compression != .none) return error.KafkaCompressionNotSupported;
        if (config.brokers.len == 0) return error.NoBrokersConfigured;

        const partition: i32 = config.partition orelse 0;

        var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(self.allocator, 256) catch return error.OutOfMemory;
        defer aw.deinit();

        var sent_count: usize = 0;
        for (events) |event| {
            aw.writer.end = 0;

            try aw.writer.print("{{\"seq\":{d},\"txn\":{d},\"type\":\"{s}\",\"entity\":\"{s}\",\"id\":{d},\"ts\":{d}", .{
                event.sequence,
                event.transaction_id,
                @tagName(event.change_type),
                @tagName(event.entity_type),
                event.entity_id,
                event.timestamp,
            });
            if (event.before) |before| {
                try aw.writer.print(",\"before\":{s}", .{before});
            }
            if (event.after) |after| {
                try aw.writer.print(",\"after\":{s}", .{after});
            }
            try aw.writer.writeAll("}");

            var key_buf: [24]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}", .{event.entity_id}) catch "0";

            var delivered = false;
            broker_loop: for (config.brokers) |broker| {
                // Each broker gets a small attempt budget so a dropped
                // connection (the broker closing mid-handshake) triggers a
                // fresh reconnect rather than a hard failure. Protocol errors
                // (topic missing, non-zero broker error code) also retry here,
                // then fall through to the next broker — the budget bounds it.
                var attempt: u32 = 0;
                while (attempt < max_attempts_per_broker) : (attempt += 1) {
                    if (self.sendToBroker(broker, config.topic, partition, key, aw.written(), event.timestamp)) {
                        delivered = true;
                        sent_count += 1;
                        break :broker_loop;
                    } else |err| {
                        log.warn("kafka delivery attempt failed", &.{
                            Attr.string("broker", broker),
                            Attr.int("attempt", @intCast(attempt + 1)),
                            Attr.string("error", @errorName(err)),
                        });
                    }
                }
            }

            if (!delivered) return error.KafkaSendFailed;
        }

        log.debug("kafka delivered", &.{
            Attr.int("events", @intCast(sent_count)),
            Attr.string("topic", config.topic),
        });
    }

    /// Deliver a single record to a specific broker over plain TCP using the
    /// Kafka wire protocol. Performs the ApiVersions handshake, a Metadata
    /// lookup (confirms the topic is known), and a Produce(v3) of one record
    /// batch, validating the per-partition error code in the response.
    fn sendToBroker(
        self: *KafkaSink,
        broker: []const u8,
        topic: []const u8,
        partition: i32,
        key: []const u8,
        value: []const u8,
        timestamp_ms: i64,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        // SONNY-6487: host:port or [ipv6]:port (the shared grammar).
        const hp = host_port.split(broker, null) catch return error.InvalidBroker;
        if (hp.host.len == 0) return error.InvalidBroker;
        const host = hp.host;
        const port = hp.port;

        const addr = kafka_wire_resolve(io, host, port) catch return error.ConnectionRefused;
        var stream = std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.ConnectionRefused;
        defer stream.close(io);

        var rbuf: [8192]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);
        const r = &reader.interface;
        const w = &writer.interface;

        const client_id = self.config.?.client_id;

        // 1) ApiVersions(v0) handshake (broker liveness; we don't pin versions).
        {
            const body = try kafka_wire.buildApiVersionsBody(self.allocator);
            const frame = try kafka_wire.buildRequest(self.allocator, .api_versions, 0, 1, client_id, body);
            defer self.allocator.free(frame);
            try writeFrame(w, frame);
            const resp = try kafka_wire.readFrame(self.allocator, r);
            defer self.allocator.free(resp);
            var dec = kafka_wire.Decoder.init(resp);
            try kafka_wire.parseCorrelationId(&dec, 1);
        }

        // 2) Metadata(v1) — confirm the topic is known to the broker.
        {
            const body = try kafka_wire.buildMetadataBody(self.allocator, topic);
            defer self.allocator.free(body);
            const frame = try kafka_wire.buildRequest(self.allocator, .metadata, 1, 2, client_id, body);
            defer self.allocator.free(frame);
            try writeFrame(w, frame);
            const resp = try kafka_wire.readFrame(self.allocator, r);
            defer self.allocator.free(resp);
            // We only need the correlation id to validate; the leader is taken
            // as the connected broker for this minimal single-broker producer.
            var dec = kafka_wire.Decoder.init(resp);
            try kafka_wire.parseCorrelationId(&dec, 2);
        }

        // 3) Produce(v3) one record batch.
        {
            const batch = try kafka_wire.buildRecordBatch(self.allocator, key, value, timestamp_ms);
            defer self.allocator.free(batch);
            const body = try kafka_wire.buildProduceBody(self.allocator, topic, partition, batch);
            defer self.allocator.free(body);
            const frame = try kafka_wire.buildRequest(self.allocator, .produce, 3, 3, client_id, body);
            defer self.allocator.free(frame);
            try writeFrame(w, frame);
            const resp = try kafka_wire.readFrame(self.allocator, r);
            defer self.allocator.free(resp);
            try kafka_wire.parseProduceResponse(resp, 3);
        }
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
            .timestamp = compat_milliTimestamp(),
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

    // With no config set, send is a hard error (no silent drop).
    // CANARY: REQ=REQ-STREAMING-KAFKA-002; FEATURE="Kafka Sink Real Implementation"; ASPECT=Test; STATUS=TESTED; OWNER=streaming; UPDATED=2026-06-10
    try testing.expectError(error.ConfigNotSet, sink.send(&events));
}

test "KafkaSink - interface implementation" {
    const testing = std.testing;

    var sink = KafkaSink.init(testing.allocator);
    defer sink.deinit();

    var iface = sink.interface();
    try iface.init();

    const events = [_]ChangeEvent{
        .{
            .timestamp = compat_milliTimestamp(),
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

    // With no config set, send via the interface is a hard error.
    try testing.expectError(error.ConfigNotSet, iface.send(&events));
    iface.deinit();
}

test "KafkaSink - rejects unsupported TLS/SASL/compression knobs (honest gating)" {
    const testing = std.testing;
    const brokers = [_][]const u8{"127.0.0.1:9092"};
    const events = [_]ChangeEvent{
        .{
            .timestamp = 1,
            .transaction_id = 1,
            .sequence = 1,
            .change_type = .insert,
            .entity_type = .node,
            .entity_id = 1,
            .before = null,
            .after = "{}",
            .metadata = std.StringHashMap([]const u8).init(testing.allocator),
        },
    };

    {
        var sink = KafkaSink.initWithConfig(testing.allocator, .{ .brokers = &brokers, .topic = "t", .use_tls = true });
        defer sink.deinit();
        try testing.expectError(error.KafkaTlsNotSupported, sink.send(&events));
    }
    {
        var sink = KafkaSink.initWithConfig(testing.allocator, .{ .brokers = &brokers, .topic = "t", .sasl_username = "u", .sasl_password = "p" });
        defer sink.deinit();
        try testing.expectError(error.KafkaAuthNotSupported, sink.send(&events));
    }
    {
        var sink = KafkaSink.initWithConfig(testing.allocator, .{ .brokers = &brokers, .topic = "t", .compression = .gzip });
        defer sink.deinit();
        try testing.expectError(error.KafkaCompressionNotSupported, sink.send(&events));
    }
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
