const std = @import("std");
const Allocator = std.mem.Allocator;

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Streaming; STATUS=IMPL; OWNER=streaming; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("streaming");
const Attr = logging.Attr;

pub const ChangeType = enum {
    insert,
    update,
    delete,
    truncate,
};

pub const ChangeEvent = struct {
    sequence_number: u64,
    timestamp: i64,
    transaction_id: u64,
    change_type: ChangeType,
    graph_id: u32,
    object_type: enum { node, edge, property },
    object_id: u64,
    before: ?[]const u8, // JSON representation
    after: ?[]const u8, // JSON representation
    metadata: std.StringHashMap([]const u8),
};

pub const CDCConfiguration = struct {
    enabled: bool = false,
    capture_mode: enum { full, incremental } = .incremental,
    retention_period_ms: u64 = 7 * 24 * 60 * 60 * 1000, // 7 days
    max_event_size: usize = 1024 * 1024, // 1MB
    filter_expression: ?[]const u8 = null,
    sink_type: SinkType = .memory,
    // Sink-specific configuration
    file_path: ?[]const u8 = null, // For file sink
    kafka_config: ?KafkaConfig = null, // For kafka sink
    webhook_url: ?[]const u8 = null, // For webhook sink
    webhook_auth_header: ?[]const u8 = null, // Optional auth header for webhook
    batch_size: u32 = 100, // Events per batch
    flush_interval_ms: u64 = 1000, // Flush interval in ms
};

/// Transaction context for CDC event correlation
/// GAP-0073: Provides transaction ID for CDC event tracking
// CANARY: REQ=REQ-GQL-CDC-TXID-001; FEATURE="CDCTransactionTracking"; ASPECT=Consistency; STATUS=IMPL; OWNER=streaming; UPDATED=2026-01-10
pub const TransactionContext = struct {
    /// Current transaction ID (0 = no active transaction)
    transaction_id: u64 = 0,
    /// Transaction start timestamp
    start_ts: i64 = 0,
    /// Transaction isolation level
    isolation_level: enum { read_uncommitted, read_committed, repeatable_read, serializable } = .read_committed,

    /// Begin a new transaction
    pub fn begin(self: *TransactionContext) void {
        self.transaction_id = generateTransactionId();
        self.start_ts = std.time.milliTimestamp();
    }

    /// Commit the current transaction
    pub fn commit(self: *TransactionContext) void {
        self.transaction_id = 0;
        self.start_ts = 0;
    }

    /// Rollback the current transaction
    pub fn rollback(self: *TransactionContext) void {
        self.transaction_id = 0;
        self.start_ts = 0;
    }

    /// Check if a transaction is active
    pub fn isActive(self: *const TransactionContext) bool {
        return self.transaction_id != 0;
    }
};

/// Thread-local transaction context
threadlocal var current_transaction: TransactionContext = .{};

/// Get the current transaction context for this thread
pub fn getCurrentTransaction() *TransactionContext {
    return &current_transaction;
}

/// Get current transaction ID (0 if no active transaction)
pub fn getCurrentTransactionId() u64 {
    return current_transaction.transaction_id;
}

/// Generate unique transaction ID using timestamp + random component
fn generateTransactionId() u64 {
    const ts: u64 = @intCast(std.time.milliTimestamp());
    var rand_bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const rand: u32 = std.mem.readInt(u32, &rand_bytes, .little);
    return (ts << 20) | (@as(u64, rand) & 0xFFFFF);
}

pub const SinkType = enum {
    memory,
    file,
    kafka,
    kinesis,
    pubsub,
    webhook,
};

pub const KafkaConfig = struct {
    brokers: []const u8,
    topic: []const u8,
    compression: enum { none, gzip, snappy, lz4 } = .snappy,
    batch_size: u32 = 1000,
    linger_ms: u32 = 100,
};

pub const StreamQuery = struct {
    query: []const u8,
    window_type: WindowType,
    window_size: u64,
    aggregations: []const Aggregation,
    output_mode: OutputMode,
};

