const std = @import("std");
const builtin = @import("builtin");
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
// Issue #444: Import AST cache to wire into parse hot path
const query_ast_cache = @import("query_ast_cache.zig");
// CANARY: REQ=REQ-ABAC-WIRE-012; FEATURE="ABAC Enforcement"; ASPECT=QUICImport; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Import geode_auth for SecurityManager type in QUIC connection handling
const geode_auth = @import("geode_auth");
// GAP-0258: Import mTLS provider for QUIC client certificate authentication
const mtls_provider = geode.mtls_provider;

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

// GAP-0258: Global mTLS provider for QUIC certificate authentication
// CANARY: REQ=REQ-AUTH-MTLS-QUIC-004; FEATURE="mTLS over QUIC"; ASPECT=GlobalProvider; STATUS=IMPL; OWNER=security; UPDATED=2026-02-13
var g_mtls_provider: ?*mtls_provider.MtlsProvider = null;

// S6: Per-IP authentication rate limiter — prevents brute-force attacks on QUIC HELLO.
// CANARY: REQ=REQ-SEC-RATE-LIMIT-003; FEATURE="AuthRateLimiting"; ASPECT=GlobalInstance; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
const auth_rate_limiter = @import("auth_rate_limiter.zig");
var g_auth_rate_limiter: ?*auth_rate_limiter.AuthRateLimiter = null;

// S1: Post-execution RLS filter — removes result rows containing denied labels.
// CANARY: REQ=REQ-SEC-RLS-WIRE-002; FEATURE="RLS Query Enforcement"; ASPECT=QUICImport; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
const rls_filter = @import("rls_filter.zig");

/// Set the global mTLS provider (called from server/main.zig during startup)
pub fn setMtlsProvider(provider: ?*mtls_provider.MtlsProvider) void {
    g_mtls_provider = provider;
}

/// Get the current global mTLS provider
pub fn getMtlsProvider() ?*mtls_provider.MtlsProvider {
    return g_mtls_provider;
}

/// Set the global authentication rate limiter (called from server/main.zig during startup).
/// CANARY: REQ=REQ-SEC-RATE-LIMIT-004; FEATURE="AuthRateLimiting"; ASPECT=GlobalSetter; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
pub fn setAuthRateLimiter(limiter: ?*auth_rate_limiter.AuthRateLimiter) void {
    g_auth_rate_limiter = limiter;
}

/// Get the current global authentication rate limiter.
pub fn getAuthRateLimiter() ?*auth_rate_limiter.AuthRateLimiter {
    return g_auth_rate_limiter;
}

/// GAP-0001 / #564: Delegate to shared mutation classification in query_traits.
/// These detect inline mutations inside Query nodes (MATCH...CREATE, etc.)
/// that previously only took a shared read lock, causing data races.
const isMutatingStatement = query_traits.isMutatingStatement;

const isMutatingProgram = query_traits.isMutatingProgram;

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
    // Encode the packet to protobuf bytes.
    // GAP-0257: Use 64KB initial capacity to reduce reallocations for large
    // data pages (1000+ row result sets produce 100KB+ encoded protobuf).
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 65536) catch return error.OutOfMemory;
    defer aw.deinit();

    try protobuf.encode(&aw.writer, allocator, packet);

    const msg_bytes = aw.writer.buffer[0..aw.writer.end];
    const msg_len: u32 = @intCast(msg_bytes.len);

    // Write 4-byte big-endian length prefix
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, msg_len, .big);
    try stream.writeAll(&len_buf);

    // Write the protobuf bytes
    try stream.writeAll(msg_bytes);
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
                        log.warn("Failed to decode Protobuf message", &.{Attr.string("error", @errorName(err))});
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
                    // #540: Wait for the dedicated poll thread to deliver data.
                    // Handler threads do NOT call poll(0) themselves — that
                    // contends on ep.mu with 30+ threads and serializes all I/O.
                    // The dedicated pollLoop thread in quic.zig runs at 50μs
                    // intervals and broadcasts poll_cv on every cycle.
                    if (self.stream.poll_sync) |ps| {
                        ps.waitForPoll(2 * std.time.ns_per_ms);
                    } else {
                        std.Thread.sleep(100 * std.time.ns_per_us);
                    }
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

// ── Stream multiplexing support ──────────────────────────────────────────────
// CANARY: REQ=REQ-QUIC-MUX-001; FEATURE="StreamMultiplexing"; ASPECT=SharedConnState; STATUS=IMPL; OWNER=server; UPDATED=2026-03-27
/// Shared connection state for QUIC stream multiplexing.
/// After the HELLO handshake on the first stream, this holds the authenticated
/// identity that is inherited by all additional streams on the connection.
/// Fields are read-only after initialization (set once after HELLO).
pub const SharedConnState = struct {
    allocator: std.mem.Allocator,
    /// Authenticated username (owned, heap-allocated). Null if auth is disabled.
    authenticated_user: ?[]const u8 = null,
    /// Authenticated role (u8 enum value of user_mgmt.Role).
    authenticated_role: ?u8 = null,
    /// Whether the user must reset their password.
    password_reset_required: bool = false,
    /// Session graph binding (owned, heap-allocated). Null if not bound.
    current_graph: ?[]const u8 = null,
    /// Whether the session was bound to a graph via DSN/HELLO.
    graph_bound: bool = false,
    /// Security manager pointer (global lifetime, not owned).
    security_manager: ?*geode_auth.SecurityManager = null,
    /// Shared AST cache pointer (global lifetime, not owned).
    shared_ast_cache: ?*anyopaque = null,
    /// Shared query optimizer pointer (global lifetime, not owned).
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer = null,
    /// Peer IP string for rate limiting (owned if allocated).
    peer_ip: []const u8 = "unknown",
    peer_ip_allocated: bool = false,
    /// Server configuration flags (immutable after init).
    disable_estimates: bool = false,
    compact_profile: bool = false,
    memcurve_profile: bool = false,
    env_spill_threshold: usize = 0,
    env_storage_checksum_error: bool = false,
    /// Number of active streams (including the first one). Used to know when
    /// the connection is idle. Atomic so the acceptor thread and stream handler
    /// threads can update it without a mutex.
    active_streams: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Snapshot shared identity from a fully-initialized ServerState (after HELLO).
    pub fn captureFromState(self: *SharedConnState, state: *const ServerState) !void {
        if (state.authenticated_user) |u| {
            self.authenticated_user = try self.allocator.dupe(u8, u);
        }
        self.authenticated_role = state.authenticated_role;
        self.password_reset_required = state.password_reset_required;
        self.graph_bound = state.graph_bound;
        if (state.exec_session) |sess| {
            if (sess.graph) |g| {
                self.current_graph = try self.allocator.dupe(u8, g);
            }
        }
    }

    pub fn deinit(self: *SharedConnState) void {
        if (self.authenticated_user) |u| self.allocator.free(u);
        if (self.current_graph) |g| self.allocator.free(g);
        // peer_ip freed by the connection handler's defer
    }
};

