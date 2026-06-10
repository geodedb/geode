//! GAP-0855b regression: the Kafka CDC sink must perform REAL produce-only
//! delivery over the Kafka wire protocol (ApiVersions -> Metadata -> Produce v3,
//! RecordBatch v2 with CRC32C), and reconnect/retry when the broker drops the
//! connection mid-handshake.
//!
//! The test stands up an in-process fake broker: a real TCP listener that
//! speaks just enough of the protocol to satisfy the sink. It echoes the
//! request correlation ids back in well-formed responses and, for Produce,
//! parses the request body to confirm the topic name and locate the value
//! bytes inside the RecordBatch the sink encoded. This is a genuine socket
//! fixture, not a mock of the sink — the sink's real wire encoder/transport
//! drives every byte.

const std = @import("std");
const geode = @import("geode");

const kafka_sink = geode.streaming.sinks.kafka_sink;
const kafka_wire = geode.streaming.sinks.kafka_wire;
const cdc_sinks = geode.streaming.cdc_sinks;
const KafkaSink = kafka_sink.KafkaSink;
const KafkaConfig = kafka_sink.KafkaConfig;
const ChangeEvent = cdc_sinks.ChangeEvent;

const io = std.Io.Threaded.global_single_threaded.io();

const FakeBroker = struct {
    server: std.Io.net.Server,
    port: u16,
    /// If true, the broker closes the connection right after accepting the
    /// FIRST connection (no response) to force a sink reconnect.
    drop_first: bool,
    /// Captured from the Produce request of the LAST fully-served connection.
    saw_value: bool = false,
    saw_topic: bool = false,
    accepted: usize = 0,
    err: ?anyerror = null,
    thread: ?std.Thread = null,
    expected_conns: usize,

    fn start(drop_first: bool, expected_conns: usize) !*FakeBroker {
        const self = try std.testing.allocator.create(FakeBroker);
        errdefer std.testing.allocator.destroy(self);

        var port: u16 = 0;
        var server: std.Io.net.Server = undefined;
        var p: u16 = 39080;
        while (p < 39980) : (p += 1) {
            const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch unreachable;
            server = std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch continue;
            port = p;
            break;
        }
        if (port == 0) return error.NoFreePort;

        self.* = .{
            .server = server,
            .port = port,
            .drop_first = drop_first,
            .expected_conns = expected_conns,
        };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn stop(self: *FakeBroker) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.server.deinit(io);
        std.testing.allocator.destroy(self);
    }

    fn run(self: *FakeBroker) void {
        var conn: usize = 0;
        while (conn < self.expected_conns) : (conn += 1) {
            const stream = self.server.accept(io) catch |e| {
                self.err = e;
                return;
            };
            self.accepted += 1;
            if (self.drop_first and conn == 0) {
                // Simulate a broker that drops the connection before responding.
                stream.close(io);
                continue;
            }
            self.serve(stream) catch |e| {
                self.err = e;
                stream.close(io);
                return;
            };
            stream.close(io);
        }
    }

    /// Serve one connection: read 3 request frames (ApiVersions, Metadata,
    /// Produce) and answer each with a minimal valid response echoing the
    /// correlation id.
    fn serve(self: *FakeBroker, stream: std.Io.net.Stream) !void {
        var rbuf: [16384]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);
        const r = &reader.interface;
        const w = &writer.interface;

        // Request 1: ApiVersions
        {
            const req = try readFrame(r);
            defer std.testing.allocator.free(req);
            const cid = correlationId(req);
            try writeApiVersionsResponse(w, cid);
        }
        // Request 2: Metadata
        {
            const req = try readFrame(r);
            defer std.testing.allocator.free(req);
            const cid = correlationId(req);
            try writeMetadataResponse(w, cid, self.port);
        }
        // Request 3: Produce — inspect the body, then ack success.
        {
            const req = try readFrame(r);
            defer std.testing.allocator.free(req);
            const cid = correlationId(req);
            self.inspectProduce(req);
            try writeProduceResponse(w, cid);
        }
    }

    fn inspectProduce(self: *FakeBroker, frame: []const u8) void {
        // Topic name "cdc-topic" and value bytes must be embedded in the request.
        if (std.mem.indexOf(u8, frame, "cdc-topic") != null) self.saw_topic = true;
        if (std.mem.indexOf(u8, frame, "alice-payload") != null) self.saw_value = true;
    }

    /// Read a Kafka frame (int32 length prefix + payload); caller frees.
    fn readFrame(r: *std.Io.Reader) ![]u8 {
        var lenbuf: [4]u8 = undefined;
        try r.readSliceAll(&lenbuf);
        const len = std.mem.readInt(i32, &lenbuf, .big);
        if (len < 0) return error.BadFrame;
        const n: usize = @intCast(len);
        const buf = try std.testing.allocator.alloc(u8, n);
        errdefer std.testing.allocator.free(buf);
        try r.readSliceAll(buf);
        return buf;
    }

    /// Correlation id sits in the request header after api_key(2)+api_version(2).
    fn correlationId(req: []const u8) i32 {
        if (req.len < 8) return -1;
        return std.mem.readInt(i32, req[4..8], .big);
    }

    fn writeFramed(w: *std.Io.Writer, payload: []const u8) !void {
        var lenbuf: [4]u8 = undefined;
        std.mem.writeInt(i32, &lenbuf, @intCast(payload.len), .big);
        try w.writeAll(&lenbuf);
        try w.writeAll(payload);
        try w.flush();
    }

    fn writeApiVersionsResponse(w: *std.Io.Writer, cid: i32) !void {
        // ApiVersions(v0) response: correlation_id, error_code(int16),
        // api_versions array (int32 count) of {api_key i16, min i16, max i16}.
        var enc = kafka_wire.Encoder.init(std.testing.allocator);
        defer enc.deinit();
        try enc.putI32(cid);
        try enc.putI16(0); // error_code
        try enc.putI32(1); // one entry
        try enc.putI16(0); // api_key = produce
        try enc.putI16(0); // min
        try enc.putI16(7); // max
        try writeFramed(w, enc.buf.items);
    }

    fn writeMetadataResponse(w: *std.Io.Writer, cid: i32, port: u16) !void {
        // Metadata(v1) response (minimal but well-formed):
        //   correlation_id i32
        //   brokers: ARRAY{ node_id i32, host STRING, port i32, rack NULLABLE_STRING }
        //   controller_id i32
        //   topics: ARRAY{ error_code i16, name STRING, is_internal i8,
        //     partitions: ARRAY{ error_code i16, partition i32, leader i32,
        //       replicas ARRAY<i32>, isr ARRAY<i32> } }
        var enc = kafka_wire.Encoder.init(std.testing.allocator);
        defer enc.deinit();
        try enc.putI32(cid);
        try enc.putI32(1); // 1 broker
        try enc.putI32(0); // node_id
        try enc.putString("127.0.0.1");
        try enc.putI32(@intCast(port));
        try enc.putI16(-1); // rack = null
        try enc.putI32(0); // controller_id
        try enc.putI32(1); // 1 topic
        try enc.putI16(0); // topic error_code
        try enc.putString("cdc-topic");
        try enc.putI8(0); // is_internal
        try enc.putI32(1); // 1 partition
        try enc.putI16(0); // partition error_code
        try enc.putI32(0); // partition index
        try enc.putI32(0); // leader = node 0
        try enc.putI32(0); // replicas: 0 entries
        try enc.putI32(0); // isr: 0 entries
        try writeFramed(w, enc.buf.items);
    }

    fn writeProduceResponse(w: *std.Io.Writer, cid: i32) !void {
        // Produce(v3) response: correlation_id, topics ARRAY{ name, partitions
        // ARRAY{ index i32, error_code i16, base_offset i64, log_append_time i64 } },
        // throttle_time_ms i32.
        var enc = kafka_wire.Encoder.init(std.testing.allocator);
        defer enc.deinit();
        try enc.putI32(cid);
        try enc.putI32(1); // 1 topic
        try enc.putString("cdc-topic");
        try enc.putI32(1); // 1 partition
        try enc.putI32(0); // partition index
        try enc.putI16(0); // error_code = 0 (success)
        try enc.putI64(0); // base_offset
        try enc.putI64(-1); // log_append_time
        try enc.putI32(0); // throttle_time_ms
        try writeFramed(w, enc.buf.items);
    }
};

