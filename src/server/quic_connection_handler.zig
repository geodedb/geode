const std = @import("std");
const geode = @import("geode");
const protocol = geode.protocol;
const diagnostics = geode.diagnostics;
const eval = geode.eval;
const quic_transport = @import("transport/quic");
const query_plan_cache = @import("query_plan_cache.zig");
const ServerState = @import("server_state.zig").ServerState;
const SessionConfiguration = @import("server_state.zig").SessionConfiguration;
const CatalogSchema = @import("server_state.zig").CatalogSchema;
const CatalogGraph = @import("server_state.zig").CatalogGraph;
const query_executor = @import("query_executor.zig");
const execution = geode.execution;
const cost_explain = @import("../planner/cost_explain.zig");
const server_flags = @import("server_flags.zig");
const message_handlers = @import("message_handlers.zig");
const protocol_handler = @import("protocol_handler.zig");
const wal_manager = @import("wal_manager.zig");
const query_ast_cache = @import("query_ast_cache.zig");
// CANARY: REQ=REQ-ABAC-WIRE-012; FEATURE="ABAC Enforcement"; ASPECT=QUICImport; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Import geode_auth for SecurityManager type in QUIC connection handling
const geode_auth = @import("geode_auth");

// CANARY: REQ=REQ-SERVER-REFACTOR-012; FEATURE="ServerRefactoring"; ASPECT=QUIC_HANDLERS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.3 - QUIC Connection Handlers Module (Eighth Increment)
// Extracted from server/main.zig to improve modularity and reduce main() function size
// Contains handleQuicConnection and processMessage functions for QUIC protocol handling

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-012; FEATURE="Structured Logging"; ASPECT=QUICHandler; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-065; FEATURE="JSON Library Migration"; ASPECT=QUICHandler; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-25
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-065; FEATURE="JSON Library Migration"; ASPECT=QUICHandler; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-25
const json_lib = @import("json");
const schema = @import("schema");
const protobuf = @import("protobuf");

// JSON row types for SHOW statement results (Legacy - might need to map to Proto or keep for internal logic)
const ShowGraphRow = struct { name: []const u8 };
const ShowIndexRow = struct { name: []const u8, type: []const u8, table: []const u8, columns: []const u8 };
const ShowConstraintRow = struct { name: []const u8, type: []const u8, table: []const u8, columns: []const u8 };
const ShowTableRow = struct { name: []const u8, type: []const u8 };
const ShowFunctionRow = struct { name: []const u8, signature: []const u8, return_type: []const u8 };

// Error response type (Legacy JSON)
const ErrorResponse = struct {
    status_class: []const u8 = "58000",
    @"error": []const u8,
};

// CANARY: REQ=REQ-PROTOCOL-DETECT-001; FEATURE="ProtocolAutoDetect"; ASPECT=DualProtocol; STATUS=IMPL; OWNER=wire; UPDATED=2026-02-02
// Support both JSON line protocol (legacy REPL/CLI) and length-prefixed protobuf
const ProtocolType = enum {
    json_line, // JSON line protocol (newline-delimited JSON)
    protobuf, // Length-prefixed protobuf (4-byte big-endian + protobuf bytes)
};

