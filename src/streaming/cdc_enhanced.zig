const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ChangeType = enum {
    insert,
    update,
    delete,
};

pub const ChangeEvent = struct {
    timestamp: i64,
    transaction_id: u64,
    change_type: ChangeType,
    entity_type: EntityType,
    entity_id: u64,
    before: ?[]const u8, // JSON representation
    after: ?[]const u8, // JSON representation
    metadata: std.StringHashMap([]const u8),
};

pub const EntityType = enum {
    node,
    edge,
    property,
    label,
};

pub const CDCSink = enum {
    memory,
    file,
    kafka,
    kinesis,
    pubsub,
    webhook,
};

pub const CDCConfig = struct {
    enabled: bool = false,
    sinks: []CDCSink = &[_]CDCSink{},
    retention_period_ms: i64 = 7 * 24 * 60 * 60 * 1000, // 7 days
    batch_size: u32 = 1000,
    flush_interval_ms: u32 = 1000,
    filter_patterns: ?[]const u8 = null,
    include_before_image: bool = true,
    include_metadata: bool = true,
};

pub const KafkaConfig = struct {
    brokers: []const u8,
    topic: []const u8,
    compression: enum { none, gzip, snappy, lz4, zstd } = .snappy,
    batch_size: u32 = 16384,
    linger_ms: u32 = 100,
    acks: enum { none, leader, all } = .all,
};

pub const KinesisConfig = struct {
    stream_name: []const u8,
    region: []const u8,
    partition_key: []const u8,
    endpoint: ?[]const u8 = null,
};

pub const WebhookConfig = struct {
    url: []const u8,
    method: enum { POST, PUT } = .POST,
    headers: std.StringHashMap([]const u8),
    retry_count: u32 = 3,
    timeout_ms: u32 = 5000,
};

pub const WindowType = enum {
    tumbling,
    sliding,
    session,
};

pub const WindowConfig = struct {
    window_type: WindowType,
    size_ms: i64,
    slide_ms: ?i64 = null, // For sliding windows
    gap_ms: ?i64 = null, // For session windows
    late_arrival_ms: i64 = 0,
    watermark_ms: i64 = 0,
};

pub const AggregationType = enum {
    count,
    sum,
    avg,
    min,
    max,
    first,
    last,
    collect,
};

pub const StreamingQuery = struct {
    id: []const u8,
    name: []const u8,
    query: []const u8,
    window: WindowConfig,
    aggregations: []AggregationSpec,
    output_mode: enum { append, update, complete } = .append,
    trigger: TriggerConfig,
    state: QueryState,
};

pub const AggregationSpec = struct {
    field: []const u8,
    function: AggregationType,
    alias: ?[]const u8 = null,
};

pub const TriggerConfig = struct {
    mode: enum { processing_time, event_time, continuous } = .processing_time,
    interval_ms: ?i64 = null,
    max_delay_ms: ?i64 = null,
};

pub const QueryState = enum {
    created,
    running,
    paused,
    stopped,
    failed,
};