/// Context passed to a spawned stream handler thread.
const StreamHandlerContext = struct {
    allocator: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    stream: *quic_transport.QuicStream,
    conn_state: *SharedConnState,
};

/// Entry point for additional (non-first) stream handler threads.
/// Each stream gets its own ServerState with per-stream transaction/result
/// state, but inherits the connection's authenticated identity.
// CANARY: REQ=REQ-QUIC-MUX-002; FEATURE="StreamMultiplexing"; ASPECT=StreamHandler; STATUS=IMPL; OWNER=server; UPDATED=2026-03-27
fn handleAdditionalStream(ctx_ptr: *anyopaque) void {
    const ctx: *StreamHandlerContext = @ptrCast(@alignCast(ctx_ptr));
    const gpa = ctx.allocator;
    const cs = ctx.conn_state;
    const stream = ctx.stream;
    const transport = ctx.transport;
    defer {
        stream.close();
        _ = cs.active_streams.fetchSub(1, .release);
        gpa.destroy(ctx);
    }

    // Build a per-stream ServerState inheriting shared connection identity.
    var state = ServerState{ .allocator = gpa };
    state.exec_session = execution.SessionState.init(gpa);
    state.txn_manager.init(gpa);
    state.inserted_values = .{};
    state.catalog_schemas = std.HashMap([]const u8, CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.catalog_graphs = std.HashMap([]const u8, CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.graph_types = std.HashMap([]const u8, geode.server_state.GraphTypeDefinition, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(gpa);
    state.query_mem_limit_bytes = cs.env_spill_threshold;
    state.storage_checksum_error = cs.env_storage_checksum_error;
    state.security_manager = cs.security_manager;
    state.query_optimizer = cs.shared_optimizer;
    state.query_ast_cache = cs.shared_ast_cache;
    state.graph_bound = cs.graph_bound;

    // Inherit authenticated identity from the connection's HELLO.
    if (cs.authenticated_user) |u| {
        state.authenticated_user = gpa.dupe(u8, u) catch null;
    }
    state.authenticated_role = cs.authenticated_role;
    state.password_reset_required = cs.password_reset_required;

    // Bind to the same graph as the connection.
    if (cs.current_graph) |g| {
        if (state.exec_session) |*sess| {
            sess.graph = gpa.dupe(u8, g) catch null;
        }
    }

    // Initialize evaluator callbacks (idempotent).
    execution.initEvaluator();

    // Federation planner (per-stream; lightweight init).
    var federation_manager = geode.distributed.query_planner.FederationManager.init(gpa);
    defer federation_manager.deinit();
    var dist_planner = geode.distributed.query_planner.DistributedQueryPlanner.init(gpa, &federation_manager);
    defer dist_planner.deinit();
    state.federation_manager = &federation_manager;
    state.distributed_planner = &dist_planner;

    // Env-driven optimizer/inline flags (same as first stream).
    state.query_optimizer_enabled = if (std.process.getEnvVarOwned(gpa, "GEODE_ENABLE_QUERY_OPTIMIZER")) |v| blk: {
        defer gpa.free(v);
        if (v.len == 0) break :blk false;
        if (v[0] == '0') break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "false")) break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "off")) break :blk false;
        break :blk true;
    } else |_| false;
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

    defer {
        state.resetResult();
        if (state.exec_session) |*sess| sess.deinit();
        if (state.session_config) |*cfg| cfg.deinit();
        if (state.authenticated_user) |u| gpa.free(u);
        if (state.authenticated_password) |p| {
            @memset(@constCast(p), 0);
            gpa.free(p);
        }
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

    // Run the query loop for this stream.
    runStreamQueryLoop(gpa, transport, stream, &state, cs.disable_estimates, cs.compact_profile, cs.memcurve_profile, cs.peer_ip);
}

