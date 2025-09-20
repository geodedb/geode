const std = @import("std");
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=API; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_API; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Lifecycle"; ASPECT=API; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_StartStopLifecycle; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=Retention; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_Retention; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=Ingest; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_Ingest; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTail; STATUS=BENCHED; TEST=TestCANARY_REQ_GQL_042_CDC_WalTailPromote; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_WalTailPerf; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailDisabled; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_WalTailDisabled; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformed; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_WalTailMalformed; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=Ordering; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_Ordering; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=OrderingConcurrency; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_OrderingConcurrency; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=OrderingPerf; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_OrderingPerf; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=MixedWorkload; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_MixedWorkload; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=AdaptiveFlush; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveFlush; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=AdaptiveBaselinePerf; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveBaselinePerf; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=Telemetry; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_Telemetry; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=AdaptiveDiffPerf; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_042_CDC_AdaptiveDiffPerf; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=EventCapture; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_EventCapture; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedDiagnostics; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_WalTailMalformed; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedLog; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_WalTailMalformed; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedLogBuffer; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_WalTailMalformedLogBuffer; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=DiagnosticsExport; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_DiagnosticsExport; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=ResumeTokenRestart; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_ResumeTokenRestart; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedSnapshotInterval; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_MalformedSnapshotIntervalEnv; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedPayloadHash; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_MalformedPayloadHash; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedGuardrailWarn; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_MalformedGuardrailEnv; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedGuardrailAbort; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_MalformedGuardrailEnv; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedGuardrailWarnEnv; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_MalformedGuardrailEnv; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedGuardrailAbortEnv; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_MalformedGuardrailEnv; OWNER=streaming; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=WALTailMalformedSnapshotIntervalEnv; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_042_CDC_MalformedSnapshotIntervalEnv; OWNER=streaming; UPDATED=2025-09-20
const Allocator = std.mem.Allocator;

fn writeInt(w: anytype, value: u64) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try w.writeAll(s);
}

fn writeFloat(w: anytype, value: f64) !void {
    var buf: [64]u8 = undefined;
    if (@floor(value) == value and value < 9.22e18 and value >= 0) {
        return writeInt(w, @intFromFloat(value));
    }
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try w.writeAll(s);
}

fn writeIntSigned(w: anytype, value: i64) !void {
    if (value < 0) {
        try w.writeAll("-");
        const pos: u64 = @intCast(-value);
        return writeInt(w, pos);
    }
    return writeInt(w, @as(u64, @intCast(value)));
}

pub const ChangeType = enum {
    insert,
    update,
    delete,
};