pub const CDCEngine = struct {
    allocator: Allocator,
    config: CDCConfig,
    event_buffer: std.ArrayList(ChangeEvent),
    sinks: std.ArrayList(Sink),
    last_flush: i64,
    total_events: u64,
    is_running: bool,
    thread: ?std.Thread,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, config: CDCConfig) !Self {
        var engine = Self{
            .allocator = allocator,
            .config = config,
            .event_buffer = std.ArrayList(ChangeEvent).init(allocator),
            .sinks = std.ArrayList(Sink).init(allocator),
            .last_flush = std.time.milliTimestamp(),
            .total_events = 0,
            .is_running = false,
            .thread = null,
            .mutex = .{},
        };
        
        // Initialize sinks
        for (config.sinks) |sink_type| {
            const sink = try Sink.init(allocator, sink_type);
            try engine.sinks.append(sink);
        }
        
        return engine;
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        
        for (self.sinks.items) |*sink| {
            sink.deinit();
        }
        self.sinks.deinit();
        
        for (self.event_buffer.items) |*event| {
            event.metadata.deinit();
            if (event.before) |before| self.allocator.free(before);
            if (event.after) |after| self.allocator.free(after);
        }
        self.event_buffer.deinit();
    }
    
    pub fn start(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.is_running) {
            return error.AlreadyRunning;
        }
        
        self.is_running = true;
        self.thread = try std.Thread.spawn(.{}, processingLoop, .{self});
    }
    
    pub fn stop(self: *Self) void {
        self.mutex.lock();
        self.is_running = false;
        self.mutex.unlock();
        
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
    
    pub fn captureChange(
        self: *Self,
        change_type: ChangeType,
        entity_type: EntityType,
        entity_id: u64,
        before: ?[]const u8,
        after: ?[]const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (!self.config.enabled) {
            return;
        }
        
        var metadata = std.StringHashMap([]const u8).init(self.allocator);
        try metadata.put("capture_time", try std.fmt.allocPrint(self.allocator, "{}", .{std.time.milliTimestamp()}));
        
        const event = ChangeEvent{
            .timestamp = std.time.milliTimestamp(),
            .transaction_id = 0, // TODO: Get from transaction manager
            .change_type = change_type,
            .entity_type = entity_type,
            .entity_id = entity_id,
            .before = if (before) |b| try self.allocator.dupe(u8, b) else null,
            .after = if (after) |a| try self.allocator.dupe(u8, a) else null,
            .metadata = metadata,
        };
        
        try self.event_buffer.append(event);
        self.total_events += 1;
        
        // Check if we should flush
        if (self.event_buffer.items.len >= self.config.batch_size) {
            try self.flush();
        }
    }
    
    fn processingLoop(self: *Self) void {
        while (self.is_running) {
            std.time.sleep(self.config.flush_interval_ms * 1_000_000);
            
            self.mutex.lock();
            defer self.mutex.unlock();
            
            const now = std.time.milliTimestamp();
            if (now - self.last_flush >= self.config.flush_interval_ms) {
                self.flush() catch |err| {
                    std.log.err("CDC flush failed: {}", .{err});
                };
            }
            
            // Clean up old events
            self.cleanupOldEvents() catch |err| {
                std.log.err("CDC cleanup failed: {}", .{err});
            };
        }
    }
    
    fn flush(self: *Self) !void {
        if (self.event_buffer.items.len == 0) {
            return;
        }
        
        // Send to all sinks
        for (self.sinks.items) |*sink| {
            try sink.send(self.event_buffer.items);
        }
        
        // Clear buffer
        for (self.event_buffer.items) |*event| {
            event.metadata.deinit();
            if (event.before) |before| self.allocator.free(before);
            if (event.after) |after| self.allocator.free(after);
        }
        self.event_buffer.clearRetainingCapacity();
        
        self.last_flush = std.time.milliTimestamp();
    }
    
    fn cleanupOldEvents(self: *Self) !void {
        const cutoff = std.time.milliTimestamp() - self.config.retention_period_ms;
        
        var i: usize = 0;
        while (i < self.event_buffer.items.len) {
            if (self.event_buffer.items[i].timestamp < cutoff) {
                const event = self.event_buffer.orderedRemove(i);
                event.metadata.deinit();
                if (event.before) |before| self.allocator.free(before);
                if (event.after) |after| self.allocator.free(after);
            } else {
                i += 1;
            }
        }
    }
    
    pub fn getStatus(self: *Self) CDCStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return CDCStatus{
            .is_running = self.is_running,
            .total_events = self.total_events,
            .buffer_size = self.event_buffer.items.len,
            .last_flush = self.last_flush,
            .sinks_count = self.sinks.items.len,
        };
    }
};

pub const CDCStatus = struct {
    is_running: bool,
    total_events: u64,
    buffer_size: usize,
    last_flush: i64,
    sinks_count: usize,
};

const Sink = struct {
    allocator: Allocator,
    sink_type: CDCSink,
    impl: SinkImpl,
    
    const SinkImpl = union(enum) {
        memory: MemorySink,
        file: FileSink,
        kafka: KafkaSink,
        kinesis: KinesisSink,
        webhook: WebhookSink,
        pubsub: PubSubSink,
    };
    
    pub fn init(allocator: Allocator, sink_type: CDCSink) !Sink {
        const impl = switch (sink_type) {
            .memory => SinkImpl{ .memory = MemorySink.init(allocator) },
            .file => SinkImpl{ .file = try FileSink.init(allocator, "cdc.log") },
            .kafka => SinkImpl{ .kafka = KafkaSink.init(allocator) },
            .kinesis => SinkImpl{ .kinesis = KinesisSink.init(allocator) },
            .webhook => SinkImpl{ .webhook = WebhookSink.init(allocator) },
            .pubsub => SinkImpl{ .pubsub = PubSubSink.init(allocator) },
        };
        
        return Sink{
            .allocator = allocator,
            .sink_type = sink_type,
            .impl = impl,
        };
    }
    
    pub fn deinit(self: *Sink) void {
        switch (self.impl) {
            .memory => |*s| s.deinit(),
            .file => |*s| s.deinit(),
            .kafka => |*s| s.deinit(),
            .kinesis => |*s| s.deinit(),
            .webhook => |*s| s.deinit(),
            .pubsub => |*s| s.deinit(),
        }
    }
    
    pub fn send(self: *Sink, events: []const ChangeEvent) !void {
        switch (self.impl) {
            .memory => |*s| try s.send(events),
            .file => |*s| try s.send(events),
            .kafka => |*s| try s.send(events),
            .kinesis => |*s| try s.send(events),
            .webhook => |*s| try s.send(events),
            .pubsub => |*s| try s.send(events),
        }
    }
};