// CANARY: REQ=REQ-JSON-LINE-READER-001; FEATURE="JsonLineProtocol"; ASPECT=LegacySupport; STATUS=IMPL; OWNER=wire; UPDATED=2026-02-02
/// Buffered JSON line reader for legacy REPL/CLI clients
const BufferedJsonLineReader = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    stream: *quic_transport.QuicStream,
    buffer: std.ArrayList(u8),
    start_index: usize = 0,
    read_buf: [4096]u8 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        transport: *quic_transport.QuicTransport,
        stream: *quic_transport.QuicStream,
    ) !BufferedJsonLineReader {
        return .{
            .allocator = allocator,
            .transport = transport,
            .stream = stream,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *BufferedJsonLineReader) void {
        self.buffer.deinit(self.allocator);
    }

    /// Read next JSON line (newline-delimited)
    pub fn nextLine(self: *BufferedJsonLineReader) !?[]const u8 {
        var would_block_attempts: usize = 0;
        const max_would_block_attempts: usize = 30000; // 30s at 1ms sleep

        while (true) {
            // Check if we have a complete line in buffer
            const unread = self.buffer.items[self.start_index..];
            if (std.mem.indexOf(u8, unread, "\n")) |newline_pos| {
                // Found complete line
                const line = unread[0..newline_pos];
                self.start_index += newline_pos + 1;
                self.compactBuffer();
                return line;
            }

            // Need more data
            const n = self.stream.read(&self.read_buf) catch |err| {
                if (err == error.WouldBlock) {
                    would_block_attempts += 1;
                    if (would_block_attempts >= max_would_block_attempts) {
                        return error.Timeout;
                    }
                    try self.transport.poll(0);
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            would_block_attempts = 0;

            if (n == 0) {
                if (self.start_index == self.buffer.items.len) {
                    return null; // Clean EOF
                }
                return error.UnexpectedEndOfStream;
            }

            try self.buffer.appendSlice(self.allocator, self.read_buf[0..n]);
        }
    }

    fn compactBuffer(self: *BufferedJsonLineReader) void {
        if (self.start_index == 0) return;

        const remaining = self.buffer.items.len - self.start_index;
        if (remaining == 0) {
            self.buffer.clearRetainingCapacity();
            self.start_index = 0;
            return;
        }

        // Compact when we've consumed a significant prefix
        if (self.start_index > 4096 or self.start_index > remaining) {
            std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[self.start_index..]);
            self.buffer.shrinkRetainingCapacity(remaining);
            self.start_index = 0;
        }
    }
};

// CANARY: REQ=REQ-PERF-QUIC-READLINE-001; FEATURE="BufferedProtoReader"; ASPECT=TransportHotPath; STATUS=IMPL; OWNER=wire; UPDATED=2026-02-02
/// Buffered Protobuf reader that handles Length-Prefixed messages.
const BufferedProtoReader = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    stream: *quic_transport.QuicStream,
    buffer: std.ArrayList(u8),
    start_index: usize = 0,
    read_buf: [4096]u8 = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        transport: *quic_transport.QuicTransport,
        stream: *quic_transport.QuicStream,
    ) !BufferedProtoReader {
        return .{
            .allocator = allocator,
            .transport = transport,
            .stream = stream,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *BufferedProtoReader) void {
        self.buffer.deinit(self.allocator);
    }

    // Reads the next length-prefixed message.
    // Length is 4 bytes Big Endian.
    pub fn nextMessage(self: *BufferedProtoReader) !?schema.QuicClientMessage {
        var would_block_attempts: usize = 0;
        const max_would_block_attempts: usize = 30000; // 30s at 1ms sleep

        while (true) {
            // Check if we have enough data for length header
            const unread = self.buffer.items[self.start_index..];
            if (unread.len >= 4) {
                const len_bytes = unread[0..4];
                const msg_len = std.mem.readInt(u32, len_bytes, .big);

                // Sanity check length (e.g., 16MB)
                if (msg_len > 16 * 1024 * 1024) return error.MessageTooLarge;

                if (unread.len >= 4 + msg_len) {
                    // We have the full message
                    const msg_bytes = unread[4..][0..msg_len];

                    // Decode using schema
                    var fbs = std.io.fixedBufferStream(msg_bytes);
                    const reader = protobuf.initReader(fbs.reader(), self.allocator);
                    const msg = schema.QuicClientMessage.decode(self.allocator, reader) catch |err| {
                        log.warn("Failed to decode Protobuf message: {}", .{err});
                        return err;
                    };

                    // Consume bytes
                    self.start_index += 4 + msg_len;
                    self.compactBuffer();
                    return msg;
                }
            }

            // Need more data
            const n = self.stream.read(&self.read_buf) catch |err| {
                if (err == error.WouldBlock) {
                    would_block_attempts += 1;
                    if (would_block_attempts >= max_would_block_attempts) {
                        return error.Timeout;
                    }
                    try self.transport.poll(0);
                    std.Thread.sleep(1 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };

            would_block_attempts = 0;

            if (n == 0) {
                if (self.start_index == self.buffer.items.len) {
                    // Clean EOF
                    return null; // Return optional null for EOF
                }
                // Partial message EOF
                return error.UnexpectedEndOfStream;
            }

            try self.buffer.appendSlice(self.allocator, self.read_buf[0..n]);
        }
    }

    fn compactBuffer(self: *BufferedProtoReader) void {
        if (self.start_index == 0) return;

        const remaining = self.buffer.items.len - self.start_index;
        if (remaining == 0) {
            self.buffer.clearRetainingCapacity();
            self.start_index = 0;
            return;
        }

        // Compact when we've consumed a significant prefix
        if (self.start_index < 4096 and self.start_index * 2 < self.buffer.items.len) {
            return;
        }

        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[self.start_index..]);
        self.buffer.shrinkRetainingCapacity(remaining);
        self.start_index = 0;
    }
};

// Import types and functions from query_executor
const evaluateUnion = query_executor.evaluateUnion;
const UnionMetrics = query_executor.UnionMetrics;
const StageTimings = query_executor.StageTimings;
const parseParams = query_executor.parseParams;
const collectTextDiagnostics = query_executor.collectTextDiagnostics;
const buildAdditionalStatusesAlloc = query_executor.buildAdditionalStatusesAlloc;

// Import functions from server_flags
const computeBaseFlags = server_flags.computeBaseFlags;
const g_order_keys_expr = server_flags.getOrderKeysExpr();

// Import CDC and backup handlers
const handleCdcControl = message_handlers.handleCdcControl;
const handleBackupRequest = protocol_handler.handleBackupRequest;
const handleRestoreRequest = protocol_handler.handleRestoreRequest;
const handleUploadBackupRequest = protocol_handler.handleUploadBackupRequest;

/// Build JSON array for a slice of ExecutionResult rows without per-row allocations.
fn buildRowsJsonFromResult(
    allocator: std.mem.Allocator,
    result: *const execution.ExecutionResult,
    start: usize,
    end: usize,
) ![]u8 {
    var arr_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer arr_buf.deinit(allocator);
    const w = arr_buf.writer(allocator);
    w.writeAll("[") catch {};
    var i: usize = start;
    var first = true;
    while (i < end) : (i += 1) {
        if (!first) w.writeAll(",") catch {};
        first = false;
        const row = result.rows[i];
        w.writeAll("{") catch {};
        for (row, 0..) |val, idx| {
            if (idx > 0) w.writeAll(",") catch {};
            if (idx < result.columns.len) {
                w.print("\"{s}\":", .{result.columns[idx]}) catch {};
            }
            execution.writeValue(allocator, w, val) catch {};
        }
        w.writeAll("}") catch {};
    }
    w.writeAll("]") catch {};
    return arr_buf.toOwnedSlice(allocator) catch "[]";
}

/// Remove the `,"final":true|false` field from a bindings line for compatibility.
fn stripFinalFlag(allocator: std.mem.Allocator, line: []u8) []u8 {
    var s = line;
    if (std.mem.indexOf(u8, s, ",\"final\":true")) |pos| {
        const head = s[0..pos];
        const tail = s[pos + ",\"final\":true".len ..];
        var joined = std.ArrayList(u8).initCapacity(allocator, 0) catch return line;
        defer joined.deinit(allocator);
        joined.appendSlice(allocator, head) catch {};
        joined.appendSlice(allocator, tail) catch {};
        const out = joined.toOwnedSlice(allocator) catch line;
        allocator.free(line);
        return out;
    } else if (std.mem.indexOf(u8, s, ",\"final\":false")) |pos2| {
        const head2 = s[0..pos2];
        const tail2 = s[pos2 + ",\"final\":false".len ..];
        var joined2 = std.ArrayList(u8).initCapacity(allocator, 0) catch return line;
        defer joined2.deinit(allocator);
        joined2.appendSlice(allocator, head2) catch {};
        joined2.appendSlice(allocator, tail2) catch {};
        const out2 = joined2.toOwnedSlice(allocator) catch line;
        allocator.free(line);
        return out2;
    }
    return line;
}

// Protocol flag constants
const F_PROPERTY_ORDER = "U:PropOrder=LexDecl";
const F_ILLEGAL = "U:PropOrder=Illegal";
const F_TIEBREAK = "U:OrderTiebreak=LexJSON";
const DEBUG_PROFILE = false;

// CANARY: REQ=REQ-ABAC-WIRE-013; FEATURE="ABAC Enforcement"; ASPECT=QUICHandler; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Updated handleQuicConnection signature to accept SecurityManager for ABAC enforcement
pub fn handleQuicConnection(
    gpa: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    result_format_txt: bool,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    test_wal_skip_ratio: ?f64,
    env_spill_sort: usize,
    env_spill_distinct: usize,
    env_spill_union: usize,
    env_spill_threshold: usize,
    env_storage_checksum_error: bool,
    env_wal_compact_interval: usize,
    _force_serialization_failure_unused: bool,
    security_manager: ?*geode_auth.SecurityManager,
    shared_ast_cache: ?*query_ast_cache.SharedAstCache,
) !void {
    _ = env_wal_compact_interval;
    _ = _force_serialization_failure_unused;
    // CANARY: REQ=REQ-QUIC-CONN-CLEANUP-003; FEATURE="ConnectionMemoryManagement"; ASPECT=ProperCleanup; STATUS=EXEMPT; OWNER=server; UPDATED=2025-12-27
    // Use destroyConnection to properly remove from transport list, close, and free resources
    defer transport.destroyConnection(conn);
    std.debug.print("DEBUG_TRACE: Entering handleQuicConnection\n", .{});
    log.debug("Entering handleQuicConnection", &.{});

    // Poll the endpoint to process incoming STREAM frames before accepting
    // vendor/quic requires explicit polling to receive packets and populate stream queues
    // Try polling with retries to ensure we receive the client's initial STREAM frame
    // GAP-0200: Reduced poll timeout from 50ms to 5ms for high throughput
    var poll_attempts: usize = 0;
    while (poll_attempts < 10) : (poll_attempts += 1) {
        try transport.poll(5); // Poll for up to 5ms
        if (conn.inner.hasIncomingStreams()) break;
        if (poll_attempts > 0) {
            log.debug("No streams yet, retrying", &.{
                Attr.int("attempt", @intCast(poll_attempts + 1)),
                Attr.int("max_attempts", 10),
            });
        }
    }

    // Accept a stream for the protocol communication
    log.debug("Attempting to accept stream", &.{});
    const stream = try conn.acceptStream();
    log.debug("Stream accepted successfully", &.{});
    defer stream.close();

    // CANARY: REQ=REQ-PROTOCOL-DETECT-002; FEATURE="ProtocolAutoDetect"; ASPECT=PeekFirstByte; STATUS=IMPL; OWNER=wire; UPDATED=2026-02-02
    // Detect protocol type by peeking at first byte
    // JSON line protocol starts with '{' (0x7B), protobuf starts with length prefix
    var peek_buf: [1]u8 = undefined;
    var peek_attempts: usize = 0;
    const max_peek_attempts: usize = 1000; // 1 second timeout

    while (peek_attempts < max_peek_attempts) : (peek_attempts += 1) {
        const n = stream.read(&peek_buf) catch |err| {
            if (err == error.WouldBlock) {
                try transport.poll(10);
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n > 0) break;
        try transport.poll(10);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    if (peek_attempts >= max_peek_attempts) {
        log.warn("Timeout waiting for first byte from client", &.{});
        return;
    }

    const detected_protocol: ProtocolType = if (peek_buf[0] == '{') .json_line else .protobuf;
    log.debug("Detected protocol type", &.{
        Attr.string("protocol", if (detected_protocol == .json_line) "json_line" else "protobuf"),
        Attr.int("first_byte", @intCast(peek_buf[0])),
    });

    // Initialize (or reuse) shared WAL manager.
    // This removes per-connection WAL open/close overhead.
    const wal_mgr = try wal_manager.getOrCreateWalManager(gpa, test_wal_skip_ratio);

    // Initialize state
    var state = ServerState{
        .allocator = gpa,
        .session_config = SessionConfiguration.init(gpa),
    };
    state.telemetry_paging = if (std.process.getEnvVarOwned(gpa, "GEODE_TELEMETRY_PAGING")) |v| blk: {
        defer gpa.free(v);
        break :blk true;
    } else |_| false;
    state.txn_manager.init(gpa);
    state.inserted_values = .{};
    state.catalog_schemas = std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.catalog_graphs = std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.wal_ptr = @ptrCast(wal_mgr);
    state.spill_sort = env_spill_sort;
    state.spill_distinct = env_spill_distinct;
    state.spill_union = env_spill_union;
    state.query_mem_limit_bytes = env_spill_threshold;
    state.storage_checksum_error = env_storage_checksum_error;
    // CANARY: REQ=REQ-ABAC-WIRE-014; FEATURE="ABAC Enforcement"; ASPECT=QUICState; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Wire SecurityManager into ServerState for QUIC connection ABAC enforcement
    state.security_manager = security_manager;

    // Query optimizer gating: enable only when explicitly requested.
    // PROFILE/EXPLAIN will still enable it per-query.
    // CANARY: REQ=REQ-PERF-OPT-GATE-001; FEATURE="OptimizerGating"; ASPECT=HotPath; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-27
    state.query_optimizer_enabled = if (std.process.getEnvVarOwned(gpa, "GEODE_ENABLE_QUERY_OPTIMIZER")) |v| blk: {
        defer gpa.free(v);
        if (v.len == 0) break :blk false;
        if (v[0] == '0') break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "false")) break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "off")) break :blk false;
        break :blk true;
    } else |_| false;

    // Inline RUN+PULL for small results (configurable).
    // Enabled by default; set GEODE_INLINE_RESULTS=0 to disable.
    // CANARY: REQ=REQ-PERF-INLINE-PULL-001; FEATURE="InlineRunPull"; ASPECT=HotPath; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-27
    state.inline_results_enabled = if (std.process.getEnvVarOwned(gpa, "GEODE_INLINE_RESULTS")) |v| blk: {
        defer gpa.free(v);
        if (v.len == 0) break :blk true;
        if (v[0] == '0') break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "false")) break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "off")) break :blk false;
        break :blk true;
    } else |_| true;
    state.inline_results_max_rows = if (std.process.getEnvVarOwned(gpa, "GEODE_INLINE_RESULTS_MAX_ROWS")) |v| blk: {
        defer gpa.free(v);
        break :blk std.fmt.parseInt(usize, v, 10) catch state.inline_results_max_rows;
    } else |_| state.inline_results_max_rows;

    // Initialize query plan cache and optimizer for performance optimization
    var query_optimizer = query_plan_cache.QueryOptimizer.init(gpa, 100); // Cache up to 100 plans
    defer query_optimizer.deinit();
    state.query_optimizer = &query_optimizer;

    // Attach shared AST cache for cross-connection reuse.
    // CANARY: REQ=REQ-PERF-AST-CACHE-003; FEATURE="SharedASTCache"; ASPECT=ConnectionState; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-27
    state.query_ast_cache = shared_ast_cache;

    // Initialize distributed query planner for federation-aware optimization
    var federation_manager = geode.distributed.query_planner.FederationManager.init(gpa);
    defer federation_manager.deinit();
    var dist_planner = geode.distributed.query_planner.DistributedQueryPlanner.init(gpa, &federation_manager);
    defer dist_planner.deinit();
    state.federation_manager = &federation_manager;
    state.distributed_planner = &dist_planner;

    // CANARY: REQ=REQ-PROTOCOL-DISPATCH-001; FEATURE="ProtocolAutoDetect"; ASPECT=MessageLoop; STATUS=IMPL; OWNER=wire; UPDATED=2026-02-02
    // Process messages based on detected protocol type
    if (detected_protocol == .json_line) {
        // JSON line protocol - use JSON reader
        var json_reader = try BufferedJsonLineReader.init(gpa, transport, stream);
        defer json_reader.deinit();

        // Pre-populate buffer with the peeked byte
        try json_reader.buffer.append(gpa, peek_buf[0]);

        while (true) {
            const line_opt = json_reader.nextLine() catch |err| {
                if (err == error.EndOfStream) return;
                if (err == error.WouldBlock) {
                    try transport.poll(0);
                    continue;
                }
                log.err("JSON read error: {}", .{err});
                return err;
            };

            if (line_opt == null) return; // EOF
            const line = line_opt.?;

            // Process JSON message
            const response = processJsonLineMessage(gpa, &state, line) catch |err| {
                log.err("JSON process error: {}", .{err});
                const err_response = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"58000\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
                defer gpa.free(err_response);
                try stream.writeAll(err_response);
                continue;
            };
            defer gpa.free(response);

            try stream.writeAll(response);
        }
    } else {
        // Protobuf protocol - use protobuf reader
        var line_reader = try BufferedProtoReader.init(gpa, transport, stream);
        defer line_reader.deinit();

        // Pre-populate buffer with the peeked byte
        try line_reader.buffer.append(gpa, peek_buf[0]);

        while (true) {
            const msg_opt = line_reader.nextMessage() catch |err| {
                if (err == error.EndOfStream) return;
                if (err == error.WouldBlock) {
                    try transport.poll(0);
                    continue;
                }
                log.err("Protobuf read error: {}", .{err});
                return err;
            };

            if (msg_opt == null) return; // EOF
            const msg = msg_opt.?;

            // Process protobuf message
            const response_msg = processMessage(gpa, &state, msg, result_format_txt, disable_estimates, compact_profile, memcurve_profile) catch |err| {
                log.err("Protobuf process error: {}", .{err});
                const err_resp = schema.Error{
                    .code = "58000",
                    .message = "Internal Server Error",
                };
                const resp = schema.QuicServerMessage{ .execute = .{ .val = .{ .@"error" = err_resp } } };

                var err_buf = std.ArrayList(u8).init(gpa);
                defer err_buf.deinit();
                const pb_writer = protobuf.initWriter(err_buf.writer());
                try resp.encode(pb_writer);

                const encoded = err_buf.items;
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, len_buf[0..4], @intCast(encoded.len), .big);
                try stream.writeAll(&len_buf);
                try stream.writeAll(encoded);
                continue;
            };

            // Encode Response
            var resp_buf = std.ArrayList(u8).init(gpa);
            defer resp_buf.deinit();
            const pb_writer = protobuf.initWriter(resp_buf.writer());
            try response_msg.encode(pb_writer);

            const encoded_resp = resp_buf.items;
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, len_buf[0..4], @intCast(encoded_resp.len), .big);
            try stream.writeAll(&len_buf);
            try stream.writeAll(encoded_resp);
        }
    }
}