fn makeEvent() ChangeEvent {
    return .{
        .timestamp = 1700000000000,
        .transaction_id = 9,
        .sequence = 55,
        .change_type = .insert,
        .entity_type = .node,
        .entity_id = 4242,
        .before = null,
        .after = "{\"name\":\"alice-payload\"}",
        .metadata = std.StringHashMap([]const u8).init(std.testing.allocator),
    };
}

test "GAP-0855b kafka sink produces a record over the wire (topic + value round-trip)" {
    var broker = try FakeBroker.start(false, 1);
    defer broker.stop();

    const broker_addr = try std.fmt.allocPrint(std.testing.allocator, "127.0.0.1:{d}", .{broker.port});
    defer std.testing.allocator.free(broker_addr);
    const brokers = [_][]const u8{broker_addr};

    const config = KafkaConfig{
        .brokers = &brokers,
        .topic = "cdc-topic",
        .partition = 0,
    };
    var sink = KafkaSink.initWithConfig(std.testing.allocator, config);
    defer sink.deinit();

    const events = [_]ChangeEvent{makeEvent()};
    try sink.send(&events);

    if (broker.thread) |t| {
        t.join();
        broker.thread = null;
    }
    if (broker.err) |e| {
        std.debug.print("broker error: {s}\n", .{@errorName(e)});
        return error.BrokerFailed;
    }
    try std.testing.expect(broker.saw_topic);
    try std.testing.expect(broker.saw_value);
    try std.testing.expectEqual(@as(usize, 1), broker.accepted);
}