pub const ChangeEvent = struct {
    timestamp: i64,
    transaction_id: u64, // 0 when not attributed to a transaction
    sequence: u64, // global monotonic sequence
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
    adaptive_flush: bool = false,
    min_batch_size: u32 = 256,
    max_batch_size: u32 = 32_000,
    adapt_window_events: u32 = 4_000, // after this many events re-evaluate rate
    filter_patterns: ?[]const u8 = null,
    include_before_image: bool = true,
    include_metadata: bool = true,
    // Malformed WAL diagnostics tuning
    malformed_snapshot_interval: u64 = 100, // capture snapshot every N malformed (plus first)
    malformed_hash_retain: u32 = 8, // retain hashes/prefixes for first N malformed payloads
    malformed_warn_pct: f64 = 0.05, // warn guardrail threshold (malformed/attempts)
    malformed_abort_pct: f64 = 0.50, // abort guardrail threshold
    // Backpressure watermark: when pending buffered events exceeds this, set backpressure flag (0 disables)
    pending_backpressure_watermark: u64 = 0,
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
    diag_events: std.ArrayList(DiagEvent), // lifecycle diagnostics (START/STOP)
    current_txn_id: u64 = 0, // CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=TxnAttribution; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_API; OWNER=streaming; UPDATED=2025-09-20
    next_sequence: u64 = 1,
    adapt_events_accum: u32 = 0,
    dynamic_batch_size: u32 = 0,
    peak_buffer: usize = 0,
    batch_adjustments: u32 = 0,
    malformed_wal_records: u64 = 0,
    malformed_ring: MalformedRing = .{},
    total_wal_attempts: u64 = 0,
    guardrail_warn_triggered: bool = false,
    guardrail_abort_triggered: bool = false,
    first_warn_ts_ms: i64 = 0, // CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=GuardrailTimestamps; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_GuardrailTimestamps; OWNER=streaming; UPDATED=2025-09-20
    first_abort_ts_ms: i64 = 0, // CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=GuardrailTimestampsAbort; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_GuardrailTimestamps; OWNER=streaming; UPDATED=2025-09-20
    malformed_hashes: MalformedHashStore = .{},
    guardrail_epoch: u64 = 0, // CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=GuardrailEpoch; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_GuardrailEpoch; OWNER=streaming; UPDATED=2025-09-20
    start_time_ms: i64 = 0, // engine start timestamp for uptime computations

    const Self = @This();

    pub const DiagEvent = enum { start, stop };

    pub const MalformedRing = struct {
        const CAP = 32;
        counts: [CAP]u64 = [_]u64{0} ** CAP,
        times: [CAP]i64 = [_]i64{0} ** CAP,
        next: usize = 0,
        filled: bool = false,

        pub fn record(self: *MalformedRing, count: u64) void {
            self.counts[self.next] = count;
            self.times[self.next] = std.time.milliTimestamp();
            self.next = (self.next + 1) % CAP;
            if (self.next == 0) self.filled = true;
        }

        pub fn writeJson(self: *MalformedRing, w: anytype) !void {
            try w.writeAll("[");
            var first = true;
            const total = if (self.filled) CAP else self.next;
            var idx: usize = 0;
            while (idx < total) : (idx += 1) {
                const logical = if (self.filled) (self.next + idx) % CAP else idx;
                if (!first) {
                    try w.writeAll(",");
                } else {
                    first = false;
                }
                try w.writeAll("{\"count\":");
                try writeInt(w, self.counts[logical]);
                try w.writeAll(",\"ts_ms\":");
                try writeIntSigned(w, self.times[logical]);
                try w.writeAll("}");
            }
            try w.writeAll("]");
        }
    };

    const MalformedHashEntry = struct {
        count: u64,
        hash: u64,
        ts_ms: i64,
        prefix_len: u8,
        prefix: [16]u8,
    };

    pub const MalformedHashStore = struct {
        const CAP = 64; // upper bound; actual retention limited by config.malformed_hash_retain
        entries: [CAP]MalformedHashEntry = undefined,
        used: u32 = 0,

        fn record(self: *MalformedHashStore, cfg_limit: u32, count: u64, payload: []const u8) void {
            if (self.used >= cfg_limit or cfg_limit == 0) return;
            const idx = self.used;
            const ts = std.time.milliTimestamp();
            var prefix_buf: [16]u8 = .{0} ** 16;
            const take = @min(payload.len, prefix_buf.len);
            if (take > 0) std.mem.copy(u8, prefix_buf[0..take], payload[0..take]);
            self.entries[idx] = .{ .count = count, .hash = fnv1a64(payload), .ts_ms = ts, .prefix_len = @intCast(take), .prefix = prefix_buf };
            self.used += 1;
        }

        fn writeJson(self: *MalformedHashStore, w: anytype, cfg_limit: u32) !void {
            try w.writeAll("[");
            var i: u32 = 0;
            while (i < self.used and i < cfg_limit) : (i += 1) {
                if (i > 0) try w.writeAll(",");
                const e = self.entries[i];
                try w.writeAll("{\"count\":");
                try writeInt(w, e.count);
                try w.writeAll(",\"hash\":");
                try writeInt(w, e.hash);
                try w.writeAll(",\"ts_ms\":");
                try writeInt(w, @as(u64, @bitCast(e.ts_ms)));
                try w.writeAll(",\"prefix\":\"");
                const p = e.prefix[0..e.prefix_len];
                // hex encode prefix bytes
                var j: usize = 0;
                while (j < p.len) : (j += 1) try std.fmt.format(w, "{x:0>2}", .{p[j]});
                try w.writeAll("\"}");
            }
            try w.writeAll("]");
        }
    };

    fn fnv1a64(data: []const u8) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (data) |b| h = (h ^ @as(u64, b)) * 0x100000001b3;
        return h;
    }

    pub fn init(allocator: Allocator, config: CDCConfig) !Self {
        var engine = Self{
            .allocator = allocator,
            .config = config,
            .event_buffer = std.ArrayList(ChangeEvent).initCapacity(allocator, 0) catch @panic("OOM"),
            .sinks = std.ArrayList(Sink).initCapacity(allocator, 0) catch @panic("OOM"),
            .last_flush = std.time.milliTimestamp(),
            .total_events = 0,
            .is_running = false,
            .thread = null,
            .mutex = .{},
            .diag_events = std.ArrayList(DiagEvent).initCapacity(allocator, 0) catch @panic("OOM"),
            .adapt_events_accum = 0,
            .dynamic_batch_size = if (config.adaptive_flush) config.batch_size else 0,
            .peak_buffer = 0,
            .batch_adjustments = 0,
            .total_wal_attempts = 0,
            .guardrail_warn_triggered = false,
            .guardrail_abort_triggered = false,
            .guardrail_epoch = 0,
            .start_time_ms = std.time.milliTimestamp(),
        };

        // Environment variable overrides (ignore parse errors; bounds check defensively)
        if (std.process.getEnvVarOwned(allocator, "GEODE_MALFORMED_WAL_WARN_PCT")) |val| {
            defer allocator.free(val);
            if (std.fmt.parseFloat(f64, val)) |p| {
                if (p > 0.0 and p < 1.0) engine.config.malformed_warn_pct = p;
            } else |_| {}
        } else |_| {}
        if (std.process.getEnvVarOwned(allocator, "GEODE_MALFORMED_WAL_ABORT_PCT")) |val| {
            defer allocator.free(val);
            if (std.fmt.parseFloat(f64, val)) |p| {
                if (p > 0.0 and p < 1.0 and p > engine.config.malformed_warn_pct) engine.config.malformed_abort_pct = p;
            } else |_| {}
        } else |_| {}
        if (std.process.getEnvVarOwned(allocator, "GEODE_MALFORMED_WAL_SNAPSHOT_INTERVAL")) |val| {
            defer allocator.free(val);
            if (std.fmt.parseInt(u64, val, 10)) |v| {
                if (v > 0 and v <= 10_000) engine.config.malformed_snapshot_interval = v;
            } else |_| {}
        } else |_| {}

        // Initialize sinks
        for (config.sinks) |sink_type| {
            const sink = try Sink.init(allocator, sink_type);
            try engine.sinks.append(allocator, sink);
        }

        return engine;
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // free diagnostics list
        self.diag_events.deinit(self.allocator);

        // Free any remaining events (in case not flushed)
        for (self.event_buffer.items) |*event| {
            freeEventInternal(self, event);
        }
        self.event_buffer.deinit(self.allocator);

        for (self.sinks.items) |*sink| {
            sink.deinit();
        }
        self.sinks.deinit(self.allocator);
    }

    pub fn start(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_running) {
            return error.AlreadyRunning;
        }

        // If CDC globally disabled we treat start as a no-op so that tests can assert not running
        if (!self.config.enabled) {
            return; // remain not running
        }

        self.is_running = true;
        self.start_time_ms = std.time.milliTimestamp();
        // record lifecycle diagnostic
        self.diag_events.append(self.allocator, .start) catch @panic("OOM");
        self.thread = try std.Thread.spawn(.{}, processingLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.mutex.lock();
        const was_running = self.is_running;
        self.is_running = false;
        self.mutex.unlock();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        if (was_running) { // only record a stop once per active run
            self.mutex.lock();
            self.diag_events.append(self.allocator, .stop) catch @panic("OOM");
            self.mutex.unlock();
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
            .transaction_id = self.current_txn_id,
            .sequence = self.next_sequence,
            .change_type = change_type,
            .entity_type = entity_type,
            .entity_id = entity_id,
            .before = if (before) |b| try self.allocator.dupe(u8, b) else null,
            .after = if (after) |a| try self.allocator.dupe(u8, a) else null,
            .metadata = metadata,
        };
        self.next_sequence += 1;

        try self.event_buffer.append(self.allocator, event);
        self.total_events += 1;
        if (self.event_buffer.items.len > self.peak_buffer) self.peak_buffer = self.event_buffer.items.len;
        if (self.config.adaptive_flush) {
            self.adapt_events_accum += 1;
            if (self.adapt_events_accum >= self.config.adapt_window_events) {
                // Simple heuristic: events per interval vs desired; adjust up/down by 2x within bounds.
                const now = std.time.milliTimestamp();
                const elapsed_ms = @max(now - self.last_flush, 1);
                const eps = (@as(f64, @floatFromInt(self.adapt_events_accum)) * 1000.0) / @as(f64, @floatFromInt(elapsed_ms));
                if (eps > 50_000 and self.dynamic_batch_size < self.config.max_batch_size) {
                    const new_size = @min(self.dynamic_batch_size * 2, self.config.max_batch_size);
                    if (new_size != self.dynamic_batch_size) self.batch_adjustments += 1;
                    self.dynamic_batch_size = new_size;
                } else if (eps < 5_000 and self.dynamic_batch_size > self.config.min_batch_size) {
                    const new_size = @max(self.dynamic_batch_size / 2, self.config.min_batch_size);
                    if (new_size != self.dynamic_batch_size) self.batch_adjustments += 1;
                    self.dynamic_batch_size = new_size;
                }
                self.adapt_events_accum = 0;
            }
        }

        // Check if we should flush
        const target_batch = if (self.config.adaptive_flush) self.dynamic_batch_size else self.config.batch_size;
        if (self.event_buffer.items.len >= target_batch) {
            try self.flush();
        }
    }

    fn processingLoop(self: *Self) void {
        while (self.is_running) {
            // Sleep fallback for Zig 0.15: use std.time.sleep if available else busy-wait
            if (@hasDecl(std.time, "sleep")) {
                std.time.sleep(self.config.flush_interval_ms * 1_000_000);
            } else {
                const target = std.time.milliTimestamp() + @as(i64, @intCast(self.config.flush_interval_ms));
                while (std.time.milliTimestamp() < target) {}
            }

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

        // Clear buffer freeing event-owned memory
        for (self.event_buffer.items) |*event| {
            freeEventInternal(self, event);
        }
        self.event_buffer.clearRetainingCapacity();

        self.last_flush = std.time.milliTimestamp();
    }

    fn cleanupOldEvents(self: *Self) !void {
        const cutoff = std.time.milliTimestamp() - self.config.retention_period_ms;

        var i: usize = 0;
        while (i < self.event_buffer.items.len) {
            if (self.event_buffer.items[i].timestamp < cutoff) {
                var event = self.event_buffer.orderedRemove(i);
                freeEventInternal(self, &event);
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
            .peak_buffer = self.peak_buffer,
            .batch_adjustments = self.batch_adjustments,
            .malformed_wal_records = self.malformed_wal_records,
        };
    }

    /// Snapshot lifecycle diagnostic events (ordered) for tests.
    pub fn diagnosticsLifecycle(self: *Self, allocator: Allocator) ![]DiagEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try allocator.alloc(DiagEvent, self.diag_events.items.len);
        std.mem.copy(DiagEvent, out, self.diag_events.items);
        return out;
    }

    /// Returns whether the CDC engine background processing loop is active.
    pub fn isRunning(self: *Self) bool {
        self.mutex.lock();
        const running = self.is_running;
        self.mutex.unlock();
        return running;
    }

    /// Public wrapper for change capture; alias to captureChange for semantic clarity in tests / future WAL tail integration.
    pub fn emitChange(
        self: *Self,
        change_type: ChangeType,
        entity_type: EntityType,
        entity_id: u64,
        before: ?[]const u8,
        after: ?[]const u8,
    ) !void {
        try self.captureChange(change_type, entity_type, entity_id, before, after);
    }

    /// Generate a resume token (opaque u64 sequence) representing next unread sequence after current highest.
    pub fn currentResumeToken(self: *Self) u64 {
        self.mutex.lock();
        const token = self.next_sequence; // next to be assigned => resume from this
        self.mutex.unlock();
        return token;
    }

    /// Replay events with sequence >= token into provided slice (allocator-owned). Primarily for tests now.
    pub fn replayFrom(self: *Self, allocator: Allocator, token: u64) ![]ChangeEvent {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Count how many qualify
        var count: usize = 0;
        for (self.event_buffer.items) |ev| {
            if (ev.sequence >= token) count += 1;
        }
        var out = try allocator.alloc(ChangeEvent, count);
        var idx: usize = 0;
        for (self.event_buffer.items) |ev| {
            if (ev.sequence >= token) {
                out[idx] = ev; // shallow copy (tests only; caller must not free internals)
                idx += 1;
            }
        }
        return out;
    }

    /// Force an immediate flush of currently buffered events to all sinks (primarily memory sink for tests).
    pub fn flushNow(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flush();
    }

    pub fn beginTxn(self: *Self, id: u64) void {
        self.mutex.lock();
        self.current_txn_id = id;
        self.mutex.unlock();
    }

    pub fn endTxn(self: *Self) void {
        self.mutex.lock();
        self.current_txn_id = 0;
        self.mutex.unlock();
    }

    /// Return the number of events stored in the in-process memory sink (0 if not configured).
    pub fn memorySinkEventCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sinks.items) |*sink| {
            switch (sink.impl) {
                .memory => |ms| return ms.events.items.len,
                else => {},
            }
        }
        return 0;
    }

    /// Simulated WAL record ingestion; maps record metadata to a change event.
    pub fn ingestFromWalRecord(self: *Self, txn_id: u64, entity_type: EntityType, entity_id: u64, after_json: []const u8) !void {
        // Count attempt (valid or malformed)
        self.mutex.lock();
        self.total_wal_attempts += 1;
        const attempt = self.total_wal_attempts;
        self.mutex.unlock();

        const malformed = after_json.len == 0 or after_json[0] != '{' or after_json[after_json.len - 1] != '}';
        if (malformed) {
            self.mutex.lock();
            self.malformed_wal_records += 1;
            const count = self.malformed_wal_records;
            // Snapshot interval logic (always first)
            if (count == 1 or (count % self.config.malformed_snapshot_interval == 0)) {
                self.malformed_ring.record(count);
            }
            // Hash retention for first N malformed
            self.malformed_hashes.record(self.config.malformed_hash_retain, count, after_json);
            // Guardrail evaluation
            const ratio = @as(f64, @floatFromInt(self.malformed_wal_records)) / @as(f64, @floatFromInt(self.total_wal_attempts));
            if (!self.guardrail_warn_triggered and ratio >= self.config.malformed_warn_pct) {
                self.guardrail_warn_triggered = true;
                self.first_warn_ts_ms = std.time.milliTimestamp();
                std.log.warn("CDC malformed WAL warn threshold triggered ratio={d:.3}", .{ratio});
                std.log.warn("CDCMalformedWarn ratio={d:.3} ts_ms={d}", .{ ratio, self.first_warn_ts_ms });
            }
            if (!self.guardrail_abort_triggered and ratio >= self.config.malformed_abort_pct) {
                self.guardrail_abort_triggered = true;
                self.first_abort_ts_ms = std.time.milliTimestamp();
                std.log.err("CDC malformed WAL abort threshold triggered ratio={d:.3}", .{ratio});
                std.log.err("CDCMalformedAbort ratio={d:.3} ts_ms={d}", .{ ratio, self.first_abort_ts_ms });
            }
            self.mutex.unlock();
            if (count == 1 or (count % self.config.malformed_snapshot_interval == 0)) {
                std.log.warn("CDC malformed WAL record count={} attempts={} ratio={d:.3}", .{ count, attempt, @as(f64, @floatFromInt(self.malformed_wal_records)) / @as(f64, @floatFromInt(self.total_wal_attempts)) });
            }
            return; // counted & dropped
        }
        self.beginTxn(txn_id);
        try self.emitChange(.update, entity_type, entity_id, null, after_json);
        self.endTxn();
    }

    /// For tests: capture a snapshot of memory sink sequences (requires memory sink configured).
    pub fn memorySinkSequences(self: *Self, allocator: Allocator) ![]u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sinks.items) |*sink| {
            switch (sink.impl) {
                .memory => |ms| {
                    var arr = try allocator.alloc(u64, ms.events.items.len);
                    var i: usize = 0;
                    while (i < ms.events.items.len) : (i += 1) arr[i] = ms.events.items[i].sequence;
                    return arr;
                },
                else => {},
            }
        }
        return allocator.alloc(u64, 0);
    }

    /// Reset guardrail state (malformed WAL ratio tracking) clearing latched flags & timestamps while preserving counters.
    /// CANARY: REQ=REQ-GQL-042; FEATURE="CDC Engine"; ASPECT=GuardrailReset; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_042_CDC_GuardrailReset; OWNER=streaming; UPDATED=2025-09-20
    pub fn resetGuardrailState(self: *Self) void {
        self.mutex.lock();
        self.guardrail_warn_triggered = false;
        self.guardrail_abort_triggered = false;
        self.first_warn_ts_ms = 0;
        self.first_abort_ts_ms = 0;
        self.guardrail_epoch += 1;
        self.mutex.unlock();
    }

    /// Serialize malformed ring buffer snapshots to JSON array string.
    pub fn malformedLogSnapshots(self: *Self, allocator: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
        const writer = buf.writer(allocator);
        try self.malformed_ring.writeJson(writer);
        return buf.toOwnedSlice(allocator);
    }

    /// Export a consolidated diagnostics JSON object (string) containing counters and ring snapshots.
    pub fn exportDiagnostics(self: *Self, allocator: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
        const w = buf.writer(allocator);
        try w.writeAll("{");
        // core counters
        try w.writeAll("\"malformed_wal_records\":");
        try std.fmt.format(w, "{d}", .{self.malformed_wal_records});
        try w.writeAll(",\"total_wal_attempts\":");
        try std.fmt.format(w, "{d}", .{self.total_wal_attempts});
        try w.writeAll(",\"malformed_ratio\":");
        const ratio = if (self.total_wal_attempts == 0) 0.0 else (@as(f64, @floatFromInt(self.malformed_wal_records)) / @as(f64, @floatFromInt(self.total_wal_attempts)));
        // Simpler float formatting for Zig 0.15 compatibility
        try std.fmt.format(w, "{d}", .{ratio});
        // state flags
        try w.writeAll(",\"guardrail_warn_triggered\":");
        try w.writeAll(if (self.guardrail_warn_triggered) "true" else "false");
        try w.writeAll(",\"guardrail_abort_triggered\":");
        try w.writeAll(if (self.guardrail_abort_triggered) "true" else "false");
        // first trigger timestamps (0 = not triggered)
        try w.writeAll(",\"first_warn_ts_ms\":");
        try std.fmt.format(w, "{d}", .{self.first_warn_ts_ms});
        try w.writeAll(",\"first_abort_ts_ms\":");
        try std.fmt.format(w, "{d}", .{self.first_abort_ts_ms});
        try w.writeAll(",\"guardrail_epoch\":");
        try std.fmt.format(w, "{d}", .{self.guardrail_epoch});
        // uptime and backpressure
        const now_ms = std.time.milliTimestamp();
        const uptime_ms: i64 = if (self.start_time_ms > 0 and now_ms >= self.start_time_ms) (now_ms - self.start_time_ms) else 0;
        try w.writeAll(",\"uptime_ms\":");
        try std.fmt.format(w, "{d}", .{uptime_ms});
        const pending_events: u64 = @intCast(self.event_buffer.items.len);
        const backpressure_active = self.config.pending_backpressure_watermark > 0 and pending_events >= self.config.pending_backpressure_watermark;
        try w.writeAll(",\"backpressure\":");
        try w.writeAll(if (backpressure_active) "true" else "false");
        // configuration echo
        try w.writeAll(",\"config\":{\"enabled\":");
        try w.writeAll(if (self.config.enabled) "true" else "false");
        try w.writeAll(",\"malformed_snapshot_interval\":");
        try std.fmt.format(w, "{d}", .{self.config.malformed_snapshot_interval});
        try w.writeAll(",\"malformed_hash_retain\":");
        try std.fmt.format(w, "{d}", .{self.config.malformed_hash_retain});
        try w.writeAll(",\"malformed_warn_pct\":");
        try std.fmt.format(w, "{d}", .{self.config.malformed_warn_pct});
        try w.writeAll(",\"malformed_abort_pct\":");
        try std.fmt.format(w, "{d}", .{self.config.malformed_abort_pct});
        try w.writeAll(",\"flush_interval_ms\":");
        try std.fmt.format(w, "{d}", .{self.config.flush_interval_ms});
        try w.writeAll(",\"batch_size\":");
        try std.fmt.format(w, "{d}", .{self.config.batch_size});
        try w.writeAll(",\"pending_backpressure_watermark\":");
        try std.fmt.format(w, "{d}", .{self.config.pending_backpressure_watermark});
        try w.writeAll("}");
        // engine runtime state
        try w.writeAll(",\"engine\":{\"is_running\":");
        try w.writeAll(if (self.is_running) "true" else "false");
        try w.writeAll(",\"last_flush_ms\":");
        try std.fmt.format(w, "{d}", .{self.last_flush});
        try w.writeAll(",\"peak_buffer\":");
        try std.fmt.format(w, "{d}", .{self.peak_buffer});
        try w.writeAll(",\"current_buffer\":");
        try std.fmt.format(w, "{d}", .{self.event_buffer.items.len});
        try w.writeAll(",\"dynamic_batch_size\":");
        try std.fmt.format(w, "{d}", .{self.dynamic_batch_size});
        try w.writeAll(",\"batch_adjustments\":");
        try std.fmt.format(w, "{d}", .{self.batch_adjustments});
        try w.writeAll("}");
        // snapshots and hashes
        try w.writeAll(",\"malformed_snapshots\":");
        try self.malformed_ring.writeJson(w);
        try w.writeAll(",\"malformed_hashes\":");
        try self.malformed_hashes.writeJson(w, self.config.malformed_hash_retain);
        // version & timestamp
        try w.writeAll(",\"version\":\"v0.15.0\",\"timestamp_ms\":");
        try std.fmt.format(w, "{d}", .{std.time.milliTimestamp()});
        try w.writeAll("}");
        return buf.toOwnedSlice(allocator);
    }
};