const MemorySink = struct {
    allocator: Allocator,
    events: std.ArrayList(ChangeEvent),
    
    pub fn init(allocator: Allocator) MemorySink {
        return MemorySink{
            .allocator = allocator,
            .events = std.ArrayList(ChangeEvent).init(allocator),
        };
    }
    
    pub fn deinit(self: *MemorySink) void {
        self.events.deinit();
    }
    
    pub fn send(self: *MemorySink, events: []const ChangeEvent) !void {
        for (events) |event| {
            try self.events.append(event);
        }
    }
};

const FileSink = struct {
    allocator: Allocator,
    file: std.fs.File,
    
    pub fn init(allocator: Allocator, path: []const u8) !FileSink {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
        return FileSink{
            .allocator = allocator,
            .file = file,
        };
    }
    
    pub fn deinit(self: *FileSink) void {
        self.file.close();
    }
    
    pub fn send(self: *FileSink, events: []const ChangeEvent) !void {
        for (events) |event| {
            const json = try serializeEvent(self.allocator, event);
            defer self.allocator.free(json);
            
            try self.file.writer().print("{s}\n", .{json});
        }
    }
};

const KafkaSink = struct {
    allocator: Allocator,
    // Kafka producer would be initialized here
    
    pub fn init(allocator: Allocator) KafkaSink {
        return KafkaSink{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *KafkaSink) void {
        _ = self;
    }
    
    pub fn send(self: *KafkaSink, events: []const ChangeEvent) !void {
        _ = self;
        _ = events;
        // Send to Kafka
    }
};

const KinesisSink = struct {
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) KinesisSink {
        return KinesisSink{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *KinesisSink) void {
        _ = self;
    }
    
    pub fn send(self: *KinesisSink, events: []const ChangeEvent) !void {
        _ = self;
        _ = events;
        // Send to Kinesis
    }
};

const WebhookSink = struct {
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) WebhookSink {
        return WebhookSink{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *WebhookSink) void {
        _ = self;
    }
    
    pub fn send(self: *WebhookSink, events: []const ChangeEvent) !void {
        _ = self;
        _ = events;
        // Send via HTTP webhook
    }
};

const PubSubSink = struct {
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) PubSubSink {
        return PubSubSink{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *PubSubSink) void {
        _ = self;
    }
    
    pub fn send(self: *PubSubSink, events: []const ChangeEvent) !void {
        _ = self;
        _ = events;
        // Send to Pub/Sub
    }
};

// Streaming query engine
pub const StreamingEngine = struct {
    allocator: Allocator,
    queries: std.StringHashMap(StreamingQuery),
    windows: std.StringHashMap(Window),
    cdc_engine: *CDCEngine,
    is_running: bool,
    thread: ?std.Thread,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, cdc_engine: *CDCEngine) Self {
        return Self{
            .allocator = allocator,
            .queries = std.StringHashMap(StreamingQuery).init(allocator),
            .windows = std.StringHashMap(Window).init(allocator),
            .cdc_engine = cdc_engine,
            .is_running = false,
            .thread = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stop();
        self.queries.deinit();
        self.windows.deinit();
    }
    
    pub fn createQuery(
        self: *Self,
        name: []const u8,
        query: []const u8,
        window: WindowConfig,
        aggregations: []const AggregationSpec,
    ) !void {
        const id = try std.fmt.allocPrint(self.allocator, "query_{}", .{std.time.milliTimestamp()});
        
        const streaming_query = StreamingQuery{
            .id = id,
            .name = try self.allocator.dupe(u8, name),
            .query = try self.allocator.dupe(u8, query),
            .window = window,
            .aggregations = try self.allocator.dupe(AggregationSpec, aggregations),
            .output_mode = .append,
            .trigger = TriggerConfig{},
            .state = .created,
        };
        
        try self.queries.put(streaming_query.name, streaming_query);
        
        // Create window
        const window_impl = try Window.init(self.allocator, window);
        try self.windows.put(streaming_query.name, window_impl);
    }
    
    pub fn start(self: *Self) !void {
        if (self.is_running) {
            return error.AlreadyRunning;
        }
        
        self.is_running = true;
        self.thread = try std.Thread.spawn(.{}, streamProcessingLoop, .{self});
        
        // Update query states
        var it = self.queries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.state = .running;
        }
    }
    
    pub fn stop(self: *Self) void {
        self.is_running = false;
        
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        
        // Update query states
        var it = self.queries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.state = .stopped;
        }
    }
    
    fn streamProcessingLoop(self: *Self) void {
        while (self.is_running) {
            // Process events from CDC
            self.processEvents() catch |err| {
                std.log.err("Stream processing error: {}", .{err});
            };
            
            std.time.sleep(100_000_000); // 100ms
        }
    }
    
    fn processEvents(self: *Self) !void {
        // Get events from CDC engine
        const status = self.cdc_engine.getStatus();
        if (status.buffer_size == 0) {
            return;
        }
        
        // Process each query
        var query_it = self.queries.iterator();
        while (query_it.next()) |query_entry| {
            const query = query_entry.value_ptr;
            if (query.state != .running) continue;
            
            const window = self.windows.get(query.name).?;
            
            // Process events through window
            // This is simplified - real implementation would parse query and apply filters
            try self.processQueryWindow(query, &window);
        }
    }
    
    fn processQueryWindow(self: *Self, query: *StreamingQuery, window: *Window) !void {
        _ = self;
        _ = query;
        _ = window;
        // Process events through window and apply aggregations
    }
};