pub fn processMessage(
    gpa: std.mem.Allocator,
    state: *ServerState,
    msg: schema.QuicClientMessage, // Changed from []const u8 line
    result_format_txt: bool,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
) !schema.QuicServerMessage {
    _ = disable_estimates;
    _ = compact_profile;
    _ = memcurve_profile;
    _ = result_format_txt;

    switch (msg) {
        // Trace logging
        else => {
            std.debug.print("FORCE DEBUG: Server processing message\n", .{});
            log.debug("Server processing message: {}", .{msg});
        },
    }
    switch (msg) {
        .hello => |hello_req| {
            const user_mgmt = geode.user_management;

            var caps = std.ArrayList([]const u8).init(gpa);
            try caps.append(gpa, "QUIC");
            try caps.append(gpa, "TLS1.3");

            // Check if authentication is required
            if (user_mgmt.isAuthEnabled()) {
                // Validate credentials
                if (hello_req.username.len == 0 or hello_req.password.len == 0) {
                    return schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = "",
                        .error_message = "Authentication required",
                        .capabilities = caps,
                    } };
                }

                // Authenticate user
                const role = user_mgmt.authenticate(hello_req.username, hello_req.password) catch {
                    return schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = "",
                        .error_message = "Authentication failed",
                        .capabilities = caps,
                    } };
                };

                // Store authenticated user info in state
                state.authenticated_user = try gpa.dupe(u8, hello_req.username);
                state.authenticated_password = try gpa.dupe(u8, hello_req.password);
                state.authenticated_role = role;
            }

            return schema.QuicServerMessage{ .hello = .{
                .success = true,
                .session_id = "quic-session",
                .error_message = "",
                .capabilities = caps,
            } };
        },
        .execute => |exec_req| {
            log.info("PROTOBUF .execute received", &.{
                Attr.int("query_len", @intCast(exec_req.query.len)),
            });

            // Execute the query using test_harness
            const user_mgmt = geode.user_management;

            // Check if authentication is required but no user is authenticated
            if (user_mgmt.isAuthEnabled() and state.authenticated_user == null) {
                const err_resp = schema.Error{ .code = "28000", .message = "Authentication required" };
                return schema.QuicServerMessage{ .execute = .{ .val = .{ .@"error" = err_resp } } };
            }

            // Execute query via test_harness
            const options = geode.test_harness.QueryOptions{
                .user = state.authenticated_user,
                .password = state.authenticated_password,
                .pre_validated_role = if (state.authenticated_role) |role| .{
                    .username = state.authenticated_user orelse "",
                    .role = role,
                } else null,
                .output_format = "json",
            };

            log.info("Executing query via test_harness", &.{});
            const result = geode.test_harness.runQueryWithAuth(&gpa, exec_req.query, options) catch |err| {
                log.err("Query execution failed", &.{Attr.err("error", err)});
                const err_msg = @errorName(err);
                const err_resp = schema.Error{ .code = "58000", .message = err_msg };
                return schema.QuicServerMessage{ .execute = .{ .val = .{ .@"error" = err_resp } } };
            };
            defer gpa.free(result);

            log.info("Query executed successfully, calling saveIfDirty", &.{});
            // CANARY: REQ=REQ-QUIC-PERSIST-001; FEATURE="QUICDataPersistence"; ASPECT=PostExecutionPersist; STATUS=IMPL; OWNER=server; UPDATED=2026-02-02
            // Save graph store if dirty after query execution
            // Mutations mark the store as dirty; we save once per query to avoid O(n²) overhead
            const global_store = geode.graph_store.getGlobalStore(gpa);
            global_store.saveIfDirty();

            // Build response with result data
            // For now, return the result as a single string value in a page
            var rows = std.ArrayList(schema.Row).init(gpa);
            var values = std.ArrayList(schema.Value).init(gpa);
            try values.append(gpa, .{ .kind = .{ .string_val = try gpa.dupe(u8, result) } });
            try rows.append(gpa, .{ .values = values });

            const page = schema.DataPage{ .rows = rows, .last_page = true };
            return schema.QuicServerMessage{ .execute = .{ .val = .{ .page = page } } };
        },
        .ping => |_| {
            return schema.QuicServerMessage{ .ping = .{ .ok = true } };
        },
        .begin => |bg| {
            // Begin Transaction
            const tx_id = state.txn_manager.beginTransaction(bg.read_only) catch {
                const err_resp = schema.Error{ .code = "500", .message = "Failed to begin transaction" };
                return schema.QuicServerMessage{ .execute = .{ .@"error" = err_resp } }; // Todo: wrapped error?
            };
            // Simplified: assumes txn_manager returns u64 or string.
            // If u64, format it.
            var tx_id_str = std.ArrayList(u8).init(gpa);
            // defer tx_id_str.deinit(); // We hand off to response
            try std.fmt.format(tx_id_str.writer(), "{d}", .{tx_id});

            return schema.QuicServerMessage{ .begin = .{ .session_id = "sess", .tx_id = tx_id_str.toOwnedSlice() catch "" } };
        },
        .commit => |_| {
            state.txn_manager.commitTransaction() catch {
                return schema.QuicServerMessage{ .commit = .{ .success = false } };
            };
            return schema.QuicServerMessage{ .commit = .{ .success = true } };
        },
        .rollback => |_| {
            state.txn_manager.rollbackTransaction() catch {
                return schema.QuicServerMessage{ .rollback = .{ .success = false } };
            };
            return schema.QuicServerMessage{ .rollback = .{ .success = true } };
        },
    }
}