pub const CDCStatus = struct {
    is_running: bool,
    total_events: u64,
    buffer_size: usize,
    last_flush: i64,
    sinks_count: usize,
    peak_buffer: usize,
    batch_adjustments: u32,
    malformed_wal_records: u64,
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
            .events = std.ArrayList(ChangeEvent).initCapacity(allocator, 0) catch @panic("OOM"),
        };
    }

    pub fn deinit(self: *MemorySink) void {
        // free owned allocations inside events first
        for (self.events.items) |*ev| {
            freeEventShallow(self.allocator, ev);
        }
        self.events.deinit(self.allocator);
    }

    pub fn send(self: *MemorySink, events: []const ChangeEvent) !void {
        for (events) |event| {
            try self.events.append(self.allocator, event);
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
            try self.file.writeAll(json);
            try self.file.writeAll("\n");
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

            if (@hasDecl(std.time, "sleep")) {
                std.time.sleep(100_000_000); // 100ms
            } else {
                const target = std.time.milliTimestamp() + 100;
                while (std.time.milliTimestamp() < target) {}
            }
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
            .buckets = std.ArrayList(WindowBucket).initCapacity(allocator, 0) catch @panic("OOM"),
            .watermark = 0,
        };
    }

    pub fn deinit(self: *Window) void {
        for (self.buckets.items) |*bucket| {
            bucket.deinit();
        }
        self.buckets.deinit(self.allocator);
    }
};