/// Stream acceptor loop: runs on a dedicated thread after the first stream's
/// HELLO succeeds. Polls the connection for new peer-initiated streams and
/// spawns a handler thread for each one.
// CANARY: REQ=REQ-QUIC-MUX-003; FEATURE="StreamMultiplexing"; ASPECT=StreamAcceptor; STATUS=IMPL; OWNER=server; UPDATED=2026-03-27
fn streamAcceptorLoop(
    gpa: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    conn: *quic_transport.QuicConnection,
    conn_state: *SharedConnState,
    shutdown: *std.atomic.Value(bool),
) void {
    const max_additional_streams: u32 = 64; // Limit to prevent resource exhaustion
    while (!shutdown.load(.acquire)) {
        // Check if connection is still alive
        if (conn.isDrained()) break;

        // Check stream limit
        if (conn_state.active_streams.load(.acquire) >= max_additional_streams) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }

        // Non-blocking attempt to accept a new stream
        if (conn.tryAcceptStream()) |new_stream| {
            log.debug("Accepted additional multiplexed stream", &.{});
            _ = conn_state.active_streams.fetchAdd(1, .release);

            // Allocate context for the handler thread
            const ctx = gpa.create(StreamHandlerContext) catch {
                log.warn("Failed to allocate stream handler context", &.{});
                new_stream.close();
                _ = conn_state.active_streams.fetchSub(1, .release);
                continue;
            };
            ctx.* = .{
                .allocator = gpa,
                .transport = transport,
                .stream = new_stream,
                .conn_state = conn_state,
            };

            _ = std.Thread.spawn(.{}, handleAdditionalStream, .{@as(*anyopaque, @ptrCast(ctx))}) catch {
                log.warn("Failed to spawn stream handler thread", &.{});
                new_stream.close();
                _ = conn_state.active_streams.fetchSub(1, .release);
                gpa.destroy(ctx);
                continue;
            };
        } else {
            // No stream pending — poll and back off
            transport.poll(0) catch {};
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
}

/// Run the protobuf message loop for a single QUIC stream.
/// Used by both the first stream (inline in handleQuicConnection) and
/// additional multiplexed streams (in handleAdditionalStream).
fn runStreamQueryLoop(
    gpa: std.mem.Allocator,
    transport: *quic_transport.QuicTransport,
    stream: *quic_transport.QuicStream,
    state: *ServerState,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    peer_ip: []const u8,
) void {
    var line_reader = BufferedProtoReader.init(gpa, transport, stream) catch return;
    defer line_reader.deinit();

    while (true) {
        const packet_opt = line_reader.nextMessage() catch |err| {
            if (err == error.EndOfStream) return;
            if (err == error.WouldBlock) {
                if (stream.poll_sync) |ps| {
                    ps.waitForPoll(2 * std.time.ns_per_ms);
                } else {
                    std.Thread.sleep(100 * std.time.ns_per_us);
                }
                continue;
            }
            log.err("Protobuf read error", &.{Attr.string("error", @errorName(err))});
            return;
        };

        if (packet_opt == null) return; // EOF
        var packet = packet_opt.?;
        defer packet.deinit(gpa);

        const msg = packet.quic orelse {
            log.err("Received empty ClientPacket", &.{});
            sendExecuteError(gpa, stream, "58000", "Empty packet", &.{}, &.{}) catch return;
            continue;
        };

        handleClientMessage(gpa, state, stream, msg, disable_estimates, compact_profile, memcurve_profile, peer_ip) catch |err| {
            log.err("Protobuf process error", &.{Attr.string("error", @errorName(err))});
            sendExecuteError(gpa, stream, "58000", "Internal Server Error", &.{}, &.{}) catch return;
            continue;
        };
    }
}

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
    shared_optimizer: ?*query_plan_cache.SharedQueryOptimizer, // Issue #460
) !void {
    _ = _force_serialization_failure_unused;
    // CANARY: REQ=REQ-QUIC-CONN-CLEANUP-003; FEATURE="ConnectionMemoryManagement"; ASPECT=ProperCleanup; STATUS=EXEMPT; OWNER=server; UPDATED=2025-12-27
    // Use destroyConnection to properly remove from transport list, close, and free resources
    defer transport.destroyConnection(conn);
    log.debug("Entering handleQuicConnection", &.{});

    // Wait for incoming STREAM frames with handler-driven polling.
    // #540: Instead of blind-sleeping, handlers call poll(0) themselves to
    // process incoming handshake packets. This eliminates the dependency on
    // the main thread's poll frequency for handshake completion.
    var poll_attempts: usize = 0;
    var backoff_us: u64 = 100; // Start at 100μs
    const max_backoff_us: u64 = 10_000; // Cap at 10ms (reduced from 50ms)
    const max_total_wait_ms: u64 = 500;
    var total_waited_us: u64 = 0;
    while (total_waited_us < max_total_wait_ms * 1000) : (poll_attempts += 1) {
        if (conn.inner.hasIncomingStreams()) break;
        // Dedicated poll thread handles packet delivery — no handler poll needed.
        std.Thread.sleep(backoff_us * std.time.ns_per_us);
        total_waited_us += backoff_us;
        backoff_us = @min(backoff_us * 2, max_backoff_us);
        if (poll_attempts > 0 and poll_attempts % 10 == 0) {
            log.debug("No streams yet, retrying", &.{
                Attr.int("attempt", @intCast(poll_attempts + 1)),
                Attr.int("total_waited_ms", @intCast(total_waited_us / 1000)),
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
        if (state.authenticated_password) |p| {
            @memset(@constCast(p), 0); // SECURITY (S7): Zero plaintext password before freeing
            gpa.free(p);
        }
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

    // Issue #460: Use shared cross-connection optimizer instead of per-connection instance
    // CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=ConnectionWiring; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
    state.query_optimizer = shared_optimizer;

    // Attach shared AST cache for cross-connection reuse.
    // CANARY: REQ=REQ-PERF-AST-CACHE-003; FEATURE="SharedASTCache"; ASPECT=ConnectionState; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
    state.query_ast_cache = shared_ast_cache;

    // Initialize distributed query planner for federation-aware optimization
    var federation_manager = geode.distributed.query_planner.FederationManager.init(gpa);
    defer federation_manager.deinit();
    var dist_planner = geode.distributed.query_planner.DistributedQueryPlanner.init(gpa, &federation_manager);
    defer dist_planner.deinit();
    state.federation_manager = &federation_manager;
    state.distributed_planner = &dist_planner;

    // GAP-0258: mTLS authentication over QUIC — extract peer certificate and authenticate
    // CANARY: REQ=REQ-AUTH-MTLS-QUIC-003; FEATURE="mTLS over QUIC"; ASPECT=ConnectionAuth; STATUS=IMPL; OWNER=security; UPDATED=2026-02-13
    if (conn.getPeerCertificateDer()) |cert_der| {
        const identity = mtls_provider.extractIdentity(gpa, cert_der) catch |err| {
            log.warn("mTLS: Failed to extract certificate identity", &.{Attr.string("error", @errorName(err))});
            return err;
        };
        // Look up global mTLS provider (set in server/main.zig startup)
        if (g_mtls_provider) |provider| {
            if (provider.authenticate(&identity)) |auth_result_opt| {
                if (auth_result_opt) |auth_result| {
                    // Store the authenticated user from the mTLS certificate
                    state.authenticated_user = std.fmt.allocPrint(gpa, "mtls:{}", .{auth_result.user_id}) catch null;
                    log.info("mTLS: Authenticated user via certificate", &.{
                        Attr.int("user_id", @intCast(auth_result.user_id)),
                    });
                }
            } else |err| {
                log.warn("mTLS: Authentication failed", &.{Attr.string("error", @errorName(err))});
                if (transport.config.require_client_cert) {
                    return err;
                }
            }
        }
    } else if (transport.config.require_client_cert) {
        log.warn("mTLS: No client certificate presented (required)", &.{});
        return error.CertificateError;
    }

    // S6: Extract peer IP for rate limiting before the message loop.
    // CANARY: REQ=REQ-SEC-RATE-LIMIT-005; FEATURE="AuthRateLimiting"; ASPECT=PeerIPExtraction; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
    const peer_ip = conn.getPeerAddressString(gpa);
    const peer_ip_allocated = !std.mem.eql(u8, peer_ip, "unknown");
    defer if (peer_ip_allocated) gpa.free(peer_ip);

    // ── Phase 1: HELLO on first stream ─────────────────────────────────────
    // Wait for the first message (expected to be HELLO) and process it.
    // This keeps the handshake flow identical to the pre-multiplexing code.
    var line_reader = try BufferedProtoReader.init(gpa, transport, stream);
    defer line_reader.deinit();

    // Read and process the first message (HELLO).
    const hello_done = hello_blk: {
        while (true) {
            const packet_opt = line_reader.nextMessage() catch |err| {
                if (err == error.EndOfStream) return;
                if (err == error.WouldBlock) {
                    if (stream.poll_sync) |ps| {
                        ps.waitForPoll(2 * std.time.ns_per_ms);
                    } else {
                        std.Thread.sleep(100 * std.time.ns_per_us);
                    }
                    continue;
                }
                log.err("Protobuf read error during HELLO", &.{Attr.string("error", @errorName(err))});
                return err;
            };

            if (packet_opt == null) return; // EOF before HELLO
            var packet = packet_opt.?;
            defer packet.deinit(gpa);

            const msg = packet.quic orelse {
                try sendExecuteError(gpa, stream, "58000", "Empty packet", &.{}, &.{});
                continue;
            };

            // Process the message (should be HELLO, but handleClientMessage handles all types).
            handleClientMessage(gpa, &state, stream, msg, disable_estimates, compact_profile, memcurve_profile, peer_ip) catch |err| {
                log.err("HELLO processing error", &.{Attr.string("error", @errorName(err))});
                sendExecuteError(gpa, stream, "58000", "Internal Server Error", &.{}, &.{}) catch return;
                continue;
            };

            // After the first successfully processed message, continue to the query phase.
            break :hello_blk true;
        }
        break :hello_blk false;
    };
    if (!hello_done) return;

    // ── Phase 2: Stream multiplexing ─────────────────────────────────────
    // CANARY: REQ=REQ-QUIC-MUX-004; FEATURE="StreamMultiplexing"; ASPECT=AcceptorSpawn; STATUS=IMPL; OWNER=server; UPDATED=2026-03-27
    // Start a stream acceptor thread that watches for additional client-initiated
    // streams on this connection. Each new stream gets its own handler thread
    // with per-stream transaction/result state but shared authentication.
    var conn_state = SharedConnState{
        .allocator = gpa,
        .security_manager = security_manager,
        .shared_ast_cache = shared_ast_cache,
        .shared_optimizer = shared_optimizer,
        .peer_ip = peer_ip,
        .peer_ip_allocated = false, // Lifetime managed by caller's defer
        .disable_estimates = disable_estimates,
        .compact_profile = compact_profile,
        .memcurve_profile = memcurve_profile,
        .env_spill_threshold = env_spill_threshold,
        .env_storage_checksum_error = env_storage_checksum_error,
    };
    conn_state.captureFromState(&state) catch {
        log.warn("Failed to capture connection state for multiplexing", &.{});
    };
    // First stream counts as active.
    _ = conn_state.active_streams.fetchAdd(1, .release);
    defer {
        _ = conn_state.active_streams.fetchSub(1, .release);
        // Wait for ALL additional stream handlers to finish before freeing
        // conn_state. Without this, handlers reference freed memory → segfault.
        while (conn_state.active_streams.load(.acquire) > 0) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
        conn_state.deinit();
    }

    var acceptor_shutdown = std.atomic.Value(bool).init(false);
    const acceptor_thread = std.Thread.spawn(.{}, streamAcceptorLoop, .{
        gpa, transport, conn, &conn_state, &acceptor_shutdown,
    }) catch |err| {
        // If we can't spawn the acceptor, fall back to single-stream mode.
        // The first stream still works fine — just no multiplexing.
        log.warn("Failed to spawn stream acceptor, single-stream mode", &.{
            Attr.string("error", @errorName(err)),
        });
        runStreamQueryLoop(gpa, transport, stream, &state, disable_estimates, compact_profile, memcurve_profile, peer_ip);
        return;
    };
    defer {
        acceptor_shutdown.store(true, .release);
        acceptor_thread.join();
    }

    // ── Phase 3: First stream query loop (inline) ────────────────────────
    // The first stream's remaining messages are processed on this thread.
    // This reuses the existing line_reader that already consumed the HELLO.
    while (true) {
        const packet_opt = line_reader.nextMessage() catch |err| {
            if (err == error.EndOfStream) break; // First stream done — check multiplexed streams
            if (err == error.WouldBlock) {
                if (stream.poll_sync) |ps| {
                    ps.waitForPoll(2 * std.time.ns_per_ms);
                } else {
                    std.Thread.sleep(100 * std.time.ns_per_us);
                }
                continue;
            }
            log.err("Protobuf read error", &.{Attr.string("error", @errorName(err))});
            break; // Error — check multiplexed streams before destroying
        };

        if (packet_opt == null) break; // EOF — check multiplexed streams
        var packet = packet_opt.?;
        defer packet.deinit(gpa);

        const msg = packet.quic orelse {
            log.err("Received empty ClientPacket", &.{});
            sendExecuteError(gpa, stream, "58000", "Empty packet", &.{}, &.{}) catch return;
            continue;
        };

        handleClientMessage(gpa, &state, stream, msg, disable_estimates, compact_profile, memcurve_profile, peer_ip) catch |err| {
            log.err("Protobuf process error", &.{Attr.string("error", @errorName(err))});
            sendExecuteError(gpa, stream, "58000", "Internal Server Error", &.{}, &.{}) catch return;
            continue;
        };
    }

    // First stream ended (EOF or error). Close it but keep the connection alive
    // for any remaining multiplexed streams. The defer stack will:
    // 1. Wait for active_streams to reach 0 (conn_state defer)
    // 2. Shut down the acceptor thread (acceptor_shutdown defer)
    // 3. Destroy the connection (transport.destroyConnection defer)
    //
    // Without this, destroyConnection fires immediately when the first stream
    // closes, killing all multiplexed streams with EOF.
    stream.close();

    // Keep accepting new streams while existing ones are active.
    // The acceptor thread handles this, so we just wait here.
    // active_streams was decremented by the conn_state defer for the first stream.
    // The conn_state wait loop handles waiting for additional streams.
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

fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    var entropy: [16]u8 = undefined;
    std.crypto.random.bytes(&entropy);
    const token = std.fmt.bytesToHex(entropy, .lower);
    return std.fmt.allocPrint(allocator, "sess_{s}", .{token});
}

/// Validate federation HELLO using GEODE_CLUSTER_TOKEN.
/// GAP-0490: Both nodes must share the same cluster token.
/// Returns true only if username is "geode-cluster" AND password matches token.
// CANARY: REQ=REQ-GAP-0490-FEDERATION-SERVER-AUTH; FEATURE="FederationAuth"; ASPECT=ServerValidation; STATUS=TESTED; OWNER=security; UPDATED=2026-02-18
fn validateFederationAuth(username: []const u8, password: []const u8) bool {
    if (!std.mem.eql(u8, username, "geode-cluster")) return false;
    const expected = if (comptime builtin.os.tag != .windows) std.posix.getenv("GEODE_CLUSTER_TOKEN") else null;
    const expected_tok = expected orelse return false;
    if (expected_tok.len == 0 or password.len == 0) return false;
    if (password.len != expected_tok.len) return false;
    // Constant-time comparison — pad both to 256 bytes to prevent timing side-channels
    var buf_a: [256]u8 = [_]u8{0} ** 256;
    var buf_b: [256]u8 = [_]u8{0} ** 256;
    const n = @min(password.len, 256);
    @memcpy(buf_a[0..n], password[0..n]);
    @memcpy(buf_b[0..n], expected_tok[0..n]);
    return std.crypto.timing_safe.eql([256]u8, buf_a, buf_b);
}

/// Parse an ALTER USER <name> SET PASSWORD '<pwd>' statement from raw query text.
/// Returns the extracted username and new password, or null if the query doesn't match.
fn parseAlterUserSetPassword(query: []const u8) ?struct { username: []const u8, new_password: []const u8 } {
    // Case-insensitive prefix match: ALTER USER
    var pos: usize = 0;
    const q = query;
    if (q.len < 30) return null; // minimum: "ALTER USER x SET PASSWORD 'y'"

    // Skip leading whitespace
    while (pos < q.len and (q[pos] == ' ' or q[pos] == '\t')) pos += 1;

    // Match ALTER
    if (pos + 5 > q.len) return null;
    if (!std.ascii.eqlIgnoreCase(q[pos..][0..5], "ALTER")) return null;
    pos += 5;

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Match USER
    if (pos + 4 > q.len) return null;
    if (!std.ascii.eqlIgnoreCase(q[pos..][0..4], "USER")) return null;
    pos += 4;

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Extract username (until next space)
    const uname_start = pos;
    while (pos < q.len and q[pos] != ' ') pos += 1;
    if (pos == uname_start) return null;
    const username = q[uname_start..pos];

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Match SET
    if (pos + 3 > q.len) return null;
    if (!std.ascii.eqlIgnoreCase(q[pos..][0..3], "SET")) return null;
    pos += 3;

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Match PASSWORD
    if (pos + 8 > q.len) return null;
    if (!std.ascii.eqlIgnoreCase(q[pos..][0..8], "PASSWORD")) return null;
    pos += 8;

    // Skip whitespace
    while (pos < q.len and q[pos] == ' ') pos += 1;

    // Extract password from single quotes
    if (pos >= q.len or q[pos] != '\'') return null;
    pos += 1; // skip opening quote
    const pwd_start = pos;
    while (pos < q.len and q[pos] != '\'') pos += 1;
    if (pos >= q.len) return null; // no closing quote
    const new_password = q[pwd_start..pos];

    return .{ .username = username, .new_password = new_password };
}

/// Validate a password against the default geodeSecure policy without requiring
/// a SecurityManager instance.  Returns an error message string if the password
/// fails validation, or null if it passes.
/// SECURITY (S4): Fallback policy enforcement when SecurityManager is null.
fn validatePasswordFallback(password: []const u8) ?[]const u8 {
    const policy = geode_auth.PasswordPolicy.geodeSecure();

    if (password.len < policy.min_length) return "Password too short (minimum 20 characters)";
    if (password.len > policy.max_length) return "Password too long (maximum 256 characters)";

    if (policy.require_uppercase) {
        var found = false;
        for (password) |c| {
            if (std.ascii.isUpper(c)) {
                found = true;
                break;
            }
        }
        if (!found) return "Password must contain at least one uppercase letter";
    }

    if (policy.require_lowercase) {
        var found = false;
        for (password) |c| {
            if (std.ascii.isLower(c)) {
                found = true;
                break;
            }
        }
        if (!found) return "Password must contain at least one lowercase letter";
    }

    if (policy.require_digit) {
        var found = false;
        for (password) |c| {
            if (std.ascii.isDigit(c)) {
                found = true;
                break;
            }
        }
        if (!found) return "Password must contain at least one digit";
    }

    if (!policy.allow_spaces) {
        for (password) |c| {
            if (c == ' ') return "Password must not contain spaces";
        }
    }

    if (policy.require_passphrase) {
        var word_count: usize = 0;
        var in_word = false;
        for (password) |c| {
            if (c == ' ') {
                in_word = false;
            } else {
                if (!in_word) word_count += 1;
                in_word = true;
            }
        }
        if (word_count < policy.min_words) return "Password must be a passphrase with at least 3 words";
    }

    return null;
}

/// Handle ALTER USER SET PASSWORD when password reset is required.
/// Updates the user's password, clears the reset flag, and sends a success response.
fn handleAlterUserSetPassword(
    gpa: std.mem.Allocator,
    state: *ServerState,
    stream: *quic_transport.QuicStream,
    username: []const u8,
    new_password: []const u8,
) !void {
    // Verify the user is changing their own password.
    // SECURITY (S9): When authenticated_user is null (auth disabled or session
    // not authenticated), reject password changes -- callers must authenticate
    // before altering any user's password.
    if (state.authenticated_user) |auth_user| {
        if (!std.mem.eql(u8, auth_user, username)) {
            try sendExecuteError(gpa, stream, "42501", "You can only change your own password", &.{}, &.{});
            return;
        }
    } else {
        try sendExecuteError(gpa, stream, "42501", "Authentication required to change passwords", &.{}, &.{});
        return;
    }

    // Validate password against SecurityManager policy BEFORE updating the
    // in-memory store.  Previously, user_mgmt accepted any password (no policy
    // validation), then sm.updatePassword silently failed when the password
    // didn't meet policy — so the change never persisted and reverted on restart.
    if (state.security_manager) |sm| {
        sm.validatePassword(new_password) catch |err| {
            const msg = switch (err) {
                error.PasswordTooShort => "Password too short (minimum 20 characters)",
                error.PasswordTooLong => "Password too long (maximum 256 characters)",
                error.PasswordMissingUppercase => "Password must contain at least one uppercase letter",
                error.PasswordMissingLowercase => "Password must contain at least one lowercase letter",
                error.PasswordMissingDigit => "Password must contain at least one digit",
                error.PasswordContainsSpaces => "Password must not contain spaces",
                error.PasswordNotPassphrase => "Password must be a passphrase with at least 3 words",
                else => "Password does not meet security policy requirements",
            };
            try sendExecuteError(gpa, stream, "28P01", msg, &.{}, &.{});
            return;
        };
    } else {
        // SECURITY (S4): When SecurityManager is null, enforce the same password
        // policy as geodeSecure() to prevent bypassing password requirements.
        if (validatePasswordFallback(new_password)) |msg| {
            try sendExecuteError(gpa, stream, "28P01", msg, &.{}, &.{});
            return;
        }
    }

    user_mgmt.updateUserPassword(gpa, username, new_password) catch |err| {
        const msg = switch (err) {
            error.PasswordReuse => "New password must not match the current password",
            else => "Failed to update password",
        };
        try sendExecuteError(gpa, stream, "28P01", msg, &.{}, &.{});
        return;
    };

    // Persist the password change to the auth graph store so it survives restarts.
    // The in-memory user_mgmt store is ephemeral; the SecurityManager's callback
    // writes the new hash to the persistent GraphStore via AuthGraphManager.
    if (state.security_manager) |sm| {
        if (sm.getUserIdByUsername(username)) |user_id| {
            sm.updatePassword(user_id, new_password) catch |err| {
                log.warn("Failed to persist password change to auth graph", &.{
                    Attr.string("username", username),
                    Attr.string("error", @errorName(err)),
                });
            };
        }
    }

    state.password_reset_required = false;

    // Send success response as a status-only execution result (no payload).
    // Sending a page payload would cause the REPL to issue a PULL request,
    // which fails with "no active result set" since no query was executed.
    const status = try proto_util.buildStatus(gpa, "00000", &.{});
    const resp = schema.ExecutionResponse{
        .status = status,
        .payload = null,
    };
    try sendQuicMessage(gpa, stream, .{ .execute = resp });
}

fn handleClientMessage(
    gpa: std.mem.Allocator,
    state: *ServerState,
    stream: *quic_transport.QuicStream,
    msg: schema.QuicClientMessage,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    peer_ip: []const u8,
) !void {
    switch (msg) {
        .hello => |hello_req| {
            var caps = std.ArrayList([]const u8).initCapacity(gpa, 3) catch return error.OutOfMemory;
            try caps.append(gpa, try gpa.dupe(u8, "QUIC"));
            try caps.append(gpa, try gpa.dupe(u8, "TLS1.3"));
            try caps.append(gpa, try gpa.dupe(u8, "PROTOBUF"));

            // S6: Per-IP rate limiting — reject locked-out IPs before attempting authentication.
            // CANARY: REQ=REQ-SEC-RATE-LIMIT-006; FEATURE="AuthRateLimiting"; ASPECT=HelloCheck; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
            if (g_auth_rate_limiter) |limiter| {
                if (limiter.isLocked(peer_ip)) {
                    log.warn("Authentication rate limit exceeded", &.{
                        Attr.string("peer_ip", peer_ip),
                    });
                    const resp = schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = try gpa.dupe(u8, ""),
                        .error_message = try gpa.dupe(u8, "Too many failed authentication attempts. Please try again later."),
                        .capabilities = caps,
                    } };
                    try sendQuicMessage(gpa, stream, resp);
                    return;
                }
            }

            // GAP-0490: Federation inter-node authentication via cluster token — fast-path
            // Must be checked BEFORE normal user auth to allow federation when auth is enabled.
            if (validateFederationAuth(hello_req.username, hello_req.password)) {
                log.info("Federation node authenticated via cluster token", &.{
                    Attr.string("client", hello_req.client_name),
                });
                // Grant federation-level session: store identity, grant ReadWrite role
                if (state.authenticated_user) |u| gpa.free(u);
                if (state.authenticated_password) |p| {
                    @memset(@constCast(p), 0); // SECURITY (S7): Zero plaintext password before freeing
                    gpa.free(p);
                }
                state.authenticated_user = try gpa.dupe(u8, hello_req.username);
                state.authenticated_password = try gpa.dupe(u8, hello_req.password);
                state.authenticated_role = @intFromEnum(user_mgmt.Role.ReadWrite);
                // GAP-0490: mTLS enforcement for federation connections (opportunistic — log only)
                if (g_mtls_provider) |provider| {
                    _ = provider;
                    log.info("Federation mTLS provider configured; certificate validation deferred to TLS layer", &.{});
                }
            } else if (user_mgmt.isAuthEnabled()) {
                if (hello_req.username.len == 0 or hello_req.password.len == 0) {
                    // S6: Record failure for empty credentials (still counts as a failed attempt).
                    if (g_auth_rate_limiter) |limiter| limiter.recordFailure(peer_ip);
                    const resp = schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = try gpa.dupe(u8, ""),
                        .error_message = try gpa.dupe(u8, "Authentication required"),
                        .capabilities = caps,
                    } };
                    try sendQuicMessage(gpa, stream, resp);
                    return;
                }

                const auth_result = user_mgmt.authenticate(hello_req.username, hello_req.password) catch {
                    // S6: Record failure for bad credentials.
                    if (g_auth_rate_limiter) |limiter| limiter.recordFailure(peer_ip);
                    const resp = schema.QuicServerMessage{ .hello = .{
                        .success = false,
                        .session_id = try gpa.dupe(u8, ""),
                        .error_message = try gpa.dupe(u8, "Authentication failed"),
                        .capabilities = caps,
                    } };
                    try sendQuicMessage(gpa, stream, resp);
                    return;
                };

                // S6: Successful authentication — reset failure counter for this IP.
                if (g_auth_rate_limiter) |limiter| limiter.recordSuccess(peer_ip);

                if (state.authenticated_user) |u| gpa.free(u);
                if (state.authenticated_password) |p| {
                    @memset(@constCast(p), 0); // SECURITY (S7): Zero plaintext password before freeing
                    gpa.free(p);
                }
                state.authenticated_user = try gpa.dupe(u8, hello_req.username);
                state.authenticated_password = try gpa.dupe(u8, hello_req.password);
                state.authenticated_role = @intFromEnum(auth_result.role);
                state.password_reset_required = auth_result.password_reset_required;
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

            // CANARY: REQ=REQ-DSN-GRAPH-BIND-003; FEATURE="DSNGraphBinding"; ASPECT=QuicGraphResolution; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
            // Resolve graph from HELLO request — validate, auto-create, bind session
            var resolved_graph: ?[]const u8 = null;
            if (hello_req.graph) |requested_graph| {
                if (requested_graph.len > 0) {
                    // Validate graph name: max 128 chars, alphanumeric + underscore only
                    if (requested_graph.len > 128) {
                        const resp = schema.QuicServerMessage{ .hello = .{
                            .success = false,
                            .session_id = try gpa.dupe(u8, ""),
                            .error_message = try gpa.dupe(u8, "Invalid graph name: too long (max 128 characters)"),
                            .capabilities = caps,
                        } };
                        try sendQuicMessage(gpa, stream, resp);
                        return;
                    }
                    for (requested_graph) |c| {
                        if (!std.ascii.isAlphanumeric(c) and c != '_') {
                            const resp = schema.QuicServerMessage{ .hello = .{
                                .success = false,
                                .session_id = try gpa.dupe(u8, ""),
                                .error_message = try gpa.dupe(u8, "Invalid graph name: must contain only alphanumeric characters and underscores"),
                                .capabilities = caps,
                            } };
                            try sendQuicMessage(gpa, stream, resp);
                            return;
                        }
                    }
                    const store = graph_store.getGlobalStore(gpa);
                    const cat = try execution.ensureCatalogInstance(gpa);

                    const in_store = store.graphExists(requested_graph);
                    const in_catalog = cat.hasGraph(requested_graph);

                    if (in_store or in_catalog) {
                        // Graph exists — bind session to it
                        if (state.exec_session) |*sess| {
                            if (sess.graph) |old| gpa.free(old);
                            sess.graph = try gpa.dupe(u8, requested_graph);
                        }
                        state.graph_bound = true;
                        resolved_graph = requested_graph;
                    } else {
                        // Graph does not exist — check if user can create it
                        const role_val = state.authenticated_role;
                        const can_create = if (role_val) |r| blk: {
                            const role = @as(user_mgmt.Role, @enumFromInt(r));
                            break :blk role == .Admin or role == .ReadWrite;
                        } else !user_mgmt.isAuthEnabled(); // No auth = allow

                        if (can_create) {
                            // Auto-create the graph
                            cat.addGraph(requested_graph) catch |err| {
                                if (err != error.GraphAlreadyExists) {
                                    log.err("Failed to add graph to catalog", &.{
                                        Attr.string("graph", requested_graph),
                                        Attr.string("error", @errorName(err)),
                                    });
                                }
                            };
                            _ = store.createGraph(requested_graph) catch |err| {
                                log.err("Graph auto-creation failed", &.{
                                    Attr.string("graph", requested_graph),
                                    Attr.string("error", @errorName(err)),
                                });
                                const resp = schema.QuicServerMessage{ .hello = .{
                                    .success = false,
                                    .session_id = try gpa.dupe(u8, ""),
                                    .error_message = try gpa.dupe(u8, "Failed to create graph"),
                                    .capabilities = caps,
                                } };
                                try sendQuicMessage(gpa, stream, resp);
                                return;
                            };

                            if (state.exec_session) |*sess| {
                                if (sess.graph) |old| gpa.free(old);
                                sess.graph = try gpa.dupe(u8, requested_graph);
                            }
                            state.graph_bound = true;
                            resolved_graph = requested_graph;
                        } else {
                            // User lacks permission to create graph
                            const resp = schema.QuicServerMessage{ .hello = .{
                                .success = false,
                                .session_id = try gpa.dupe(u8, ""),
                                .error_message = try gpa.dupe(u8, "Graph does not exist and user lacks permission to create it"),
                                .capabilities = caps,
                            } };
                            try sendQuicMessage(gpa, stream, resp);
                            return;
                        }
                    }
                }
            }

            const session_id = try generateSessionId(gpa);
            const resp = schema.QuicServerMessage{ .hello = .{
                .success = true,
                .session_id = session_id,
                .error_message = try gpa.dupe(u8, ""),
                .capabilities = caps,
                .password_reset_required = state.password_reset_required,
                .graph = if (resolved_graph) |g| try gpa.dupe(u8, g) else null,
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

            // Handle ALTER USER SET PASSWORD — intercept before GQL parser since
            // ALTER USER is not part of GQL syntax. Works both during forced
            // password reset and for normal password changes.
            {
                const trimmed = std.mem.trim(u8, exec_req.query, " \t\r\n");
                if (parseAlterUserSetPassword(trimmed)) |parsed| {
                    try handleAlterUserSetPassword(gpa, state, stream, parsed.username, parsed.new_password);
                    return;
                }
            }

            // Block all other queries when password reset is required
            if (state.password_reset_required) {
                try sendExecuteError(gpa, stream, "08P01", "Password reset required. Change password with: ALTER USER <username> SET PASSWORD '<new_password>'", &.{}, &.{});
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

            // Wire shared AST cache into parse hot path (Issue #444)
            // CANARY: REQ=REQ-PERF-AST-CACHE-004; FEATURE="SharedASTCache"; ASPECT=ParseHotPathWiring; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
            var ast_cache_handle: ?query_ast_cache.AstHandle = null;
            var owned_parse_result: geode.ParseResult = undefined;
            var owns_parse_result: bool = false;
            defer {
                if (ast_cache_handle) |*h| h.release();
                if (owns_parse_result) owned_parse_result.deinit();
            }

            const parse_result: *const geode.ParseResult = parse_blk: {
                // Try shared AST cache first for cross-connection reuse
                if (state.query_ast_cache) |cache_ptr| {
                    const cache: *query_ast_cache.SharedAstCache = @ptrCast(@alignCast(cache_ptr));
                    switch (try cache.getOrParse(query_text, parse_opts)) {
                        .Err => |err_info| {
                            const err_msg = if (err_info.has_double_dash_comment)
                                diagnostics.defaultMessage(.GB02CommentDisabled)
                            else
                                err_info.msg;
                            try sendExecuteError(gpa, stream, "42000", err_msg, &.{}, &.{});
                            return;
                        },
                        .Ok => |handle| {
                            ast_cache_handle = handle;
                            break :parse_blk handle.parse_result;
                        },
                    }
                }
                // Fallback: parse directly when no cache is configured
                switch (try geode.parseGqlOutcome(query_text, gpa, parse_opts)) {
                    .Err => |err_info| {
                        const err_msg = if (err_info.has_double_dash_comment)
                            diagnostics.defaultMessage(.GB02CommentDisabled)
                        else
                            err_info.msg;
                        try sendExecuteError(gpa, stream, "42000", err_msg, &.{}, &.{});
                        return;
                    },
                    .Ok => |pr| {
                        owned_parse_result = pr;
                        owns_parse_result = true;
                        break :parse_blk &owned_parse_result;
                    },
                }
            };

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
            // Issue #452/#460: Consult shared optimizer for plan hints
            // CANARY: REQ=REQ-PERF-SHARED-OPT-001; FEATURE="SharedQueryOptimizer"; ASPECT=HintExtraction; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
            var plan_handle: ?query_plan_cache.SharedPlanHandle = null;
            var optimizer_hints_storage: query_plan_cache.OptimizerHints = .{};
            defer if (plan_handle) |*h| h.release();

            if (state.query_optimizer) |shared_opt| {
                const store = graph_store.getGlobalStore(gpa);
                const store_stats = query_plan_cache.StoreStats{
                    .node_count = @intCast(store.getNodeCount()),
                    .edge_count = @intCast(store.getEdgeCount()),
                };
                plan_handle = shared_opt.optimizeQuery(query_text, &parse_result.program, store_stats) catch null;
                if (plan_handle) |*h| {
                    optimizer_hints_storage = h.toHints();
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
                .optimizer_hints = if (plan_handle != null) &optimizer_hints_storage else null,
                .graph_bound = state.graph_bound,
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

            // GAP-0001: Acquire the appropriate store lock based on query type.
            // Mutations (CREATE, MERGE, DELETE, INSERT, DDL) take the exclusive
            // write lock to prevent concurrent HashMap rehash races (CWE-362).
            // Read-only queries take the shared lock so they can run in parallel.
            // EXPLAIN never executes, so no lock is needed.
            // #52: Lock is released explicitly after execution completes but BEFORE
            // response serialization and network send, to avoid holding the global
            // write lock during slow I/O operations.
            const needs_store_lock = analysis.kind != .explain;
            const is_mutation = needs_store_lock and isMutatingProgram(&parse_result.program);
            if (needs_store_lock) {
                if (is_mutation) {
                    graph_store.acquireStoreWriteLock();
                } else {
                    graph_store.acquireStoreLock();
                }
            }
            // Safety net: release on any unexpected error path not explicitly handled.
            var lock_released = false;
            defer {
                if (!lock_released and needs_store_lock) {
                    if (is_mutation) {
                        graph_store.releaseStoreWriteLock();
                    } else {
                        graph_store.releaseStoreLock();
                    }
                }
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

                    // Capture store stats while under lock
                    const store = graph_store.getGlobalStore(gpa);
                    const profile_node_count: u64 = @intCast(store.getNodeCount());
                    const profile_edge_count: u64 = @intCast(store.getEdgeCount());
                    const profile_is_dirty = store.isDirty();

                    // #52: Release lock before serialization and network send.
                    // exec_result is a thread-local copy; store stats are captured above.
                    if (needs_store_lock) {
                        if (is_mutation) graph_store.releaseStoreWriteLock() else graph_store.releaseStoreLock();
                        lock_released = true;
                    }

                    // S1: RLS filter on PROFILE path (same logic as .rows path).
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                            _ = rls_filter.applyRLSFilter(gpa, &exec_result, rls_engine, auth_user, rls_graph);
                        }
                    }

                    const profile_msg = try profile_payload.buildProfilePayload(gpa, traits, exec_result.rows.len, .{
                        .compact = compact_profile,
                        .include_mem_curve = memcurve_profile,
                        .disable_estimates = disable_estimates,
                        .spill_threshold = state.query_mem_limit_bytes,
                        .committed_txns = state.global_commit_ts,
                        .graph_store_nodes = profile_node_count,
                        .graph_store_edges = profile_edge_count,
                        .graph_store_dirty = profile_is_dirty,
                        .flagger_findings = exec_result.flags.items,
                        .union_part_count = analysis.union_part_count,
                    });

                    const status = try proto_util.buildStatus(gpa, "00000", exec_result.flags.items);
                    const resp = schema.ExecutionResponse{
                        .status = status,
                        .payload = .{ .profile = profile_msg },
                    };
                    try sendQuicMessage(gpa, stream, .{ .execute = resp });

                    // GAP-0260: Non-txn saves deferred to background persistence thread
                },
                .rows => {
                    var exec_result = execution.executeProgramWithContext(gpa, &parse_result.program, exec_context) catch |err| {
                        const info = proto_util.mapError(err);
                        try sendExecuteError(gpa, stream, info.code, info.message, &.{}, &.{});
                        return;
                    };
                    var store_result = false;
                    defer if (!store_result) exec_result.deinit(gpa);

                    // #52: Release lock immediately after execution completes.
                    // exec_result is a thread-local copy (owned data, freed by connection allocator).
                    // Everything below (flags, ordering, serialization, send, txn state update)
                    // does not access the store and does not need the lock.
                    if (needs_store_lock) {
                        if (is_mutation) graph_store.releaseStoreWriteLock() else graph_store.releaseStoreLock();
                        lock_released = true;
                    }

                    // S1: Apply label-based RLS filtering AFTER lock release and BEFORE
                    // response serialization.  This removes rows whose Node/Edge labels
                    // are denied for the authenticated user in the current graph.
                    // CANARY: REQ=REQ-SEC-RLS-WIRE-003; FEATURE="RLS Query Enforcement"; ASPECT=PostResultFilter; STATUS=IMPL; OWNER=security; UPDATED=2026-03-26
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                            _ = rls_filter.applyRLSFilter(gpa, &exec_result, rls_engine, auth_user, rls_graph);
                        }
                    }

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

                    // Arena allocator for schema definition serialization (Issue #446)
                    {
                        var schema_arena = std.heap.ArenaAllocator.init(gpa);
                        defer schema_arena.deinit();
                        const sa = schema_arena.allocator();
                        const status = try proto_util.buildStatus(sa, "00000", exec_result.flags.items);
                        const schema_def = try proto_util.buildSchemaDefinition(sa, &exec_result);
                        const schema_resp = schema.ExecutionResponse{
                            .status = status,
                            .payload = .{ .schema = schema_def },
                        };
                        try sendQuicMessage(sa, stream, .{ .execute = schema_resp });
                    }

                    var sent_rows: usize = 0;
                    var page_final = false;
                    if (state.inline_results_enabled) {
                        const inline_max = if (state.inline_results_max_rows == 0) exec_result.rows.len else state.inline_results_max_rows;
                        // Arena allocator for data page serialization (Issue #446):
                        // Per-value string dups become bump allocations; individual frees become no-ops.
                        var page_arena = std.heap.ArenaAllocator.init(gpa);
                        defer page_arena.deinit();
                        const pa = page_arena.allocator();
                        const page = try proto_util.buildDataPage(pa, &exec_result, 0, inline_max, ordered, order_keys);
                        sent_rows = page.rows.items.len;
                        page_final = page.final;
                        const page_status = try proto_util.buildStatus(pa, "00000", exec_result.flags.items);
                        const page_resp = schema.ExecutionResponse{
                            .status = page_status,
                            .payload = .{ .page = page },
                        };
                        try sendQuicMessage(pa, stream, .{ .execute = page_resp });
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

            // Arena allocator for pull page serialization (Issue #446)
            var pull_arena = std.heap.ArenaAllocator.init(gpa);
            defer pull_arena.deinit();
            const pa = pull_arena.allocator();

            const page = try proto_util.buildDataPage(pa, result, start, page_size, state.result_ordered, state.result_order_keys);
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

            const status = try proto_util.buildStatus(pa, "00000", result.flags.items);
            const resp = schema.ExecutionResponse{
                .status = status,
                .payload = .{ .page = page },
            };
            try sendQuicMessage(pa, stream, .{ .pull = .{ .response = resp } });

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
                try sendQuicMessage(gpa, stream, .{ .commit = .{ .success = true } });
            } else {
                try sendQuicMessage(gpa, stream, .{ .commit = .{ .success = false } });
            }
        },
        .rollback => |_| {
            if (state.in_txn) {
                // GAP-0001: Rollback reverses mutations on the store — needs exclusive lock
                graph_store.acquireStoreWriteLock();
                defer graph_store.releaseStoreWriteLock();
                const store = graph_store.getGlobalStore(gpa);
                txn_undo_log.getGlobalUndoLog(gpa).rollback(store) catch |err| {
                    log.err("Rollback failed", &.{Attr.string("error", @errorName(err))});
                };
                state.in_txn = false;
                state.txn_id = 0;
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
                    .version = try gpa.dupe(u8, @import("build_options").version),
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
            // GAP-0001: Backup reads from the store — shared lock prevents
            // concurrent mutations from corrupting the snapshot.
            graph_store.acquireStoreLock();
            defer graph_store.releaseStoreLock();
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
                                Attr.string("error", @errorName(err)),
                            });
                            break;
                        };
                        if (n == 0) break;
                        _ = stream.write(buf[0..n]) catch |err| {
                            log.err("Failed to stream backup bytes", &.{
                                Attr.string("path", backup_path),
                                Attr.string("error", @errorName(err)),
                            });
                            break;
                        };
                        remaining -= n;
                    }
                } else |err| {
                    log.err("Backup file missing for streaming", &.{
                        Attr.string("path", backup_path),
                        Attr.string("error", @errorName(err)),
                    });
                }
            }
        },
        .restore => |restore_req| {
            // GAP-0001: Restore mutates on-disk state — exclusive write lock
            graph_store.acquireStoreWriteLock();
            defer graph_store.releaseStoreWriteLock();
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
