const std = @import("std");
const geode = @import("geode");
const quic_transport = @import("transport/quic");
const query_plan_cache = geode.query_plan_cache;
const query_traits = geode.query_traits;
const explain_payload = geode.explain_payload;
const profile_payload = geode.profile_payload;
const ServerState = geode.server_state.ServerState;
const CatalogSchema = geode.server_state.CatalogSchema;
const CatalogGraph = geode.server_state.CatalogGraph;
const execution = geode.execution;
const server_flags = geode.server_flags;
const graph_store = geode.graph_store;
const proto_util = geode.proto_util;
const gql_print = geode.printer;
const gql_ast = geode.gql.ast;
const backup_manager = geode.backup_manager;
const SimplifiedBackupManager = backup_manager.SimplifiedBackupManager;
const BackupConfig = @import("storage/backup").BackupConfig;
const txn_undo_log = geode.txn_undo_log;
const diagnostics = geode.diagnostics;
const user_mgmt = geode.user_management;
// Note: query_ast_cache type is opaque to avoid circular dependency with lib.zig
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

const schema = @import("schema");
const protobuf = @import("protobuf");

/// Build a protobuf error response with status and error payload
fn buildErrorResponse(
    allocator: std.mem.Allocator,
    status_class: []const u8,
    message: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
) !schema.ExecutionResponse {
    const status = try proto_util.buildStatusFull(allocator, status_class, additional_statuses, flagger_findings);
    return .{
        .status = status,
        .payload = .{
            .@"error" = .{
                .code = try allocator.dupe(u8, status_class),
                .message = try allocator.dupe(u8, message),
                .type = try allocator.dupe(u8, "ERROR"),
                .anchor = try allocator.dupe(u8, ""),
            },
        },
    };
}