const WindowBucket = struct {
    start_time: i64,
    end_time: i64,
    events: std.ArrayList(ChangeEvent),
    aggregates: std.StringHashMap(f64),

    pub fn deinit(self: *WindowBucket) void {
        for (self.events.items) |*ev| {
            freeEventShallow(self.allocator, ev);
        }
        self.events.deinit(self.allocator);
        self.aggregates.deinit();
    }
};

fn serializeEvent(allocator: Allocator, event: ChangeEvent) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "timestamp": {d},
        \\  "transaction_id": {d},
        \\  "change_type": "{s}",
        \\  "entity_type": "{s}",
        \\  "entity_id": {d},
        \\  "before": {s},
        \\  "after": {s}
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

// Free all allocations owned by an event (before/after + metadata values + metadata table)
fn freeEventInternal(engine: *CDCEngine, ev: *ChangeEvent) void {
    if (ev.before) |b| engine.allocator.free(b);
    if (ev.after) |a| engine.allocator.free(a);
    // Free metadata values (keys are string literals, not owned)
    var it = ev.metadata.iterator();
    while (it.next()) |entry| {
        engine.allocator.free(entry.value_ptr.*);
    }
    ev.metadata.deinit();
    ev.before = null;
    ev.after = null;
}

// Shallow free for contexts where we only have allocator, not engine pointer.
fn freeEventShallow(allocator: Allocator, ev: *ChangeEvent) void {
    if (ev.before) |b| allocator.free(b);
    if (ev.after) |a| allocator.free(a);
    var it = ev.metadata.iterator();
    while (it.next()) |entry| allocator.free(entry.value_ptr.*);
    ev.metadata.deinit();
    ev.before = null;
    ev.after = null;
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