pub const WindowType = enum {
    tumbling,
    sliding,
    session,
    global,
};

pub const Aggregation = enum {
    count,
    sum,
    avg,
    min,
    max,
    first,
    last,
};

pub const OutputMode = enum {
    append,
    update,
    complete,
};

pub const CDCEngine = struct {
    allocator: Allocator,
    config: CDCConfiguration,
    event_queue: std.ArrayList(ChangeEvent),
    subscribers: std.ArrayList(*CDCSubscriber),
    sequence_counter: std.atomic.Value(u64),
    is_running: std.atomic.Value(bool),
    worker_thread: ?std.Thread,

    const Self = @This();

    pub fn init(allocator: Allocator, config: CDCConfiguration) !Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .event_queue = std.ArrayList(ChangeEvent){},
            .subscribers = std.ArrayList(*CDCSubscriber){},
            .sequence_counter = std.atomic.Value(u64).init(0),
            .is_running = std.atomic.Value(bool).init(false),
            .worker_thread = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.event_queue.deinit(self.allocator);
        for (self.subscribers.items) |subscriber| {
            subscriber.deinit();
            self.allocator.destroy(subscriber);
        }
        self.subscribers.deinit(self.allocator);
    }

    pub fn start(self: *Self) !void {
        if (self.is_running.load(.acquire)) {
            return error.AlreadyRunning;
        }

        self.is_running.store(true, .release);
        self.worker_thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        if (!self.is_running.load(.acquire)) {
            return;
        }

        self.is_running.store(false, .release);
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
    }

    /// Capture a change event with automatic transaction ID from current context
    /// GAP-0073: Transaction ID now properly wired from TransactionContext
    pub fn captureChange(
        self: *Self,
        change_type: ChangeType,
        graph_id: u32,
        object_type: anytype,
        object_id: u64,
        before: ?[]const u8,
        after: ?[]const u8,
    ) !void {
        return self.captureChangeWithTxId(change_type, graph_id, object_type, object_id, before, after, getCurrentTransactionId());
    }

    /// Capture a change event with explicit transaction ID
    /// GAP-0073: Allows explicit transaction ID for distributed scenarios
    pub fn captureChangeWithTxId(
        self: *Self,
        change_type: ChangeType,
        graph_id: u32,
        object_type: anytype,
        object_id: u64,
        before: ?[]const u8,
        after: ?[]const u8,
        transaction_id: u64,
    ) !void {
        if (!self.config.enabled) {
            return;
        }

        const seq = self.sequence_counter.fetchAdd(1, .monotonic);
        const event = ChangeEvent{
            .sequence_number = seq,
            .timestamp = std.time.milliTimestamp(),
            .transaction_id = transaction_id, // GAP-0073: Now from transaction context
            .change_type = change_type,
            .graph_id = graph_id,
            .object_type = object_type,
            .object_id = object_id,
            .before = before,
            .after = after,
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };

        try self.event_queue.append(self.allocator, event);

        // Notify subscribers
        for (self.subscribers.items) |subscriber| {
            try subscriber.onEvent(event);
        }
    }

    pub fn subscribe(self: *Self, subscriber: *CDCSubscriber) !void {
        try self.subscribers.append(subscriber);
    }

    pub fn unsubscribe(self: *Self, subscriber: *CDCSubscriber) void {
        for (self.subscribers.items, 0..) |sub, i| {
            if (sub == subscriber) {
                _ = self.subscribers.swapRemove(i);
                break;
            }
        }
    }

    fn workerLoop(self: *Self) !void {
        while (self.is_running.load(.acquire)) {
            // Process events
            self.processEvents() catch |err| {
                log.err("CDC worker error", &.{
                    Attr.err("error", err),
                });
            };

            // Clean up old events
            self.cleanupOldEvents() catch |err| {
                log.err("CDC cleanup error", &.{
                    Attr.err("error", err),
                });
            };

            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn processEvents(self: *Self) !void {
        // Process queued events based on sink type
        switch (self.config.sink_type) {
            .kafka => try self.sendToKafka(),
            .file => try self.writeToFile(),
            .webhook => try self.sendToWebhook(),
            else => {},
        }
    }

    fn cleanupOldEvents(self: *Self) !void {
        const now = std.time.milliTimestamp();
        const cutoff = now - @as(i64, @intCast(self.config.retention_period_ms));

        var i: usize = 0;
        while (i < self.event_queue.items.len) {
            if (self.event_queue.items[i].timestamp < cutoff) {
                _ = self.event_queue.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // CANARY: REQ=REQ-CDC-KAFKA-001; FEATURE="CDC Kafka Sink"; ASPECT=Streaming; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=streaming; UPDATED=2026-01-09
    fn sendToKafka(self: *Self) !void {
        // Kafka sink: serialize events and send to Kafka brokers
        // Note: Full Kafka protocol implementation would require librdkafka
        // This implementation uses a simplified approach with TCP socket to broker
        const kafka_config = self.config.kafka_config orelse return;
        if (self.event_queue.items.len == 0) return;

        // Batch events for efficiency
        const batch_size = @min(self.event_queue.items.len, self.config.batch_size);
        var batch_buffer = std.ArrayList(u8){};
        defer batch_buffer.deinit(self.allocator);

        // Serialize events as JSONL batch
        for (self.event_queue.items[0..batch_size]) |event| {
            try self.serializeEventJson(&batch_buffer, event);
            try batch_buffer.append(self.allocator, '\n');
        }

        // Try to connect to Kafka broker - parse host:port
        var host: []const u8 = "localhost";
        var port: u16 = 9092;
        if (std.mem.indexOf(u8, kafka_config.brokers, ":")) |colon_idx| {
            host = kafka_config.brokers[0..colon_idx];
            port = std.fmt.parseInt(u16, kafka_config.brokers[colon_idx + 1 ..], 10) catch 9092;
        } else {
            host = kafka_config.brokers;
        }

        // Attempt TCP connection to Kafka broker
        const stream = std.net.tcpConnectToHost(self.allocator, host, port) catch |err| {
            log.warn("CDC Kafka: Failed to connect", &.{
                Attr.string("host", host),
                Attr.int("port", port),
                Attr.err("error", err),
            });
            // Log events locally as fallback
            log.info("CDC Kafka: events queued", &.{
                Attr.int("batch_size", @intCast(batch_size)),
                Attr.string("topic", kafka_config.topic),
            });
            return;
        };
        defer stream.close();

        // Send batch (simplified - real implementation needs Kafka protocol)
        _ = stream.write(batch_buffer.items) catch |err| {
            log.warn("CDC Kafka: Write failed", &.{
                Attr.err("error", err),
            });
            return;
        };

        // Remove sent events from queue
        var i: usize = 0;
        while (i < batch_size) : (i += 1) {
            _ = self.event_queue.orderedRemove(0);
        }

        log.info("CDC Kafka: Sent events", &.{
            Attr.int("batch_size", @intCast(batch_size)),
            Attr.string("topic", kafka_config.topic),
        });
    }

    // CANARY: REQ=REQ-CDC-FILE-001; FEATURE="CDC File Sink"; ASPECT=Streaming; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=streaming; UPDATED=2026-01-09
    fn writeToFile(self: *Self) !void {
        // File sink: append events as JSON lines to configured file
        const file_path = self.config.file_path orelse return;
        if (self.event_queue.items.len == 0) return;

        // Open file for appending
        const file = std.fs.cwd().openFile(file_path, .{ .mode = .write_only }) catch |err| {
            if (err == error.FileNotFound) {
                // Create file if it doesn't exist
                const new_file = std.fs.cwd().createFile(file_path, .{}) catch |create_err| {
                    log.warn("CDC File: Failed to create", &.{
                        Attr.string("path", file_path),
                        Attr.err("error", create_err),
                    });
                    return;
                };
                return self.writeEventsToFile(new_file);
            }
            log.warn("CDC File: Failed to open", &.{
                Attr.string("path", file_path),
                Attr.err("error", err),
            });
            return;
        };
        defer file.close();

        // Seek to end for appending
        file.seekFromEnd(0) catch {};
        try self.writeEventsToFile(file);
    }

    fn writeEventsToFile(self: *Self, file: std.fs.File) !void {
        const batch_size = @min(self.event_queue.items.len, self.config.batch_size);
        var events_written: usize = 0;

        for (self.event_queue.items[0..batch_size]) |event| {
            // Write event as JSON line
            var json_buffer = std.ArrayList(u8){};
            defer json_buffer.deinit(self.allocator);

            try self.serializeEventJson(&json_buffer, event);

            // Write directly using file.write
            _ = file.write(json_buffer.items) catch |err| {
                log.warn("CDC File: Write error", &.{
                    Attr.err("error", err),
                });
                break;
            };
            _ = file.write("\n") catch {};
            events_written += 1;
        }

        // Remove written events from queue
        var i: usize = 0;
        while (i < events_written) : (i += 1) {
            _ = self.event_queue.orderedRemove(0);
        }

        log.debug("CDC File: Wrote events", &.{
            Attr.int("events_written", @intCast(events_written)),
        });
    }

    // CANARY: REQ=REQ-CDC-WEBHOOK-001; FEATURE="CDC Webhook Sink"; ASPECT=Streaming; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=streaming; UPDATED=2026-01-09
    fn sendToWebhook(self: *Self) !void {
        // Webhook sink: POST events as JSON to configured URL
        const webhook_url = self.config.webhook_url orelse return;
        if (self.event_queue.items.len == 0) return;

        // Batch events for single POST
        const batch_size = @min(self.event_queue.items.len, self.config.batch_size);
        var json_buffer = std.ArrayList(u8){};
        defer json_buffer.deinit(self.allocator);

        // Build JSON array of events
        try json_buffer.appendSlice(self.allocator, "{\"events\":[");
        for (self.event_queue.items[0..batch_size], 0..) |event, idx| {
            if (idx > 0) try json_buffer.append(self.allocator, ',');
            try self.serializeEventJson(&json_buffer, event);
        }
        try json_buffer.appendSlice(self.allocator, "]}");

        // Parse webhook URL
        const uri = std.Uri.parse(webhook_url) catch |err| {
            log.warn("CDC Webhook: Invalid URL", &.{
                Attr.string("url", webhook_url),
                Attr.err("error", err),
            });
            return;
        };

        // Make HTTP request using TCP socket
        const host_component = uri.host orelse {
            log.warn("CDC Webhook: URL missing host", &.{});
            return;
        };
        // Extract host string from Component union
        const host: []const u8 = switch (host_component) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };
        const scheme = uri.scheme;
        const port: u16 = uri.port orelse if (std.mem.eql(u8, scheme, "https")) @as(u16, 443) else @as(u16, 80);

        const stream = std.net.tcpConnectToHost(self.allocator, host, port) catch |err| {
            log.warn("CDC Webhook: Connection failed", &.{
                Attr.string("host", host),
                Attr.int("port", port),
                Attr.err("error", err),
            });
            return;
        };
        defer stream.close();

        // Build HTTP request
        var request_buf: [8192]u8 = undefined;
        // Extract path string from component
        const path_raw: []const u8 = switch (uri.path) {
            .raw => |p| p,
            .percent_encoded => |p| p,
        };
        const path = if (path_raw.len > 0) path_raw else "/";
        // Build auth header if present
        var auth_header: []const u8 = "";
        var auth_buf: [512]u8 = undefined;
        if (self.config.webhook_auth_header) |auth| {
            auth_header = std.fmt.bufPrint(&auth_buf, "Authorization: {s}\r\n", .{auth}) catch "";
        }

        const request = std.fmt.bufPrint(
            &request_buf,
            "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n{s}\r\n",
            .{ path, host, json_buffer.items.len, auth_header },
        ) catch {
            log.warn("CDC Webhook: Request buffer overflow", &.{});
            return;
        };

        // Send request headers
        _ = stream.write(request) catch |err| {
            log.warn("CDC Webhook: Header write failed", &.{
                Attr.err("error", err),
            });
            return;
        };

        // Send body
        _ = stream.write(json_buffer.items) catch |err| {
            log.warn("CDC Webhook: Body write failed", &.{
                Attr.err("error", err),
            });
            return;
        };

        // Read response status (first line)
        var response_buf: [256]u8 = undefined;
        const response_len = stream.read(&response_buf) catch 0;
        if (response_len > 0) {
            const response = response_buf[0..response_len];
            // Check for HTTP 2xx status
            if (std.mem.startsWith(u8, response, "HTTP/1.1 2") or std.mem.startsWith(u8, response, "HTTP/1.0 2")) {
                // Remove sent events from queue
                var i: usize = 0;
                while (i < batch_size) : (i += 1) {
                    _ = self.event_queue.orderedRemove(0);
                }
                log.info("CDC Webhook: Sent events", &.{
                    Attr.int("batch_size", @intCast(batch_size)),
                    Attr.string("url", webhook_url),
                });
            } else {
                log.warn("CDC Webhook: Server returned non-2xx status", &.{});
            }
        }
    }

    // Helper: serialize a ChangeEvent to JSON
    fn serializeEventJson(self: *Self, buffer: *std.ArrayList(u8), event: ChangeEvent) !void {
        var writer = buffer.writer(self.allocator);

        try writer.writeAll("{");
        try writer.print("\"sequence_number\":{d},", .{event.sequence_number});
        try writer.print("\"timestamp\":{d},", .{event.timestamp});
        try writer.print("\"transaction_id\":{d},", .{event.transaction_id});
        try writer.print("\"change_type\":\"{s}\",", .{@tagName(event.change_type)});
        try writer.print("\"graph_id\":{d},", .{event.graph_id});
        try writer.print("\"object_type\":\"{s}\",", .{@tagName(event.object_type)});
        try writer.print("\"object_id\":{d}", .{event.object_id});

        if (event.before) |before| {
            try writer.writeAll(",\"before\":");
            try writer.writeAll(before);
        }
        if (event.after) |after| {
            try writer.writeAll(",\"after\":");
            try writer.writeAll(after);
        }
        try writer.writeAll("}");
    }
};

pub const CDCSubscriber = struct {
    allocator: Allocator,
    filter: ?*const fn (event: ChangeEvent) bool,
    handler: *const fn (event: ChangeEvent) anyerror!void,

    const Self = @This();

    pub fn init(
        allocator: Allocator,
        handler: *const fn (event: ChangeEvent) anyerror!void,
    ) !*Self {
        const subscriber = try allocator.create(Self);
        subscriber.* = Self{
            .allocator = allocator,
            .filter = null,
            .handler = handler,
        };
        return subscriber;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn onEvent(self: *Self, event: ChangeEvent) !void {
        if (self.filter) |filter| {
            if (!filter(event)) {
                return;
            }
        }
        try self.handler(event);
    }
};

pub const StreamingEngine = struct {
    allocator: Allocator,
    queries: std.StringHashMap(*StreamingQuery),
    is_running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .queries = std.StringHashMap(*StreamingQuery).init(allocator),
            .is_running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.queries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.queries.deinit();
    }

    pub fn registerQuery(self: *Self, name: []const u8, query: StreamQuery) !void {
        const streaming_query = try self.allocator.create(StreamingQuery);
        streaming_query.* = try StreamingQuery.init(self.allocator, query);
        try self.queries.put(name, streaming_query);
    }

    pub fn start(self: *Self) !void {
        self.is_running.store(true, .release);

        var it = self.queries.iterator();
        while (it.next()) |entry| {
            try entry.value_ptr.*.start();
        }
    }

    pub fn stop(self: *Self) void {
        self.is_running.store(false, .release);

        var it = self.queries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.stop();
        }
    }
};

pub const StreamingQuery = struct {
    allocator: Allocator,
    query: StreamQuery,
    window_state: WindowState,
    output_buffer: std.ArrayList([]const u8),
    is_running: bool,

    const Self = @This();

    pub fn init(allocator: Allocator, query: StreamQuery) !Self {
        return Self{
            .allocator = allocator,
            .query = query,
            .window_state = WindowState.init(allocator),
            .output_buffer = std.ArrayList([]const u8){},
            .is_running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.window_state.deinit();
        self.output_buffer.deinit(self.allocator);
    }

    pub fn start(self: *Self) !void {
        self.is_running = true;
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
    }

    pub fn processEvent(self: *Self, event: ChangeEvent) !void {
        _ = event;
        // Process event through window
        try self.window_state.addEvent();

        // Check if window should trigger
        if (self.window_state.shouldTrigger()) {
            try self.computeAndEmit();
        }
    }

    fn computeAndEmit(self: *Self) !void {
        // Compute aggregations
        // Emit results based on output mode
        _ = self;
    }
};

pub const WindowState = struct {
    allocator: Allocator,
    events: std.ArrayList(ChangeEvent),
    start_time: i64,
    end_time: i64,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .events = std.ArrayList(ChangeEvent){},
            .start_time = 0,
            .end_time = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.events.deinit(self.allocator);
    }

    pub fn addEvent(self: *Self) !void {
        _ = self;
    }

    pub fn shouldTrigger(self: *Self) bool {
        _ = self;
        return false;
    }
};

// Database procedures
pub const CDCProcedures = struct {
    engine: *CDCEngine,

    const Self = @This();

    pub fn init(engine: *CDCEngine) Self {
        return Self{ .engine = engine };
    }

    // CALL db.cdc.start()
    pub fn start(self: *Self) !void {
        try self.engine.start();
    }

    // CALL db.cdc.stop()
    pub fn stop(self: *Self) void {
        self.engine.stop();
    }

    // CALL db.cdc.status()
    pub fn status(self: *Self) CDCStatus {
        return CDCStatus{
            .is_running = self.engine.is_running.load(.acquire),
            .events_captured = self.engine.event_queue.items.len,
            .subscribers = self.engine.subscribers.items.len,
        };
    }

    // CALL db.cdc.subscribe(filter)
    pub fn subscribe(self: *Self, filter: ?[]const u8) !void {
        _ = filter;
        // Create and register subscriber
        const subscriber = try CDCSubscriber.init(
            self.engine.allocator,
            defaultEventHandler,
        );
        try self.engine.subscribe(subscriber);
    }
};

pub const CDCStatus = struct {
    is_running: bool,
    events_captured: usize,
    subscribers: usize,
};

fn defaultEventHandler(event: ChangeEvent) anyerror!void {
    log.info("CDC Event", &.{
        Attr.string("change_type", @tagName(event.change_type)),
        Attr.string("object_type", @tagName(event.object_type)),
        Attr.int("object_id", @intCast(event.object_id)),
    });
}

test "CDC engine basic operations" {
    const allocator = std.testing.allocator;

    var engine = try CDCEngine.init(allocator, .{ .enabled = true });
    defer engine.deinit();

    try engine.start();
    defer engine.stop();

    // Capture a change
    try engine.captureChange(
        .insert,
        1,
        .node,
        100,
        null,
        "{ \"id\": 100, \"label\": \"Person\" }",
    );

    try std.testing.expect(engine.event_queue.items.len == 1);
}

test "streaming query registration" {
    const allocator = std.testing.allocator;

    var engine = try StreamingEngine.init(allocator);
    defer engine.deinit();

    const query = StreamQuery{
        .query = "MATCH (n) WHERE n.timestamp > $window_start RETURN count(n)",
        .window_type = .tumbling,
        .window_size = 60000, // 1 minute
        .aggregations = &[_]Aggregation{.count},
        .output_mode = .append,
    };

    try engine.registerQuery("node_count", query);
    try std.testing.expect(engine.queries.count() == 1);
}