test "GAP-0855b kafka sink reconnects and retries when the broker drops the first connection" {
    // Broker drops the first connection (no response), serves the second fully.
    var broker = try FakeBroker.start(true, 2);
    defer broker.stop();

    const broker_addr = try std.fmt.allocPrint(std.testing.allocator, "127.0.0.1:{d}", .{broker.port});
    defer std.testing.allocator.free(broker_addr);
    const brokers = [_][]const u8{broker_addr};

    const config = KafkaConfig{
        .brokers = &brokers,
        .topic = "cdc-topic",
        .partition = 0,
    };
    var sink = KafkaSink.initWithConfig(std.testing.allocator, config);
    defer sink.deinit();

    const events = [_]ChangeEvent{makeEvent()};
    try sink.send(&events); // must succeed on the retry

    if (broker.thread) |t| {
        t.join();
        broker.thread = null;
    }
    try std.testing.expect(broker.err == null);
    try std.testing.expect(broker.saw_value);
    try std.testing.expectEqual(@as(usize, 2), broker.accepted);
}

test "GAP-0855b kafka sink surfaces failure when no broker is reachable" {
    // Point at a closed port so connect fails on every attempt.
    const brokers = [_][]const u8{"127.0.0.1:1"};
    const config = KafkaConfig{ .brokers = &brokers, .topic = "cdc-topic", .partition = 0 };
    var sink = KafkaSink.initWithConfig(std.testing.allocator, config);
    defer sink.deinit();

    const events = [_]ChangeEvent{makeEvent()};
    try std.testing.expectError(error.KafkaSendFailed, sink.send(&events));
}