const Window = struct {
    allocator: Allocator,
    config: WindowConfig,
    buckets: std.ArrayList(WindowBucket),
    watermark: i64,
    
    pub fn init(allocator: Allocator, config: WindowConfig) !Window {
        return Window{
            .allocator = allocator,
            .config = config,
            .buckets = std.ArrayList(WindowBucket).init(allocator),
            .watermark = 0,
        };
    }
    
    pub fn deinit(self: *Window) void {
        for (self.buckets.items) |*bucket| {
            bucket.deinit();
        }
        self.buckets.deinit();
    }
};

const WindowBucket = struct {
    start_time: i64,
    end_time: i64,
    events: std.ArrayList(ChangeEvent),
    aggregates: std.StringHashMap(f64),
    
    pub fn deinit(self: *WindowBucket) void {
        self.events.deinit();
        self.aggregates.deinit();
    }
};

fn serializeEvent(allocator: Allocator, event: ChangeEvent) ![]const u8 {
    return std.fmt.allocPrint(allocator, 
        \\{{
        \\  "timestamp": {},
        \\  "transaction_id": {},
        \\  "change_type": "{}",
        \\  "entity_type": "{}",
        \\  "entity_id": {},
        \\  "before": {},
        \\  "after": {}
        \\}}
    , .{
        event.timestamp,
        event.transaction_id,
        @tagName(event.change_type),
        @tagName(event.entity_type),
        event.entity_id,
        if (event.before) |b| b else "null",
        if (event.after) |a| a else "null",
    });
}

// System procedures for CDC control
pub fn startCDC(allocator: Allocator, config: CDCConfig) !*CDCEngine {
    const engine = try allocator.create(CDCEngine);
    engine.* = try CDCEngine.init(allocator, config);
    try engine.start();
    return engine;
}

pub fn stopCDC(engine: *CDCEngine) void {
    engine.stop();
}

pub fn getCDCStatus(engine: *CDCEngine) CDCStatus {
    return engine.getStatus();
}

test "CDC basic operations" {
    const allocator = std.testing.allocator;
    
    const config = CDCConfig{
        .enabled = true,
        .sinks = &[_]CDCSink{.memory},
        .batch_size = 10,
        .flush_interval_ms = 100,
    };
    
    var engine = try CDCEngine.init(allocator, config);
    defer engine.deinit();
    
    try engine.start();
    defer engine.stop();
    
    // Capture some changes
    try engine.captureChange(.insert, .node, 1, null, "{\"id\": 1}");
    try engine.captureChange(.update, .node, 1, "{\"id\": 1}", "{\"id\": 1, \"name\": \"test\"}");
    try engine.captureChange(.delete, .node, 1, "{\"id\": 1, \"name\": \"test\"}", null);
    
    const status = engine.getStatus();
    try std.testing.expect(status.is_running);
    try std.testing.expect(status.total_events == 3);
}

test "Streaming query creation" {
    const allocator = std.testing.allocator;
    
    const cdc_config = CDCConfig{
        .enabled = true,
        .sinks = &[_]CDCSink{.memory},
    };
    
    var cdc_engine = try CDCEngine.init(allocator, cdc_config);
    defer cdc_engine.deinit();
    
    var streaming = StreamingEngine.init(allocator, &cdc_engine);
    defer streaming.deinit();
    
    const window = WindowConfig{
        .window_type = .tumbling,
        .size_ms = 60000, // 1 minute
    };
    
    const aggregations = [_]AggregationSpec{
        .{ .field = "count", .function = .count },
        .{ .field = "sum", .function = .sum },
    };
    
    try streaming.createQuery("test_query", "MATCH (n) RETURN n", window, &aggregations);
    
    try std.testing.expect(streaming.queries.count() == 1);
}