/// Write a length-prefixed protobuf ServerPacket to the stream
fn writeServerPacket(allocator: std.mem.Allocator, stream: *quic_transport.QuicStream, packet: schema.ServerPacket) !void {
    // Encode the packet to protobuf bytes
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch return error.OutOfMemory;
    defer aw.deinit();

    try protobuf.encode(&aw.writer, allocator, packet);

    const msg_bytes = aw.writer.buffer[0..aw.writer.end];
    const msg_len: u32 = @intCast(msg_bytes.len);

    // Write 4-byte big-endian length prefix
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, msg_len, .big);
    _ = try stream.write(&len_buf);

    // Write the protobuf bytes
    _ = try stream.write(msg_bytes);
}

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
            .buffer = std.ArrayList(u8){},
        };
    }

    pub fn deinit(self: *BufferedProtoReader) void {
        self.buffer.deinit(self.allocator);
    }

    // Reads the next length-prefixed message.
    // Length is 4 bytes Big Endian.
    pub fn nextMessage(self: *BufferedProtoReader) !?schema.ClientPacket {
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
                    var reader: std.Io.Reader = .fixed(msg_bytes);
                    const msg = protobuf.decode(schema.ClientPacket, &reader, self.allocator) catch |err| {
                        log.warn("Failed to decode Protobuf message", &.{Attr.err("error", err)});
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
                    // Note: Do NOT call transport.poll() here - it's not thread-safe
                    // The main accept loop handles polling; we just wait for data
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

fn sendQuicMessage(allocator: std.mem.Allocator, stream: *quic_transport.QuicStream, msg: schema.QuicServerMessage) !void {
    var msg_copy = msg;
    defer msg_copy.deinit(allocator);
    try writeServerPacket(allocator, stream, .{ .quic = msg_copy });
}

fn sendExecuteError(
    allocator: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    status_class: []const u8,
    message: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
) !void {
    const resp = try buildErrorResponse(allocator, status_class, message, additional_statuses, flagger_findings);
    try sendQuicMessage(allocator, stream, .{ .execute = resp });
}

fn sendPullError(
    allocator: std.mem.Allocator,
    stream: *quic_transport.QuicStream,
    status_class: []const u8,
    message: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
) !void {
    const resp = try buildErrorResponse(allocator, status_class, message, additional_statuses, flagger_findings);
    try sendQuicMessage(allocator, stream, .{ .pull = .{ .response = resp } });
}

fn appendFlagIfMissing(allocator: std.mem.Allocator, flags: *std.ArrayList([]const u8), flag: []const u8) !void {
    for (flags.items) |existing| {
        if (std.mem.eql(u8, existing, flag)) return;
    }
    try flags.append(allocator, flag);
}

// Append a flag to an ExecutionResult, duplicating if the result owns memory
fn appendFlagToResult(allocator: std.mem.Allocator, result: *execution.ExecutionResult, flag: []const u8) !void {
    for (result.flags.items) |existing| {
        if (std.mem.eql(u8, existing, flag)) return;
    }
    // Duplicate flag if result owns memory, otherwise string literal is fine
    const flag_to_add = if (result.owns_value_memory) try allocator.dupe(u8, flag) else flag;
    try result.flags.append(allocator, flag_to_add);
}

/// Extract variable name and property name from a property access expression.
/// Handles both PropertyAccess (object.property) and Member (Ident.field) forms.
fn extractVarProperty(expr: gql_ast.Expr) ?struct { variable: []const u8, property: []const u8 } {
    if (expr == .PropertyAccess) {
        const pa = expr.PropertyAccess;
        return .{ .variable = pa.object, .property = pa.property };
    }
    if (expr == .Member) {
        const m = expr.Member;
        if (m.target.* == .Ident) {
            return .{ .variable = m.target.Ident.orig, .property = m.field };
        }
    }
    return null;
}

/// Check if a WHERE clause contains an equality predicate on a property
/// that matches a catalog index for the given label and variable name.
fn whereHasIndexedEq(where_expr: gql_ast.Expr, var_name: []const u8, label: []const u8, cat: anytype) bool {
    switch (where_expr) {
        .Binary => |bin| {
            if (bin.op == .And) {
                if (whereHasIndexedEq(bin.left.*, var_name, label, cat)) return true;
                if (whereHasIndexedEq(bin.right.*, var_name, label, cat)) return true;
                return false;
            } else if (bin.op == .Eq) {
                const prop_name = blk: {
                    if (extractVarProperty(bin.left.*)) |vp| {
                        if (std.mem.eql(u8, vp.variable, var_name)) break :blk vp.property;
                    }
                    if (extractVarProperty(bin.right.*)) |vp| {
                        if (std.mem.eql(u8, vp.variable, var_name)) break :blk vp.property;
                    }
                    break :blk @as(?[]const u8, null);
                };
                if (prop_name) |pn| {
                    var idx_iter = cat.indexes.valueIterator();
                    while (idx_iter.next()) |info| {
                        if (std.mem.eql(u8, info.table_name, label) and
                            info.columns.len > 0 and
                            std.mem.eql(u8, info.columns[0], pn)) return true;
                    }
                }
                return false;
            }
            return false;
        },
        else => return false,
    }
}

fn findOrderBy(program: *const gql_ast.Program) ?*const gql_ast.OrderBy {
    var idx: usize = program.statements.len;
    while (idx > 0) : (idx -= 1) {
        const stmt_ptr = &program.statements[idx - 1];
        switch (stmt_ptr.*) {
            .Query => |*q| {
                if (q.order_by) |*ob| return ob;
                return null;
            },
            .Union => |*u| {
                if (u.order_by) |ob_ptr| return ob_ptr;
                return null;
            },
            .StartTransaction, .Commit, .Rollback => continue,
            else => return null,
        }
    }
    return null;
}

fn buildOrderKeys(
    allocator: std.mem.Allocator,
    order_by: *const gql_ast.OrderBy,
    result: *const execution.ExecutionResult,
) ![]const []const u8 {
    var keys = try allocator.alloc([]const u8, order_by.keys.len);
    var i: usize = 0;
    while (i < order_by.keys.len) : (i += 1) {
        const expr = order_by.keys[i].expr;
        if (expr == .Int) {
            const ordinal = expr.Int;
            if (ordinal > 0 and @as(usize, @intCast(ordinal)) <= result.columns.len) {
                keys[i] = try allocator.dupe(u8, result.columns[@intCast(ordinal - 1)]);
                continue;
            }
        }
        keys[i] = try gql_print.stringifyExprAlloc(allocator, expr, .{});
    }
    return keys;
}

const DEBUG_PROFILE = false;

// CANARY: REQ=REQ-ABAC-WIRE-013; FEATURE="ABAC Enforcement"; ASPECT=QUICHandler; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Updated handleQuicConnection signature to accept SecurityManager for ABAC enforcement
pub fn handleQuicConnection(
    gpa: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    env_spill_threshold: usize,
    env_storage_checksum_error: bool,
    _force_serialization_failure_unused: bool,
    security_manager: ?*geode_auth.SecurityManager,
    shared_ast_cache: ?*anyopaque, // Type is query_ast_cache.SharedAstCache
) !void {
    _ = _force_serialization_failure_unused;
    // CANARY: REQ=REQ-QUIC-CONN-CLEANUP-003; FEATURE="ConnectionMemoryManagement"; ASPECT=ProperCleanup; STATUS=EXEMPT; OWNER=server; UPDATED=2025-12-27
    // Use destroyConnection to properly remove from transport list, close, and free resources
    defer transport.destroyConnection(conn);
    log.debug("Entering handleQuicConnection", &.{});

    // Wait for incoming STREAM frames using a simple retry loop
    // Note: transport.poll() is NOT thread-safe and must only be called from the main accept loop
    // The main accept loop's poll() already processes incoming packets, so streams should be queued
    // GAP-0200-FIX: Increased timeout from 50ms to 500ms to handle slower clients
    // and network latency. The accept() function now waits longer for streams before
    // returning, but we still need this as a fallback.
    var poll_attempts: usize = 0;
    while (poll_attempts < 500) : (poll_attempts += 1) {
        if (conn.inner.hasIncomingStreams()) break;
        std.Thread.sleep(1 * std.time.ns_per_ms); // Sleep 1ms and check again
        if (poll_attempts > 0 and poll_attempts % 100 == 0) {
            log.debug("No streams yet, retrying", &.{
                Attr.int("attempt", @intCast(poll_attempts + 1)),
                Attr.int("max_attempts", 500),
            });
        }
    }

    // Accept a stream for the protocol communication
    log.debug("Attempting to accept stream", &.{});
    const stream = try conn.acceptStream();
    log.debug("Stream accepted successfully", &.{});
    defer stream.close();

    // Initialize state
    var state = ServerState{
        .allocator = gpa,
    };
    state.exec_session = execution.SessionState.init(gpa);
    state.telemetry_paging = if (std.process.getEnvVarOwned(gpa, "GEODE_TELEMETRY_PAGING")) |v| blk: {
        defer gpa.free(v);
        break :blk true;
    } else |_| false;
    state.txn_manager.init(gpa);
    state.inserted_values = .{};
    state.catalog_schemas = std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.catalog_graphs = std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.graph_types = std.HashMap([]const u8, geode.server_state.GraphTypeDefinition, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.query_mem_limit_bytes = env_spill_threshold;
    state.storage_checksum_error = env_storage_checksum_error;
    // CANARY: REQ=REQ-ABAC-WIRE-014; FEATURE="ABAC Enforcement"; ASPECT=QUICState; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Wire SecurityManager into ServerState for QUIC connection ABAC enforcement
    state.security_manager = security_manager;

    // Initialize evaluator callbacks for execution engine.
    execution.initEvaluator();

    // Ensure cleanup of per-connection state.
    defer {
        state.resetResult();
        if (state.exec_session) |*sess| sess.deinit();
        if (state.session_config) |*cfg| cfg.deinit();
        if (state.authenticated_user) |u| gpa.free(u);
        if (state.authenticated_password) |p| gpa.free(p);
        state.txn_manager.deinit();
        for (state.inserted_values.items) |item| {
            state.allocator.free(item.value);
        }
        state.inserted_values.deinit(state.allocator);
        state.catalog_schemas.deinit();
        state.catalog_graphs.deinit();
        var gt_iter = state.graph_types.iterator();
        while (gt_iter.next()) |entry| {
            state.allocator.free(entry.key_ptr.*);
            state.allocator.free(entry.value_ptr.name);
        }
        state.graph_types.deinit();
    }

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

    // Protobuf protocol only - use protobuf reader
    var line_reader = try BufferedProtoReader.init(gpa, transport, stream);
    defer line_reader.deinit();

    while (true) {
        const packet_opt = line_reader.nextMessage() catch |err| {
            if (err == error.EndOfStream) return;
            if (err == error.WouldBlock) {
                // Note: Do NOT call transport.poll() here - it's not thread-safe
                // The main accept loop handles polling; just sleep and retry
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            log.err("Protobuf read error", &.{Attr.err("error", err)});
            return err;
        };

        if (packet_opt == null) return; // EOF
        var packet = packet_opt.?;
        defer packet.deinit(gpa);

        const msg = packet.quic orelse {
            log.err("Received empty ClientPacket", &.{});
            try sendExecuteError(gpa, stream, "58000", "Empty packet", &.{}, &.{});
            continue;
        };

        // Process protobuf message and emit responses directly
        handleClientMessage(gpa, &state, stream, msg, disable_estimates, compact_profile, memcurve_profile) catch |err| {
            log.err("Protobuf process error", &.{Attr.err("error", err)});
            try sendExecuteError(gpa, stream, "58000", "Internal Server Error", &.{}, &.{});
            continue;
        };
    }
}

fn updateTxnStateFromProgram(state: *ServerState, program: *const gql_ast.Program) void {
    var has_start: bool = false;
    var has_commit: bool = false;
    var has_rollback: bool = false;

    for (program.statements) |stmt| {
        switch (stmt) {
            .StartTransaction => |st| {
                if (st.body == null) has_start = true;
            },
            .Commit => has_commit = true,
            .Rollback => has_rollback = true,
            else => {},
        }
    }

    if (has_commit or has_rollback) {
        state.in_txn = false;
        state.txn_id = 0;
        return;
    }

    if (has_start) {
        state.in_txn = true;
        if (state.txn_id == 0) {
            state.txn_id = @intCast(std.time.milliTimestamp());
        }
    }
}

fn handleClientMessage(
    gpa: std.mem.Allocator,
    state: *ServerState,
    stream: *quic_transport.QuicStream,
    msg: schema.QuicClientMessage,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
) !void {
    switch (msg) {
        .hello => |hello_req| {
            var caps = std.ArrayList([]const u8).initCapacity(gpa, 3) catch return error.OutOfMemory;
            try caps.append(gpa, try gpa.dupe(u8, "QUIC"));
            try caps.append(gpa, try gpa.dupe(u8, "TLS1.3"));
            try caps.append(gpa, try gpa.dupe(u8, "PROTOBUF"));

            if (user_mgmt.isAuthEnabled()) {
                if (hello_req.username.len == 0 or hello_req.password.len == 0) {
                    const resp = schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = try gpa.dupe(u8, ""),
                        .error_message = try gpa.dupe(u8, "Authentication required"),
                        .capabilities = caps,
                    } };
                    try sendQuicMessage(gpa, stream, resp);
                    return;
                }

                const role = user_mgmt.authenticate(hello_req.username, hello_req.password) catch {
                    const resp = schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = try gpa.dupe(u8, ""),
                        .error_message = try gpa.dupe(u8, "Authentication failed"),
                        .capabilities = caps,
                    } };
                    try sendQuicMessage(gpa, stream, resp);
                    return;
                };

                if (state.authenticated_user) |u| gpa.free(u);
                if (state.authenticated_password) |p| gpa.free(p);
                state.authenticated_user = try gpa.dupe(u8, hello_req.username);
                state.authenticated_password = try gpa.dupe(u8, hello_req.password);
                state.authenticated_role = @intFromEnum(role);
            }

            if (hello_req.tenant_id) |tenant| {
                if (state.session_config == null) {
                    state.session_config = geode.server_state.SessionConfiguration.init(gpa);
                }
                if (state.session_config.?.tenant_id) |old| {
                    gpa.free(old);
                }
                state.session_config.?.tenant_id = try gpa.dupe(u8, tenant);
            }

            const session_id = try std.fmt.allocPrint(gpa, "sess_{d}", .{std.time.milliTimestamp()});
            const resp = schema.QuicServerMessage{ .hello = .{
                .success = true,
                .session_id = session_id,
                .error_message = try gpa.dupe(u8, ""),
                .capabilities = caps,
            } };
            try sendQuicMessage(gpa, stream, resp);
        },
        .execute => |exec_req| {
            log.info("PROTOBUF .execute received", &.{
                Attr.int("query_len", @intCast(exec_req.query.len)),
            });

            state.resetResult();

            if (user_mgmt.isAuthEnabled() and state.authenticated_user == null) {
                try sendExecuteError(gpa, stream, "28000", "Authentication required", &.{}, &.{});
                return;
            }

            const bindings = proto_util.parseParams(gpa, exec_req.params.items) catch |err| {
                const err_msg = @errorName(err);
                try sendExecuteError(gpa, stream, "22023", err_msg, &.{}, &.{});
                return;
            };
            defer proto_util.freeParamBindings(gpa, bindings);

            const order_keys_expr = server_flags.getOrderKeysExpr();
            const parse_opts = geode.ParseOptions{
                .ident_order_only = !order_keys_expr,
                .forbid_orderby_calls = !order_keys_expr,
            };

            var normalized = try query_traits.normalizeExplainCalibrated(gpa, exec_req.query);
            defer normalized.deinit(gpa);

            const query_text = normalized.text;
            if (state.query_text) |qt| gpa.free(qt);
            state.query_text = try gpa.dupe(u8, query_text);

            const outcome = try geode.parseGqlOutcome(query_text, gpa, parse_opts);
            switch (outcome) {
                .Err => |err_info| {
                    const err_msg = if (err_info.has_double_dash_comment)
                        diagnostics.defaultMessage(.GB02CommentDisabled)
                    else
                        err_info.msg;
                    try sendExecuteError(gpa, stream, "42000", err_msg, &.{}, &.{});
                    return;
                },
                .Ok => |parse_result_const| {
                    var parse_result = parse_result_const;
                    defer parse_result.deinit();

                    if (parse_result.has_double_dash_comment) {
                        try sendExecuteError(gpa, stream, "42000", diagnostics.defaultMessage(.GB02CommentDisabled), &.{}, &.{});
                        return;
                    }

                    const analysis = query_traits.analyzeProgram(&parse_result.program);
                    var traits = analysis.traits;
                    const ordered = traits.ordered;
                    const distinct = traits.distinct;
                    const heur_index = traits.has_where_eq or traits.has_filter_eq;

                    const role = if (state.authenticated_role) |role_u8|
                        @as(user_mgmt.Role, @enumFromInt(role_u8))
                    else
                        null;

                    const catalog = try execution.ensureCatalogInstance(gpa);

                    // Detect index-seek for EXPLAIN: check if query's node pattern
                    // matches a catalog index (label + property equality)
                    if (analysis.kind == .explain) {
                        if (analysis.target) |target| {
                            if (target.* == .Query) {
                                const q = target.Query;
                                if (q.match.chains.len > 0) {
                                    const head_opt = q.match.chains[0].head;
                                    if (head_opt) |head| {
                                        if (head.labels.len > 0) {
                                            const label = head.labels[0];
                                            // Check inline properties
                                            if (head.props) |props| {
                                                if (props.len > 0) {
                                                    const prop_name = props[0].key;
                                                    catalog.rwlock.lockShared();
                                                    defer catalog.rwlock.unlockShared();
                                                    var idx_iter = catalog.indexes.valueIterator();
                                                    while (idx_iter.next()) |info| {
                                                        if (std.mem.eql(u8, info.table_name, label) and
                                                            info.columns.len > 0 and
                                                            std.mem.eql(u8, info.columns[0], prop_name))
                                                        {
                                                            traits.has_index_seek = true;
                                                            break;
                                                        }
                                                    }
                                                }
                                            }
                                            // Check WHERE clause for equality on indexed property
                                            if (!traits.has_index_seek) {
                                                if (q.where_clause) |where_expr| {
                                                    if (head.name) |vn| {
                                                        catalog.rwlock.lockShared();
                                                        defer catalog.rwlock.unlockShared();
                                                        traits.has_index_seek = whereHasIndexedEq(where_expr, vn, label, catalog);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    const exec_context = execution.ExecutionContext{
                        .catalog = catalog,
                        .user = state.authenticated_user,
                        .role = role,
                        .token = null,
                        .strict_offset_validation = false,
                        .session_state = if (state.exec_session) |*s| s else null,
                        .transaction_state = if (state.in_txn) .Active else .None,
                        .query_param_names = bindings.names,
                        .query_param_values = bindings.values,
                    };

                    var flags = std.ArrayList([]const u8).initCapacity(gpa, 8) catch return error.OutOfMemory;
                    defer flags.deinit(gpa);
                    const base_flags = server_flags.computeBaseFlags(ordered, distinct);
                    for (base_flags) |flag| {
                        try appendFlagIfMissing(gpa, &flags, flag);
                    }
                    if (traits.has_union) {
                        try appendFlagIfMissing(gpa, &flags, server_flags.F_UNION_PHASES);
                    }
                    if (heur_index) {
                        try appendFlagIfMissing(gpa, &flags, server_flags.F_HEUR_INDEX);
                    }
                    if (parse_result.has_double_solidus_comment) {
                        try appendFlagIfMissing(gpa, &flags, "GB03:DoubleSolidusComment");
                    }

                    switch (analysis.kind) {
                        .explain => {
                            const explain_msg = try explain_payload.buildExplainPayload(
                                gpa,
                                traits,
                                analysis.union_part_count,
                                normalized.explain_calibrated,
                            );

                            const status = try proto_util.buildStatus(gpa, "00000", flags.items);
                            const resp = schema.ExecutionResponse{
                                .status = status,
                                .payload = .{ .explain = explain_msg },
                            };
                            try sendQuicMessage(gpa, stream, .{ .execute = resp });
                        },
                        .profile => {
                            const target_stmt = analysis.target orelse {
                                try sendExecuteError(gpa, stream, "0A000", "PROFILE target missing", &.{}, &.{});
                                return;
                            };
                            var exec_result = execution.executeStatementWithContext(gpa, target_stmt.*, exec_context) catch |err| {
                                const info = proto_util.mapError(err);
                                try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                                return;
                            };
                            defer exec_result.deinit(gpa);

                            for (flags.items) |flag| {
                                try appendFlagToResult(gpa, &exec_result, flag);
                            }

                            const store = graph_store.getGlobalStore(gpa);
                            const profile_msg = try profile_payload.buildProfilePayload(gpa, traits, exec_result.rows.len, .{
                                .compact = compact_profile,
                                .include_mem_curve = memcurve_profile,
                                .disable_estimates = disable_estimates,
                                .spill_threshold = state.query_mem_limit_bytes,
                                .committed_txns = state.global_commit_ts,
                                .graph_store_nodes = @intCast(store.getNodeCount()),
                                .graph_store_edges = @intCast(store.getEdgeCount()),
                                .graph_store_dirty = store.isDirty(),
                                .flagger_findings = exec_result.flags.items,
                                .union_part_count = analysis.union_part_count,
                            });

                            const status = try proto_util.buildStatus(gpa, "00000", exec_result.flags.items);
                            const resp = schema.ExecutionResponse{
                                .status = status,
                                .payload = .{ .profile = profile_msg },
                            };
                            try sendQuicMessage(gpa, stream, .{ .execute = resp });

                            if (!state.in_txn) {
                                const global_store = graph_store.getGlobalStore(gpa);
                                global_store.saveIfDirty();
                            }
                        },
                        .rows => {
                            var exec_result = execution.executeProgramWithContext(gpa, &parse_result.program, exec_context) catch |err| {
                                const info = proto_util.mapError(err);
                                try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                                return;
                            };
                            var store_result = false;
                            defer if (!store_result) exec_result.deinit(gpa);

                            for (flags.items) |flag| {
                                try appendFlagToResult(gpa, &exec_result, flag);
                            }

                            var order_keys: []const []const u8 = &.{};
                            defer if (!store_result) {
                                for (order_keys) |key| gpa.free(key);
                                if (order_keys.len > 0) gpa.free(order_keys);
                            };
                            if (ordered) {
                                if (findOrderBy(&parse_result.program)) |ob| {
                                    order_keys = try buildOrderKeys(gpa, ob, &exec_result);
                                }
                            }

                            const status = try proto_util.buildStatus(gpa, "00000", exec_result.flags.items);
                            const schema_def = try proto_util.buildSchemaDefinition(gpa, &exec_result);
                            const schema_resp = schema.ExecutionResponse{
                                .status = status,
                                .payload = .{ .schema = schema_def },
                            };
                            try sendQuicMessage(gpa, stream, .{ .execute = schema_resp });

                            var sent_rows: usize = 0;
                            var page_final = false;
                            if (state.inline_results_enabled) {
                                const inline_max = if (state.inline_results_max_rows == 0) exec_result.rows.len else state.inline_results_max_rows;
                                const page = try proto_util.buildDataPage(gpa, &exec_result, 0, inline_max, ordered, order_keys);
                                sent_rows = page.rows.items.len;
                                page_final = page.final;
                                const page_status = try proto_util.buildStatus(gpa, "00000", exec_result.flags.items);
                                const page_resp = schema.ExecutionResponse{
                                    .status = page_status,
                                    .payload = .{ .page = page },
                                };
                                try sendQuicMessage(gpa, stream, .{ .execute = page_resp });
                            }

                            if (!state.inline_results_enabled or !page_final) {
                                store_result = true;
                                state.active_result_values = exec_result;
                                state.active_result = true;
                                state.result_page_index = if (state.inline_results_enabled) sent_rows else 0;
                                state.result_ordered = ordered;
                                state.result_order_keys = order_keys;
                            }

                            updateTxnStateFromProgram(state, &parse_result.program);

                            if (!state.in_txn) {
                                const global_store = graph_store.getGlobalStore(gpa);
                                global_store.saveIfDirty();
                            }
                        },
                    }
                },
            }
        },
        .pull => |pull_req| {
            if (state.active_result_values == null) {
                try sendPullError(gpa, stream, "02000", "no active result set", &.{}, &.{});
                return;
            }

            const page_size = pull_req.page_size;
            const start = state.result_page_index;
            const result = &state.active_result_values.?;
            const page = try proto_util.buildDataPage(gpa, result, start, page_size, state.result_ordered, state.result_order_keys);
            state.result_page_index = start + page.rows.items.len;

            if (state.telemetry_paging) {
                var ps_buf: [32]u8 = undefined;
                const ps_str = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
                var rows_buf: [32]u8 = undefined;
                const rows_str = std.fmt.bufPrint(&rows_buf, "{d}", .{page.rows.items.len}) catch "0";
                log.info("telemetry", &.{
                    Attr.string("type", "TELEMETRY"),
                    Attr.string("event", "PULL_PAGE"),
                    Attr.string("page_size", ps_str),
                    Attr.string("rows_emitted", rows_str),
                    Attr.string("final", if (page.final) "true" else "false"),
                });
            }

            const status = try proto_util.buildStatus(gpa, "00000", result.flags.items);
            const resp = schema.ExecutionResponse{
                .status = status,
                .payload = .{ .page = page },
            };
            try sendQuicMessage(gpa, stream, .{ .pull = .{ .response = resp } });

            if (page.final) {
                state.resetResult();
            }
        },
        .ping => |_| {
            try sendQuicMessage(gpa, stream, .{ .ping = .{ .ok = true } });
        },
        .begin => |bg| {
            _ = bg;
            if (state.in_txn) {
                try sendQuicMessage(gpa, stream, .{ .begin = .{ .session_id = try gpa.dupe(u8, ""), .tx_id = try gpa.dupe(u8, "") } });
                return;
            }

            state.in_txn = true;
            state.txn_id = @intCast(std.time.milliTimestamp());
            state.session_snapshot_ts = state.global_commit_ts;
            txn_undo_log.getGlobalUndoLog(gpa).begin();

            const tx_id_str = try std.fmt.allocPrint(gpa, "{d}", .{state.txn_id});
            try sendQuicMessage(gpa, stream, .{ .begin = .{ .session_id = try gpa.dupe(u8, "sess"), .tx_id = tx_id_str } });
        },
        .commit => |_| {
            if (state.in_txn) {
                txn_undo_log.getGlobalUndoLog(gpa).commit();
                state.global_commit_ts += 1;
                state.in_txn = false;
                state.txn_id = 0;
                const global_store = graph_store.getGlobalStore(gpa);
                global_store.saveIfDirty();
                try sendQuicMessage(gpa, stream, .{ .commit = .{ .success = true } });
            } else {
                try sendQuicMessage(gpa, stream, .{ .commit = .{ .success = false } });
            }
        },
        .rollback => |_| {
            if (state.in_txn) {
                const store = graph_store.getGlobalStore(gpa);
                txn_undo_log.getGlobalUndoLog(gpa).rollback(store) catch |err| {
                    log.err("Rollback failed", &.{Attr.err("error", err)});
                };
                state.in_txn = false;
                state.txn_id = 0;
                const global_store = graph_store.getGlobalStore(gpa);
                global_store.saveIfDirty();
                try sendQuicMessage(gpa, stream, .{ .rollback = .{ .success = true } });
            } else {
                try sendQuicMessage(gpa, stream, .{ .rollback = .{ .success = false } });
            }
        },
        .savepoint => |_| {
            try sendQuicMessage(gpa, stream, .{ .savepoint = .{ .success = false } });
        },
        .rollback_to => |_| {
            try sendQuicMessage(gpa, stream, .{ .rollback_to = .{ .success = false } });
        },
        .cdc_diag => |_| {
            if (state.cdc_engine) |eng| {
                const payload = try eng.exportDiagnostics(gpa);
                try sendQuicMessage(gpa, stream, .{ .cdc_diag = payload });
            } else {
                const payload = schema.CdcDiagnosticsResponse{
                    .config = .{ .enabled = false },
                    .engine = .{ .is_running = false },
                    .malformed_snapshots = std.ArrayList(schema.CdcMalformedSnapshot){},
                    .malformed_hashes = std.ArrayList(schema.CdcMalformedHash){},
                    .version = try gpa.dupe(u8, "v0.1.0"),
                    .timestamp_ms = std.time.milliTimestamp(),
                };
                try sendQuicMessage(gpa, stream, .{ .cdc_diag = payload });
            }
        },
        .cdc_ctrl => |ctrl| {
            if (state.cdc_engine) |eng| {
                if (std.ascii.eqlIgnoreCase(ctrl.action, "RESET_GUARDRAILS")) {
                    eng.resetGuardrailState();
                    try sendQuicMessage(gpa, stream, .{ .cdc_ctrl = .{ .success = true, .status = try gpa.dupe(u8, "OK"), .guardrail_epoch = eng.guardrail_epoch } });
                } else {
                    try sendQuicMessage(gpa, stream, .{ .cdc_ctrl = .{ .success = false, .status = try gpa.dupe(u8, "UNSUPPORTED"), .guardrail_epoch = eng.guardrail_epoch } });
                }
            } else {
                try sendQuicMessage(gpa, stream, .{ .cdc_ctrl = .{ .success = false, .status = try gpa.dupe(u8, "NO_ENGINE"), .guardrail_epoch = 0 } });
            }
        },
        .backup => |backup_req| {
            const backup_dir = "./server_backups";
            const backup_config = BackupConfig{
                .compression = if (backup_req.compress) .zstd else .none,
                .encryption = false,
                .retention_days = 30,
            };

            var mgr = SimplifiedBackupManager.init(gpa, backup_dir, backup_config) catch |err| {
                const msg_text = try std.fmt.allocPrint(gpa, "Backup init failed: {s}", .{@errorName(err)});
                try sendQuicMessage(gpa, stream, .{ .backup = .{ .success = false, .message = msg_text } });
                return;
            };
            defer mgr.deinit();

            const metadata = if (std.ascii.eqlIgnoreCase(backup_req.backup_type, "full"))
                (mgr.createFullBackup() catch |err| {
                    const msg_text = try std.fmt.allocPrint(gpa, "Backup failed: {s}", .{@errorName(err)});
                    try sendQuicMessage(gpa, stream, .{ .backup = .{ .success = false, .message = msg_text } });
                    return;
                })
            else {
                const msg_text = try gpa.dupe(u8, "Only full backups are supported with GraphStore");
                try sendQuicMessage(gpa, stream, .{ .backup = .{ .success = false, .message = msg_text } });
                return;
            };

            const backup_id = try std.fmt.allocPrint(gpa, "{x}", .{metadata.backup_id});
            const backup_type = try gpa.dupe(u8, @tagName(metadata.backup_type));
            const compression = try gpa.dupe(u8, @tagName(metadata.compression));
            const checksum = try std.fmt.allocPrint(gpa, "{x}", .{metadata.checksum});
            try sendQuicMessage(gpa, stream, .{ .backup = .{
                .success = true,
                .message = try gpa.dupe(u8, "Backup completed successfully"),
                .backup_id = backup_id,
                .backup_type = backup_type,
                .size_bytes = metadata.size_bytes,
                .compression = compression,
                .checksum = checksum,
            } });

            // Stream backup file bytes after sending metadata response.
            if (metadata.size_bytes > 0) {
                const backup_path = try std.fmt.allocPrint(gpa, "{s}/full_{x}.backup", .{ backup_dir, metadata.backup_id });
                defer gpa.free(backup_path);

                if (std.fs.cwd().openFile(backup_path, .{})) |file| {
                    defer file.close();
                    var buf: [65536]u8 = undefined;
                    var remaining: u64 = metadata.size_bytes;
                    while (remaining > 0) {
                        const chunk = @min(remaining, buf.len);
                        const n = file.read(buf[0..chunk]) catch |err| {
                            log.err("Failed to read backup file", &.{
                                Attr.string("path", backup_path),
                                Attr.err("error", err),
                            });
                            break;
                        };
                        if (n == 0) break;
                        _ = stream.write(buf[0..n]) catch |err| {
                            log.err("Failed to stream backup bytes", &.{
                                Attr.string("path", backup_path),
                                Attr.err("error", err),
                            });
                            break;
                        };
                        remaining -= n;
                    }
                } else |err| {
                    log.err("Backup file missing for streaming", &.{
                        Attr.string("path", backup_path),
                        Attr.err("error", err),
                    });
                }
            }
        },
        .restore => |restore_req| {
            if (!restore_req.confirm) {
                const msg_text = try gpa.dupe(u8, "Restore requires confirmation");
                try sendQuicMessage(gpa, stream, .{ .restore = .{ .success = false, .message = msg_text } });
                return;
            }

            const backup_config = BackupConfig{
                .compression = .zstd,
                .encryption = false,
                .retention_days = 30,
            };
            var mgr = SimplifiedBackupManager.init(gpa, "./server_backups", backup_config) catch |err| {
                const msg_text = try std.fmt.allocPrint(gpa, "Restore init failed: {s}", .{@errorName(err)});
                try sendQuicMessage(gpa, stream, .{ .restore = .{ .success = false, .message = msg_text } });
                return;
            };
            defer mgr.deinit();

            const target_time: i64 = if (restore_req.target_time.len > 0)
                std.fmt.parseInt(i64, restore_req.target_time, 10) catch std.time.milliTimestamp()
            else
                std.time.milliTimestamp();

            const restore_dir = if (std.process.getEnvVarOwned(gpa, "GEODE_DATA_DIR")) |dir| blk: {
                defer gpa.free(dir);
                break :blk try gpa.dupe(u8, dir);
            } else |_| try gpa.dupe(u8, "./data");

            mgr.restoreToPointInTime(target_time, restore_dir) catch |err| {
                const msg_text = try std.fmt.allocPrint(gpa, "Restore failed: {s}", .{@errorName(err)});
                try sendQuicMessage(gpa, stream, .{ .restore = .{ .success = false, .message = msg_text } });
                gpa.free(restore_dir);
                return;
            };

            const ts = std.time.milliTimestamp();
            try sendQuicMessage(gpa, stream, .{ .restore = .{
                .success = true,
                .message = try gpa.dupe(u8, "Restore completed"),
                .restore_dir = restore_dir,
                .target_time = try gpa.dupe(u8, if (restore_req.target_time.len > 0) restore_req.target_time else "latest"),
                .restore_timestamp = @intCast(ts),
            } });
        },
        .upload_backup => |upload_req| {
            if (upload_req.size_bytes == 0 or upload_req.checksum.len == 0) {
                try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = false, .message = try gpa.dupe(u8, "Invalid upload request") } });
                return;
            }

            std.fs.cwd().makePath("./uploaded_backups") catch {};
            const path = try std.fmt.allocPrint(gpa, "./uploaded_backups/backup_{d}.bin", .{std.time.milliTimestamp()});
            // Create empty placeholder file
            if (std.fs.cwd().createFile(path, .{})) |file| {
                file.close();
            } else |_| {}

            try sendQuicMessage(gpa, stream, .{ .upload_backup = .{ .success = true, .message = try gpa.dupe(u8, "Upload slot ready"), .upload_path = path } });
        },
    }
}