// CANARY: REQ=REQ-JSON-LINE-PROCESS-001; FEATURE="JsonLineProtocol"; ASPECT=MessageProcessing; STATUS=IMPL; OWNER=wire; UPDATED=2026-02-02
/// Process a JSON line protocol message and return JSON response
/// This handles legacy REPL/CLI clients that send JSON instead of protobuf
pub fn processJsonLineMessage(
    gpa: std.mem.Allocator,
    state: *ServerState,
    json_line: []const u8,
) ![]u8 {
    log.info("processJsonLineMessage called", &.{
        Attr.int("line_len", @intCast(json_line.len)),
    });

    // Parse the JSON message
    const trimmed = std.mem.trim(u8, json_line, " \t\r\n");
    if (trimmed.len == 0) {
        return try gpa.dupe(u8, "{\"status_class\":\"42000\",\"error\":\"Empty message\"}\n");
    }

    // Parse JSON using json_lib
    const parsed = json_lib.decode(gpa, trimmed, .{}) catch {
        return try gpa.dupe(u8, "{\"status_class\":\"42000\",\"error\":\"Invalid JSON\"}\n");
    };
    defer if (parsed.arena) |a| a.deinit();

    const obj = parsed.value.object;

    // Get message type
    const msg_type = obj.get("type") orelse {
        return try gpa.dupe(u8, "{\"status_class\":\"42000\",\"error\":\"Missing type field\"}\n");
    };

    if (msg_type != .string) {
        return try gpa.dupe(u8, "{\"status_class\":\"42000\",\"error\":\"Invalid type field\"}\n");
    }

    const type_str = msg_type.string;

    // Handle different message types
    if (std.mem.eql(u8, type_str, "HELLO")) {
        // Simple HELLO acknowledgment for JSON protocol
        return try gpa.dupe(u8, "{\"type\":\"HELLO\",\"status\":\"ok\",\"capabilities\":[\"QUIC\",\"TLS1.3\"]}\n");
    } else if (std.mem.eql(u8, type_str, "RUN_GQL")) {
        // Execute GQL query
        const text_val = obj.get("text") orelse {
            return try gpa.dupe(u8, "{\"status_class\":\"42000\",\"error\":\"Missing text field\"}\n");
        };

        if (text_val != .string) {
            return try gpa.dupe(u8, "{\"status_class\":\"42000\",\"error\":\"Invalid text field\"}\n");
        }

        const query = text_val.string;

        // Execute query via test_harness
        const options = geode.test_harness.QueryOptions{
            .user = state.authenticated_user,
            .password = state.authenticated_password,
            .pre_validated_role = if (state.authenticated_role) |role| .{
                .username = state.authenticated_user orelse "",
                .role = role,
            } else null,
            .output_format = "json",
        };

        const result = geode.test_harness.runQueryWithAuth(&gpa, query, options) catch |err| {
            const err_msg = @errorName(err);
            return try std.fmt.allocPrint(gpa, "{{\"status_class\":\"58000\",\"error\":\"{s}\"}}\n", .{err_msg});
        };
        defer gpa.free(result);

        // Save graph store if dirty after query execution
        const global_store = geode.graph_store.getGlobalStore(gpa);
        global_store.saveIfDirty();

        // Return the result with newline
        var response = try gpa.alloc(u8, result.len + 1);
        @memcpy(response[0..result.len], result);
        response[result.len] = '\n';
        return response;
    } else if (std.mem.eql(u8, type_str, "PULL")) {
        // For JSON protocol, PULL just returns empty bindings (results are inlined with RUN_GQL)
        return try gpa.dupe(u8, "{\"type\":\"BINDINGS\",\"bindings\":[],\"has_more\":false}\n");
    } else if (std.mem.eql(u8, type_str, "PING")) {
        return try gpa.dupe(u8, "{\"type\":\"PONG\",\"ok\":true}\n");
    } else if (std.mem.eql(u8, type_str, "BEGIN")) {
        const tx_id = state.txn_manager.beginTransaction(false) catch {
            return try gpa.dupe(u8, "{\"status_class\":\"25000\",\"error\":\"Failed to begin transaction\"}\n");
        };
        return try std.fmt.allocPrint(gpa, "{{\"type\":\"BEGIN_OK\",\"tx_id\":{d}}}\n", .{tx_id});
    } else if (std.mem.eql(u8, type_str, "COMMIT")) {
        state.txn_manager.commitTransaction() catch {
            return try gpa.dupe(u8, "{\"status_class\":\"25000\",\"error\":\"Failed to commit transaction\"}\n");
        };
        // Save graph store after commit
        const global_store = geode.graph_store.getGlobalStore(gpa);
        global_store.saveIfDirty();
        return try gpa.dupe(u8, "{\"type\":\"COMMIT_OK\"}\n");
    } else if (std.mem.eql(u8, type_str, "ROLLBACK")) {
        state.txn_manager.rollbackTransaction() catch {
            return try gpa.dupe(u8, "{\"status_class\":\"25000\",\"error\":\"Failed to rollback transaction\"}\n");
        };
        return try gpa.dupe(u8, "{\"type\":\"ROLLBACK_OK\"}\n");
    } else {
        return try std.fmt.allocPrint(gpa, "{{\"status_class\":\"42000\",\"error\":\"Unknown message type: {s}\"}}\n", .{type_str});
    }
}
