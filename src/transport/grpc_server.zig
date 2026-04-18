const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

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

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}
const builtin = @import("builtin");
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const grpc_zig = @import("grpc_server");
const GrpcServer = grpc_zig.GrpcServer;
const GrpcTransport = grpc_zig.Transport;
const proto_util = geode.proto_util;
const server_flags = geode.server_flags;
const diagnostics = geode.diagnostics;
const execution = geode.execution;
const graph_store = geode.graph_store;
const server_state = geode.server_state;
const query_runner = geode.query_runner;
const query_traits = geode.query_traits;
const explain_payload = geode.explain_payload;
const profile_payload = geode.profile_payload;
const txn_undo_log = geode.txn_undo_log;
const index_manager = geode.index_manager;
const user_mgmt = geode.user_management;
const gql_ast = geode.gql.ast;
const gql_print = geode.printer;
const planned_read_runtime = geode.planned_read_runtime;
const node_scan_stream = geode.node_scan_stream;
const geode_auth = @import("geode_auth");
const grpc_tls = @import("grpc_tls.zig");
// Issue #515: Backup types for new gRPC handlers
const backup_mgr = geode.backup_manager;
const SimplifiedBackupManager = backup_mgr.SimplifiedBackupManager;

// GAP-0281: FLE integration for per-tenant encryption namespace setup.
const fle_integration = geode.fle_integration;
// GAP-0282: Import audit module for per-thread tenant_id enrichment
const audit_mod = geode.security.audit;
// S1: RLS post-result filtering (parity with QUIC handler).
const rls_filter = @import("../server/rls_filter.zig");
// S6: Auth rate limiter (parity with QUIC handler).
const auth_rate_limiter_mod = @import("../server/auth_rate_limiter.zig");
// GAP-0283: Graph-scoped RBAC enforcement (parity with QUIC handler).
const multi_graph_security = geode.multi_graph_security;
// GAP-0289: Per-tenant resource quotas (parity with QUIC handler).
const tenant_quota = geode.tenant_quota;

const logging = @import("logging");
const log = logging.scoped("grpc");
const Attr = logging.Attr;

pub const GrpcConfig = struct {
    spill_threshold: usize = 0,
    storage_checksum_error: bool = false,
    disable_estimates: bool = false,
    compact_profile: bool = false,
    memcurve_profile: bool = false,
    security_manager: ?*geode_auth.SecurityManager = null,
};

const SessionEntry = struct {
    state: *server_state.ServerState,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
};

const SessionAuthStatus = enum {
    ok,
    missing,
    invalidated,
};

const AdminSessionStatus = enum {
    ok,
    missing,
    invalidated,
    forbidden,
};

fn envFlagEnabled(allocator: std.mem.Allocator, name: []const u8) bool {
    const raw = getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(raw);
    if (raw.len == 0) return false;
    if (raw[0] == '0') return false;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "off")) return false;
    return true;
}

fn shouldAllowGrpcPlaintextFallback(allocator: std.mem.Allocator) bool {
    if (!envFlagEnabled(allocator, "GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK")) return false;
    if (builtin.mode == .Debug) return true;

    log.warn("Ignoring GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK outside Debug builds", &.{});
    return false;
}

fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    var entropy: [16]u8 = undefined;
    compat_fillRandom(&entropy);
    const token = std.fmt.bytesToHex(entropy, .lower);
    return std.fmt.allocPrint(allocator, "sess_{s}", .{token});
}

fn throttleInvalidSessionProbe() void {
    var jitter: [1]u8 = undefined;
    compat_fillRandom(&jitter);
    const delay_ms: u64 = 5 + @as(u64, @intCast(jitter[0] % 6));
    const ns: u64 = delay_ms * std.time.ns_per_ms;
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

fn rebuildPendingIndexes(
    allocator: std.mem.Allocator,
    graph_name: []const u8,
    pending_index_rebuilds: *std.StringHashMap(void),
) void {
    if (pending_index_rebuilds.count() == 0) return;
    const manager = index_manager.getGlobalIndexManager() orelse return;

    const rebuild_lock = graph_store.acquireGraphReadLock(graph_name);
    defer graph_store.releaseGraphLock(rebuild_lock);

    const store = graph_store.getGlobalStore(allocator);
    var iter = pending_index_rebuilds.keyIterator();
    while (iter.next()) |k| manager.rebuildAdvancedIndex(store, k.*) catch {};
}

// Issue #453: Use RwLock instead of Mutex to allow concurrent readers
const SessionStore = struct {
    allocator: std.mem.Allocator,
    rwlock: std.Io.RwLock = std.Io.RwLock.init,
    sessions: std.StringHashMap(*SessionEntry),
    config: GrpcConfig,

    pub fn init(allocator: std.mem.Allocator, config: GrpcConfig) SessionStore {
        execution.initEvaluator();
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*SessionEntry).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *SessionStore) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session_id = entry.key_ptr.*;
            const session = entry.value_ptr.*;
            deinitServerState(session.state);
            self.allocator.destroy(session.state);
            self.allocator.destroy(session);
            self.allocator.free(session_id);
        }
        self.sessions.deinit();
    }

    pub fn createSession(
        self: *SessionStore,
        username: []const u8,
        password: []const u8,
        role: ?user_mgmt.Role,
        tenant_id: ?[]const u8,
        graph: ?[]const u8,
        pwd_reset_required: bool,
        auth_version: u64,
    ) ![]const u8 {
        const session_id = try generateSessionId(self.allocator);
        const state = try initServerState(self.allocator, self.config);
        if (username.len > 0) {
            state.authenticated_user = try self.allocator.dupe(u8, username);
        }
        if (password.len > 0) {
            state.authenticated_password = try self.allocator.dupe(u8, password);
        }
        if (role) |r| {
            state.authenticated_role = @intFromEnum(r);
        }
        state.authenticated_auth_version = auth_version;
        // GAP-0284: Persist password_reset_required flag so execute handler can enforce it.
        state.password_reset_required = pwd_reset_required;
        if (tenant_id) |tenant| {
            // GAP-0289: Enforce per-tenant connection quota before registering the session.
            if (tenant_quota.getGlobalQuotaManager()) |qm| {
                qm.acquireConnection(tenant) catch return error.OutOfMemory; // quota exceeded
            }
            state.session_config = server_state.SessionConfiguration.init(self.allocator);
            state.session_config.?.tenant_id = try self.allocator.dupe(u8, tenant);
        }

        // GAP-0281: Set per-thread FLE tenant_id for encryption namespace isolation.
        fle_integration.setCurrentTenantId(if (state.session_config) |cfg| cfg.tenant_id else null);
        // GAP-0282: Set per-thread audit tenant_id so all audit events carry tenant context.
        audit_mod.setCurrentAuditTenantId(if (state.session_config) |cfg| cfg.tenant_id else null);

        // CANARY: REQ=REQ-DSN-GRAPH-BIND-004; FEATURE="DSNGraphBinding"; ASPECT=GrpcSessionGraph; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
        if (graph) |g| {
            if (g.len > 0) {
                if (state.exec_session) |*sess| {
                    if (sess.graph) |old| self.allocator.free(old);
                    sess.graph = try self.allocator.dupe(u8, g);
                }
                state.graph_bound = true;
            }
        }

        const entry = try self.allocator.create(SessionEntry);
        entry.* = .{ .state = state };

        self.rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
        try self.sessions.put(session_id, entry);
        return session_id;
    }

    pub fn getEntry(self: *SessionStore, session_id: []const u8) ?*SessionEntry {
        self.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
        return self.sessions.get(session_id);
    }
};

/// Issue #514: Use atomic for session store pointer to prevent race on initialization.
/// CANARY: REQ=REQ-GRPC-ATOMIC-SESSION-001; FEATURE="GrpcSessionSafety"; ASPECT=AtomicPointer; STATUS=IMPL; OWNER=transport; UPDATED=2026-02-13
var g_session_store_atomic: std.atomic.Value(?*SessionStore) = std.atomic.Value(?*SessionStore).init(null);

/// Thread-safe getter for session store.
fn getSessionStore() ?*SessionStore {
    return g_session_store_atomic.load(.acquire);
}

/// Thread-safe setter for session store.
fn setSessionStore(store: ?*SessionStore) void {
    g_session_store_atomic.store(store, .release);
}

fn initServerState(allocator: std.mem.Allocator, config: GrpcConfig) !*server_state.ServerState {
    const state = try allocator.create(server_state.ServerState);
    state.* = .{ .allocator = allocator };
    state.exec_session = execution.SessionState.init(allocator);
    state.telemetry_paging = if (getEnvVarOwned(allocator, "GEODE_TELEMETRY_PAGING")) |v| blk: {
        defer allocator.free(v);
        break :blk true;
    } else |_| false;
    state.txn_manager.init(allocator);
    state.inserted_values = .empty;
    state.catalog_schemas = std.HashMap([]const u8, server_state.CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    state.catalog_graphs = std.HashMap([]const u8, server_state.CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    state.graph_types = std.HashMap([]const u8, server_state.GraphTypeDefinition, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    state.query_mem_limit_bytes = config.spill_threshold;
    state.storage_checksum_error = config.storage_checksum_error;
    state.security_manager = config.security_manager;
    state.query_optimizer_enabled = if (getEnvVarOwned(allocator, "GEODE_ENABLE_QUERY_OPTIMIZER")) |v| blk: {
        defer allocator.free(v);
        // Use consistent boolean parsing across transports (matches QUIC handler)
        if (v.len == 0) break :blk false;
        if (v[0] == '0') break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "false")) break :blk false;
        if (std.ascii.eqlIgnoreCase(v, "off")) break :blk false;
        break :blk true;
    } else |_| false;
    return state;
}

fn deinitServerState(state: *server_state.ServerState) void {
    const alloc = state.allocator;
    // GAP-0285: Clear per-thread FLE state (tenant_id and role) to prevent stale
    // state from leaking into a subsequent request that reuses this thread.
    // CANARY: REQ=REQ-FLE-ROLE-ISOLATION-004; FEATURE="FLERoleIsolation"; ASPECT=GrpcCleanup; STATUS=IMPL; OWNER=security; UPDATED=2026-04-05
    fle_integration.clearCurrentThreadState();
    // GAP-0285: Also clear per-thread audit tenant_id.
    audit_mod.setCurrentAuditTenantId(null);

    state.resetResult();
    if (state.exec_session) |*sess| sess.deinit();
    // GAP-0289: Release per-tenant connection quota before freeing session config.
    if (state.session_config) |cfg| {
        if (cfg.tenant_id) |tid| {
            if (tenant_quota.getGlobalQuotaManager()) |qm| {
                qm.releaseConnection(tid);
            }
        }
    }
    if (state.session_config) |*cfg| cfg.deinit();
    if (state.authenticated_user) |u| alloc.free(u);
    if (state.authenticated_password) |p| {
        std.crypto.secureZero(u8, @constCast(p)); // SECURITY (S7): Zero plaintext password before freeing
        alloc.free(p);
    }
    state.txn_manager.deinit();
    for (state.inserted_values.items) |item| {
        alloc.free(item.value);
    }
    state.inserted_values.deinit(alloc);
    state.catalog_schemas.deinit();
    state.catalog_graphs.deinit();
    var gt_iter = state.graph_types.iterator();
    while (gt_iter.next()) |entry| {
        alloc.free(entry.key_ptr.*);
        alloc.free(entry.value_ptr.name);
    }
    state.graph_types.deinit();
}

fn invalidateAuthenticatedSession(allocator: std.mem.Allocator, state: *server_state.ServerState) void {
    state.resetResult();
    if (state.in_txn) {
        const graph_name = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
        const lock_handle = graph_store.acquireGraphWriteLock(graph_name);
        defer graph_store.releaseGraphLock(lock_handle);
        const store_ptr = graph_store.getGlobalStore(allocator);
        txn_undo_log.getGlobalUndoLog(allocator).rollback(store_ptr) catch |err| {
            log.warn("Failed to rollback invalidated session transaction", &.{Attr.string("error", @errorName(err))});
        };
    }
    state.in_txn = false;
    state.txn_id = 0;
    state.current_user_id = null;
    if (state.authenticated_user) |u| {
        allocator.free(u);
        state.authenticated_user = null;
    }
    if (state.authenticated_password) |p| {
        std.crypto.secureZero(u8, @constCast(p));
        allocator.free(p);
        state.authenticated_password = null;
    }
    state.authenticated_role = null;
    state.authenticated_auth_version = 0;
    state.password_reset_required = false;
}

fn validateSessionAuth(allocator: std.mem.Allocator, state: *server_state.ServerState) !SessionAuthStatus {
    if (!user_mgmt.isAuthEnabled()) return .ok;
    const username = state.authenticated_user orelse return .missing;
    if (state.authenticated_auth_version == 0) return .ok;
    if (try user_mgmt.isSessionAuthCurrent(username, state.authenticated_auth_version)) {
        return .ok;
    }
    invalidateAuthenticatedSession(allocator, state);
    return .invalidated;
}

fn authorizeAdminSession(session_id: []const u8, allocator: std.mem.Allocator) !AdminSessionStatus {
    if (!user_mgmt.isAuthEnabled()) return .ok;
    if (session_id.len == 0) return .missing;
    const store = getSessionStore() orelse return .missing;
    const entry = store.getEntry(session_id) orelse {
        throttleInvalidSessionProbe();
        return .missing;
    };

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        .missing => return .missing,
        .invalidated => return .invalidated,
    }

    const role_raw = state.authenticated_role orelse return .forbidden;
    const role = @as(user_mgmt.Role, @enumFromInt(role_raw));
    if (role != .Admin) return .forbidden;
    if (state.authenticated_user == null) return .missing;
    return .ok;
}

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

fn updateTxnStateFromProgram(state: *server_state.ServerState, program: *const gql_ast.Program) void {
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
            state.txn_id = @intCast(compat_milliTimestamp());
        }
    }
}

fn encodeMessage(allocator: std.mem.Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch return error.OutOfMemory;
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    const result = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    return result;
}

pub const GeodeGrpcServer = struct {
    allocator: std.mem.Allocator,
    server: GrpcServer,
    session_store: *SessionStore,
    /// GAP-0518: Heap-allocated random session key (freed in deinit).
    grpc_session_key: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        cert_path: ?[]const u8,
        key_path: ?[]const u8,
        config: GrpcConfig,
    ) !GeodeGrpcServer {
        // GAP-0518: Generate a random session key per startup instead of a
        // hardcoded literal.  The 32-byte key is hex-encoded (64 chars) and
        // heap-allocated so it lives as long as the server.
        var grpc_session_key_raw: [32]u8 = undefined;
        compat_fillRandom(&grpc_session_key_raw);
        const grpc_session_key = try allocator.alloc(u8, 64);
        const hex_array = std.fmt.bytesToHex(grpc_session_key_raw, .lower);
        @memcpy(grpc_session_key, &hex_array);
        var server = try GrpcServer.init(allocator, std.Io.Threaded.global_single_threaded.io(), port, grpc_session_key);
        const allow_plaintext_fallback = shouldAllowGrpcPlaintextFallback(allocator);

        if (allow_plaintext_fallback) {
            server.on_tls_accept = grpc_tls.rawAccept;
            log.warn("gRPC plaintext enabled in Debug mode via GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK", &.{});
        }

        // Initialize TLS if cert and key are provided and plaintext mode is not forced.
        if (server.on_tls_accept == null) {
            if (cert_path) |cp| {
                if (key_path) |kp| {
                    // Create null-terminated strings for OpenSSL
                    const cert_z = try allocator.dupeZ(u8, cp);
                    defer allocator.free(cert_z);
                    const key_z = try allocator.dupeZ(u8, kp);
                    defer allocator.free(key_z);

                    grpc_tls.initTlsContext(cert_z, key_z) catch |err| {
                        if (!allow_plaintext_fallback) {
                            log.err("gRPC TLS init failed; refusing plaintext fallback", &.{
                                Attr.string("error", @errorName(err)),
                            });
                            return err;
                        }
                        log.warn("gRPC TLS init failed; plaintext fallback explicitly enabled", &.{
                            Attr.string("error", @errorName(err)),
                        });
                    };
                    if (grpc_tls.hasTlsContext()) {
                        server.on_tls_accept = grpc_tls.tlsAccept;
                        log.info("gRPC TLS enabled", &.{});
                    }
                }
            }
        }

        // Fail-closed by default: plaintext fallback requires explicit opt-in.
        if (server.on_tls_accept == null and allow_plaintext_fallback) {
            server.on_tls_accept = grpc_tls.rawAccept;
            log.warn("gRPC plaintext fallback enabled in Debug mode", &.{});
        } else if (server.on_tls_accept == null) {
            return error.TlsRequired;
        }

        const store = try allocator.create(SessionStore);
        store.* = SessionStore.init(allocator, config);
        setSessionStore(store);

        var self = GeodeGrpcServer{
            .allocator = allocator,
            .server = server,
            .session_store = store,
            .grpc_session_key = grpc_session_key,
        };

        try self.registerHandlers();
        return self;
    }

    pub fn deinit(self: *GeodeGrpcServer) void {
        self.session_store.deinit();
        self.allocator.destroy(self.session_store);
        setSessionStore(null);
        grpc_tls.deinitTlsContext();
        // GAP-0518: Securely zero and free the random session key.
        if (self.grpc_session_key) |key| {
            std.crypto.secureZero(u8, key);
            self.allocator.free(key);
        }
        self.server.deinit();
    }

    pub fn start(self: *GeodeGrpcServer) !void {
        log.info("Starting gRPC server", &.{});
        try self.server.start();
    }

    fn registerHandlers(self: *GeodeGrpcServer) !void {
        // grpc_zig routes only the first handler; use a packet wrapper to dispatch
        try self.server.handlers.append(self.allocator, .{
            .name = "Packet",
            .handler_fn = handlePacket,
        });
    }
};

fn buildPacketError(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    var resp = try buildErrorResponse(allocator, code, message, &.{}, &.{});
    defer resp.deinit(allocator);
    var packet = schema.ServerPacket{ .quic = .{ .execute = resp } };
    defer packet.deinit(allocator);
    return encodeMessage(allocator, packet);
}

/// Helper: send a unary gRPC response (HEADERS + DATA + TRAILERS).
fn sendUnaryResponse(trans: *GrpcTransport, response: []const u8) !void {
    try trans.writeMessage(response);
}

/// Helper: send a streaming gRPC response message.
fn sendStreamResponse(trans: *GrpcTransport, response: []const u8, is_first: bool) !void {
    try trans.writeStreamMessage(response, is_first);
}

fn handlePacket(request_bytes: []const u8, method: []const u8, trans: *GrpcTransport, allocator: std.mem.Allocator) anyerror!void {
    log.info("gRPC dispatch", &.{
        Attr.string("method", if (method.len > 0) method else "(empty)"),
        Attr.uint("payload_len", request_bytes.len),
    });

    // Standard gRPC: route by method path from HEADERS frame.
    if (method.len > 0) {
        if (std.mem.endsWith(u8, method, "/Handshake")) {
            const resp = try handleHandshake(request_bytes, trans, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Execute")) {
            return handleExecuteStreaming(request_bytes, trans, allocator);
        } else if (std.mem.endsWith(u8, method, "/Ping")) {
            const resp = try handlePing(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Begin")) {
            const resp = try handleBegin(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Commit")) {
            const resp = try handleCommit(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Rollback")) {
            const resp = try handleRollback(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Savepoint")) {
            // Issue #515: Savepoint handler (stub — matches QUIC behavior)
            const resp = try handleSavepoint(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/RollbackTo")) {
            const resp = try handleRollbackTo(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/CdcDiag")) {
            const resp = try handleCdcDiag(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/CdcCtrl")) {
            const resp = try handleCdcCtrl(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Backup")) {
            const resp = try handleBackup(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/Restore")) {
            const resp = try handleRestore(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else if (std.mem.endsWith(u8, method, "/UploadBackup")) {
            const resp = try handleUploadBackup(request_bytes, allocator);
            defer allocator.free(resp);
            return sendUnaryResponse(trans, resp);
        } else {
            log.warn("Unknown gRPC method", &.{});
            const err_resp = try buildPacketError(allocator, "0A000", "Unknown gRPC method");
            defer allocator.free(err_resp);
            return sendUnaryResponse(trans, err_resp);
        }
    }

    // Fallback: legacy ClientPacket-wrapped messages (custom gRPC clients)
    const resp = try handleLegacyPacket(request_bytes, trans, allocator);
    defer allocator.free(resp);
    return sendUnaryResponse(trans, resp);
}

/// Build a data page ExecutionResponse directly (avoids decode+re-encode cycle).
/// Returns encoded ExecutionResponse bytes and whether this is the final page.
const PageResult = struct { bytes: []u8, is_final: bool };
const grpc_stream_page_size: usize = query_runner.default_page_size;

fn buildStreamDataPage(session_id: []const u8, allocator: std.mem.Allocator) !PageResult {
    const store = getSessionStore() orelse {
        var resp = try buildErrorResponse(allocator, "58000", "Server not initialized", &.{}, &.{});
        defer resp.deinit(allocator);
        return .{ .bytes = try encodeMessage(allocator, resp), .is_final = true };
    };

    const entry = store.getEntry(session_id) orelse {
        throttleInvalidSessionProbe();
        var resp = try buildErrorResponse(allocator, "28000", "Unknown session", &.{}, &.{});
        defer resp.deinit(allocator);
        return .{ .bytes = try encodeMessage(allocator, resp), .is_final = true };
    };

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;

    const result_ptr = if (state.active_result_values) |*res| res else {
        var resp = try buildErrorResponse(allocator, "02000", "No active result set", &.{}, &.{});
        defer resp.deinit(allocator);
        return .{ .bytes = try encodeMessage(allocator, resp), .is_final = true };
    };

    const start = state.result_page_index;

    // Arena allocator for data page serialization (Issue #446):
    // Per-value string dups become bump allocations; arena bulk-frees after encode.
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();
    const pa = page_arena.allocator();

    const page = try proto_util.buildDataPage(pa, result_ptr, start, grpc_stream_page_size, state.result_ordered, state.result_order_keys);
    state.result_page_index += page.rows.items.len;
    const is_final = page.final;

    const status = try proto_util.buildStatus(pa, "00000", result_ptr.flags.items);
    const resp = schema.ExecutionResponse{
        .status = status,
        .payload = .{ .page = page },
    };
    // resp.deinit not needed: arena handles all proto object memory

    const encoded_tmp = try encodeMessage(pa, resp);
    const encoded = try allocator.dupe(u8, encoded_tmp);

    if (is_final) {
        state.resetResult();
    }

    return .{ .bytes = encoded, .is_final = is_final };
}

/// Issue #514: Lock-free variant that operates on an already-locked state pointer.
/// Caller MUST hold entry.mutex for the entire streaming loop.
fn buildStreamDataPageLocked(state: *server_state.ServerState, allocator: std.mem.Allocator) !PageResult {
    const result_ptr = if (state.active_result_values) |*res| res else {
        var resp = try buildErrorResponse(allocator, "02000", "No active result set", &.{}, &.{});
        defer resp.deinit(allocator);
        return .{ .bytes = try encodeMessage(allocator, resp), .is_final = true };
    };

    const start = state.result_page_index;

    // Arena allocator for data page serialization (Issue #446)
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();
    const pa = page_arena.allocator();

    const page = try proto_util.buildDataPage(pa, result_ptr, start, grpc_stream_page_size, state.result_ordered, state.result_order_keys);
    state.result_page_index += page.rows.items.len;
    const is_final = page.final;

    const status = try proto_util.buildStatus(pa, "00000", result_ptr.flags.items);
    const resp = schema.ExecutionResponse{
        .status = status,
        .payload = .{ .page = page },
    };

    const encoded_tmp = try encodeMessage(pa, resp);
    const encoded = try allocator.dupe(u8, encoded_tmp);

    if (is_final) {
        state.resetResult();
    }

    return .{ .bytes = encoded, .is_final = is_final };
}

/// Handle Execute as a server-streaming RPC: send schema, then all data pages.
/// Issue #479: Added error recovery to prevent leaving HTTP/2 streams in an
/// inconsistent state when writes fail (e.g. client disconnect, partial write).
fn handleExecuteStreaming(request_bytes: []const u8, trans: *GrpcTransport, allocator: std.mem.Allocator) !void {
    // Get the schema/first response from handleExecute
    const exec_resp = try handleExecute(request_bytes, allocator);
    defer allocator.free(exec_resp);

    // Send first streaming message (with HEADERS).
    // If this fails, the connection is broken — propagate the error so the
    // connection loop can detect it and close cleanly.
    sendStreamResponse(trans, exec_resp, true) catch |err| {
        log.err("gRPC streaming: failed to send initial response", &.{
            Attr.string("error", @errorName(err)),
        });
        return err;
    };

    // Check if the response is EXPLAIN, PROFILE, or error — these have no data pages to pull
    var skip_pages = false;
    blk: {
        var resp_reader: std.Io.Reader = .fixed(exec_resp);
        var resp = protobuf.decode(schema.ExecutionResponse, &resp_reader, allocator) catch {
            skip_pages = true;
            break :blk;
        };
        defer resp.deinit(allocator);
        if (resp.payload) |payload| {
            switch (payload) {
                .explain, .profile, .@"error" => {
                    skip_pages = true;
                },
                else => {},
            }
        }
    }

    if (!skip_pages) {
        // Extract session_id from the request for data pages
        var reader: std.Io.Reader = .fixed(request_bytes);
        var req = protobuf.decode(schema.ExecuteRequest, &reader, allocator) catch {
            trans.endStream() catch {};
            return;
        };
        defer req.deinit(allocator);

        // Issue #514: Hold session mutex for the ENTIRE streaming loop to prevent
        // concurrent Execute from calling resetResult() mid-stream (use-after-free).
        const store = getSessionStore() orelse {
            trans.endStream() catch {};
            return;
        };
        const entry = store.getEntry(req.session_id) orelse {
            throttleInvalidSessionProbe();
            trans.endStream() catch {};
            return;
        };

        entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Pull all data pages under a single lock scope
        var page_count: usize = 0;
        var stream_error = false;
        while (page_count < 1000) : (page_count += 1) { // safety limit
            const result = buildStreamDataPageLocked(entry.state, allocator) catch |err| {
                log.err("gRPC streaming: failed to build data page", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("page", page_count),
                });
                stream_error = true;
                break;
            };
            defer allocator.free(result.bytes);

            sendStreamResponse(trans, result.bytes, false) catch |err| {
                log.err("gRPC streaming: write failed mid-stream", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("page", page_count),
                });
                stream_error = true;
                break;
            };
            if (result.is_final) break;
        }

        if (stream_error) {
            // Try to end the stream gracefully so the client gets a clean close.
            // If this also fails, the connection is broken and the connection
            // loop will detect it on the next readMessage.
            trans.endStream() catch {};
            return;
        }
    }

    // End the stream normally
    trans.endStream() catch |err| {
        log.err("gRPC streaming: failed to send end-of-stream", &.{
            Attr.string("error", @errorName(err)),
        });
    };
}

fn handleLegacyPacket(request_bytes: []const u8, trans: *GrpcTransport, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var packet = protobuf.decode(schema.ClientPacket, &reader, allocator) catch |err| {
        log.err("Failed to decode gRPC packet", &.{Attr.string("error", @errorName(err))});
        return buildPacketError(allocator, "22023", "Invalid client packet");
    };
    defer packet.deinit(allocator);

    const msg = packet.quic orelse {
        return buildPacketError(allocator, "22023", "Missing client message");
    };

    return switch (msg) {
        .hello => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleHandshake(req_bytes, trans, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.HelloResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .hello = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .execute => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleExecute(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.ExecutionResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .execute = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .pull => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handlePull(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.PullResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .pull = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .ping => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handlePing(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.PingResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .ping = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .begin => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleBegin(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.BeginResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .begin = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .commit => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleCommit(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.CommitResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .commit = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .rollback => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleRollback(req_bytes, allocator);
            defer allocator.free(resp_bytes);

            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.RollbackResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .rollback = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        // Issue #515: Route 7 previously-unsupported message types through handlers
        .savepoint => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleSavepoint(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.SavepointResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .savepoint = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .rollback_to => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleRollbackTo(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.RollbackToResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .rollback_to = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .cdc_diag => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleCdcDiag(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.CdcDiagnosticsResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .cdc_diag = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .cdc_ctrl => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleCdcCtrl(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.CdcControlResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .cdc_ctrl = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .backup => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleBackup(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.BackupResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .backup = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .restore => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleRestore(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.RestoreResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .restore = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
        .upload_backup => |req| blk: {
            const req_bytes = try encodeMessage(allocator, req);
            defer allocator.free(req_bytes);
            const resp_bytes = try handleUploadBackup(req_bytes, allocator);
            defer allocator.free(resp_bytes);
            var resp_reader: std.Io.Reader = .fixed(resp_bytes);
            const resp = try protobuf.decode(schema.UploadBackupResponse, &resp_reader, allocator);
            var out = schema.ServerPacket{ .quic = .{ .upload_backup = resp } };
            defer out.deinit(allocator);
            break :blk encodeMessage(allocator, out);
        },
    };
}

fn handlePing(_: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const response = schema.PingResponse{ .ok = true };
    return encodeMessage(allocator, response);
}

/// Extract peer IP address string from a gRPC transport's underlying socket.
/// Returns a stack-allocated formatted IP string, or "unknown" on failure.
fn getPeerIp(trans: *GrpcTransport) [45]u8 {
    var buf: [45]u8 = .{0} ** 45;
    var addr: std.posix.sockaddr.storage = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(trans.stream.socket.handle, @ptrCast(&addr), &addr_len) catch {
        @memcpy(buf[0..7], "unknown");
        return buf;
    };
    // Zig 0.16 compat: Io.net.IpAddress.initPosix was removed. Placeholder
    // until the address-formatting helper is reintroduced.
    @memcpy(buf[0..7], "unknown");
    return buf;
}

/// Return a slice of the peer IP buffer up to the first null byte.
fn peerIpSlice(buf: *const [45]u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

/// Validate federation HELLO using GEODE_CLUSTER_TOKEN (parity with QUIC handler).
/// GAP-0284 / GAP-0490: Both nodes must share the same cluster token.
/// Returns true only if username is "geode-cluster" AND password matches token.
// CANARY: REQ=REQ-GAP-0284-FEDERATION-GRPC-AUTH; FEATURE="FederationAuth"; ASPECT=GrpcServerValidation; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
fn validateFederationAuth(username: []const u8, password: []const u8) bool {
    if (!std.mem.eql(u8, username, "geode-cluster")) return false;
    const expected = if (comptime builtin.os.tag != .windows) posixGetenv("GEODE_CLUSTER_TOKEN") else null;
    const expected_tok = expected orelse return false;
    if (expected_tok.len == 0 or password.len == 0) return false;
    // SEC-07: No early length check — pad both independently to prevent length-leak timing
    var buf_a: [256]u8 = [_]u8{0} ** 256;
    var buf_b: [256]u8 = [_]u8{0} ** 256;
    const n_pw = @min(password.len, 256);
    const n_ex = @min(expected_tok.len, 256);
    @memcpy(buf_a[0..n_pw], password[0..n_pw]);
    @memcpy(buf_b[0..n_ex], expected_tok[0..n_ex]);
    return std.crypto.timing_safe.eql([256]u8, buf_a, buf_b);
}

/// Parse an ALTER USER <name> SET PASSWORD '<pwd>' statement from raw query text.
/// Returns the extracted username and new password, or null if the query doesn't match.
/// GAP-0284: Parity with QUIC handler's parseAlterUserSetPassword.
// CANARY: REQ=REQ-GAP-0284-ALTER-USER-GRPC; FEATURE="PasswordResetEnforcement"; ASPECT=GrpcAlterUserParse; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
fn parseAlterUserSetPassword(query: []const u8) ?struct { username: []const u8, new_password: []const u8 } {
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
/// a SecurityManager instance. Returns an error message string if the password
/// fails validation, or null if it passes.
/// GAP-0284: Parity with QUIC handler's validatePasswordFallback.
// CANARY: REQ=REQ-GAP-0284-PWD-VALIDATE-GRPC; FEATURE="PasswordPolicyEnforcement"; ASPECT=GrpcFallbackValidation; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
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

fn handleHandshake(request_bytes: []const u8, trans: *GrpcTransport, allocator: std.mem.Allocator) ![]u8 {
    log.debug("gRPC Handshake", &.{Attr.uint("request_bytes_len", request_bytes.len)});

    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.HelloRequest, &reader, allocator) catch |err| {
        log.err("Failed to decode HELLO request", &.{Attr.string("error", @errorName(err))});
        const resp = schema.HelloResponse{
            .success = false,
            .session_id = "",
            .error_message = "Invalid request",
            .capabilities = std.ArrayList([]const u8).empty,
        };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    log.debug("gRPC Handshake decoded", &.{
        Attr.uint("username_len", req.username.len),
        Attr.uint("password_len", req.password.len),
    });

    const store = getSessionStore() orelse {
        const resp = schema.HelloResponse{
            .success = false,
            .session_id = "",
            .error_message = "Server not initialized",
            .capabilities = std.ArrayList([]const u8).empty,
        };
        return encodeMessage(allocator, resp);
    };

    var caps = std.ArrayList([]const u8).initCapacity(allocator, 3) catch return error.OutOfMemory;
    try caps.append(allocator, try allocator.dupe(u8, "GRPC"));
    try caps.append(allocator, try allocator.dupe(u8, "PROTOBUF"));
    try caps.append(allocator, try allocator.dupe(u8, "TLS1.3"));

    // S12: Use peer IP as rate limiter key (not attacker-controlled username).
    // This matches the QUIC handler which uses peer_ip at quic_connection_handler.zig:1301.
    const peer_ip_buf = getPeerIp(trans);
    const peer_ip = peerIpSlice(&peer_ip_buf);

    // S6: Check auth rate limiter before authentication attempt (parity with QUIC handler).
    if (auth_rate_limiter_mod.getGlobalRateLimiter()) |limiter| {
        if (limiter.isLocked(peer_ip)) {
            const resp = schema.HelloResponse{
                .success = false,
                .session_id = "",
                .error_message = "Too many failed authentication attempts. Try again later.",
                .capabilities = caps,
            };
            return encodeMessage(allocator, resp);
        }
    }

    // GAP-0284: Federation inter-node authentication via cluster token — fast-path.
    // Must be checked BEFORE normal user auth to allow federation when auth is enabled.
    // CANARY: REQ=REQ-GAP-0284-FEDERATION-GRPC-WIRE; FEATURE="FederationAuth"; ASPECT=GrpcHelloCheck; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
    if (validateFederationAuth(req.username, req.password)) {
        log.info("Federation node authenticated via cluster token (gRPC)", &.{
            Attr.string("client", req.client_name),
        });
        // Grant federation-level session with ReadWrite role
        const session_id = try store.createSession(req.username, "", .ReadWrite, req.tenant_id, null, false, 0);
        const resp = schema.HelloResponse{
            .success = true,
            .session_id = try allocator.dupe(u8, session_id),
            .error_message = "",
            .capabilities = caps,
        };
        return encodeMessage(allocator, resp);
    }

    if (user_mgmt.isAuthEnabled()) {
        if (req.username.len == 0 or req.password.len == 0) {
            // S6: Record failure for empty credentials.
            if (auth_rate_limiter_mod.getGlobalRateLimiter()) |limiter| {
                limiter.recordFailure(peer_ip);
            }
            const resp = schema.HelloResponse{
                .success = false,
                .session_id = "",
                .error_message = "Authentication required",
                .capabilities = caps,
            };
            return encodeMessage(allocator, resp);
        }
        const auth_result = user_mgmt.authenticate(req.username, req.password) catch {
            // S6: Record failure for bad credentials.
            if (auth_rate_limiter_mod.getGlobalRateLimiter()) |limiter| {
                limiter.recordFailure(peer_ip);
            }
            const resp = schema.HelloResponse{
                .success = false,
                .session_id = "",
                .error_message = "Authentication failed",
                .capabilities = caps,
            };
            return encodeMessage(allocator, resp);
        };

        // S6: Successful authentication — reset failure counter.
        if (auth_rate_limiter_mod.getGlobalRateLimiter()) |limiter| {
            limiter.recordSuccess(peer_ip);
        }
        // CANARY: REQ=REQ-DSN-GRAPH-BIND-005; FEATURE="DSNGraphBinding"; ASPECT=GrpcGraphResolution; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
        // Resolve graph from HELLO request — validate, auto-create, bind session
        var resolved_graph: ?[]const u8 = null;
        if (req.graph) |requested_graph| {
            if (requested_graph.len > 0) {
                // Validate graph name: max 128 chars, alphanumeric + underscore only
                if (requested_graph.len > 128) {
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Invalid graph name: too long (max 128 characters)",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                }
                for (requested_graph) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '_') {
                        const resp = schema.HelloResponse{
                            .success = false,
                            .session_id = "",
                            .error_message = "Invalid graph name: must contain only alphanumeric characters and underscores",
                            .capabilities = caps,
                        };
                        return encodeMessage(allocator, resp);
                    }
                }
                const gstore = graph_store.getGlobalStore(allocator);
                const cat = try execution.ensureCatalogInstance(allocator);

                const in_store = gstore.graphExists(requested_graph);
                const in_catalog = cat.hasGraph(requested_graph);

                if (in_store or in_catalog) {
                    // GAP-0283: Graph-scoped RBAC authorization check before binding (parity with QUIC handler).
                    // CANARY: REQ=REQ-MULTI-GRAPH-RBAC-WIRE-003; FEATURE="GraphRBACEnforcement"; ASPECT=GrpcGraphAuth; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
                    const rbac_allowed = rbac_blk: {
                        if (auth_result.role == .Admin) {
                            break :rbac_blk true;
                        }
                        if (multi_graph_security.getGlobalPolicy()) |rbac| {
                            const uid = std.hash.Wyhash.hash(0, req.username);
                            if (rbac.hasPermission(uid, requested_graph, "graph", .read)) break :rbac_blk true;
                            const key = multi_graph_security.GraphRoleKey.init(uid, requested_graph);
                            if (rbac.graph_user_roles.get(key)) |_| {
                                break :rbac_blk false; // Explicit assignment but no read -> deny
                            }
                        }
                        break :rbac_blk true; // No explicit denial -> allow
                    };
                    if (!rbac_allowed) {
                        const resp = schema.HelloResponse{
                            .success = false,
                            .session_id = "",
                            .error_message = "Access denied: insufficient permissions for graph",
                            .capabilities = caps,
                        };
                        return encodeMessage(allocator, resp);
                    }
                    resolved_graph = requested_graph;
                } else {
                    // Graph does not exist — check if user can create it
                    const can_create = auth_result.role == .Admin or auth_result.role == .ReadWrite;

                    if (can_create) {
                        _ = gstore.createGraph(requested_graph) catch |err| {
                            log.err("Graph auto-creation failed", &.{
                                Attr.string("graph", requested_graph),
                                Attr.string("error", @errorName(err)),
                            });
                            const resp = schema.HelloResponse{
                                .success = false,
                                .session_id = "",
                                .error_message = "Failed to create graph",
                                .capabilities = caps,
                            };
                            return encodeMessage(allocator, resp);
                        };
                        const uuid = graph_store.GraphStore.getGraphUuid(requested_graph) orelse {
                            const resp = schema.HelloResponse{
                                .success = false,
                                .session_id = "",
                                .error_message = "Graph created without persistent UUID",
                                .capabilities = caps,
                            };
                            return encodeMessage(allocator, resp);
                        };
                        cat.addGraphWithUuid(requested_graph, uuid) catch |err| {
                            gstore.dropGraph(requested_graph) catch {};
                            log.err("Failed to persist graph metadata", &.{
                                Attr.string("graph", requested_graph),
                                Attr.string("error", @errorName(err)),
                            });
                            const resp = schema.HelloResponse{
                                .success = false,
                                .session_id = "",
                                .error_message = "Failed to persist graph metadata",
                                .capabilities = caps,
                            };
                            return encodeMessage(allocator, resp);
                        };
                        resolved_graph = requested_graph;
                    } else {
                        const resp = schema.HelloResponse{
                            .success = false,
                            .session_id = "",
                            .error_message = "Graph does not exist and user lacks permission to create it",
                            .capabilities = caps,
                        };
                        return encodeMessage(allocator, resp);
                    }
                }
            }
        }

        // GAP-0284: Set FLE role from HELLO request with injection validation (parity with QUIC handler).
        // Always reset role on new connection to prevent stale role leakage.
        if (req.role) |requested_role| {
            if (requested_role.len > 0) {
                // Validate role: only [a-zA-Z0-9_-] allowed — reject semicolons, commas, wildcards
                var role_valid = true;
                for (requested_role) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                        role_valid = false;
                        break;
                    }
                }
                if (role_valid) {
                    fle_integration.setCurrentUserRole(requested_role);
                } else {
                    log.warn("Rejected invalid FLE role: contains illegal characters", &.{});
                    fle_integration.setCurrentUserRole(null);
                }
            } else {
                fle_integration.setCurrentUserRole(null);
            }
        } else {
            fle_integration.setCurrentUserRole(null);
        }

        const session_id = try store.createSession(req.username, req.password, auth_result.role, req.tenant_id, resolved_graph, auth_result.password_reset_required, auth_result.auth_version);
        const resp = schema.HelloResponse{
            .success = true,
            .session_id = try allocator.dupe(u8, session_id),
            .error_message = "",
            .capabilities = caps,
            .password_reset_required = auth_result.password_reset_required,
            .graph = if (resolved_graph) |g| try allocator.dupe(u8, g) else null,
        };
        return encodeMessage(allocator, resp);
    }

    // CANARY: REQ=REQ-DSN-GRAPH-BIND-006; FEATURE="DSNGraphBinding"; ASPECT=GrpcNoAuthGraph; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
    // No-auth path: auto-create graph if needed
    var noauth_resolved_graph: ?[]const u8 = null;
    if (req.graph) |requested_graph| {
        if (requested_graph.len > 0) {
            // Validate graph name: max 128 chars, alphanumeric + underscore only
            if (requested_graph.len > 128) {
                const resp = schema.HelloResponse{
                    .success = false,
                    .session_id = "",
                    .error_message = "Invalid graph name: too long (max 128 characters)",
                    .capabilities = caps,
                };
                return encodeMessage(allocator, resp);
            }
            for (requested_graph) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '_') {
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Invalid graph name: must contain only alphanumeric characters and underscores",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                }
            }
            const gstore = graph_store.getGlobalStore(allocator);
            const cat = try execution.ensureCatalogInstance(allocator);

            const in_store = gstore.graphExists(requested_graph);
            const in_catalog = cat.hasGraph(requested_graph);

            if (!in_store and !in_catalog) {
                // No auth = always allow auto-create
                _ = gstore.createGraph(requested_graph) catch |err| {
                    log.err("Graph auto-creation failed (no-auth)", &.{
                        Attr.string("graph", requested_graph),
                        Attr.string("error", @errorName(err)),
                    });
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Failed to create graph",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                };
                const uuid = graph_store.GraphStore.getGraphUuid(requested_graph) orelse {
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Graph created without persistent UUID",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                };
                cat.addGraphWithUuid(requested_graph, uuid) catch |err| {
                    gstore.dropGraph(requested_graph) catch {};
                    log.err("Failed to persist graph metadata (no-auth)", &.{
                        Attr.string("graph", requested_graph),
                        Attr.string("error", @errorName(err)),
                    });
                    const resp = schema.HelloResponse{
                        .success = false,
                        .session_id = "",
                        .error_message = "Failed to persist graph metadata",
                        .capabilities = caps,
                    };
                    return encodeMessage(allocator, resp);
                };
            }
            noauth_resolved_graph = requested_graph;
        }
    }

    const session_id = try store.createSession("", "", null, req.tenant_id, noauth_resolved_graph, false, 0);
    const resp = schema.HelloResponse{
        .success = true,
        .session_id = try allocator.dupe(u8, session_id),
        .error_message = "",
        .capabilities = caps,
        .graph = if (noauth_resolved_graph) |g| try allocator.dupe(u8, g) else null,
    };
    return encodeMessage(allocator, resp);
}

fn handleExecute(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.ExecuteRequest, &reader, allocator) catch |err| {
        log.err("Failed to decode Execute request", &.{Attr.string("error", @errorName(err))});
        var resp = try buildErrorResponse(allocator, "22023", "Invalid execute request", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        var resp = try buildErrorResponse(allocator, "28000", "Missing session_id", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    }

    const store = getSessionStore() orelse {
        var resp = try buildErrorResponse(allocator, "58000", "Server not initialized", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };

    const entry = store.getEntry(req.session_id) orelse {
        throttleInvalidSessionProbe();
        var resp = try buildErrorResponse(allocator, "28000", "Unknown session", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;

    state.resetResult();

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        .missing => {
            var resp = try buildErrorResponse(allocator, "28000", "Authentication required", &.{}, &.{});
            defer resp.deinit(allocator);
            return encodeMessage(allocator, resp);
        },
        .invalidated => {
            var resp = try buildErrorResponse(allocator, "28000", "Session invalidated due to credential or role change", &.{}, &.{});
            defer resp.deinit(allocator);
            return encodeMessage(allocator, resp);
        },
    }

    // GAP-0284: Handle ALTER USER SET PASSWORD — intercept before GQL parser since
    // ALTER USER is not part of GQL syntax. Works both during forced
    // password reset and for normal password changes (parity with QUIC handler).
    // CANARY: REQ=REQ-GAP-0284-ALTER-USER-GRPC-WIRE; FEATURE="PasswordResetEnforcement"; ASPECT=GrpcExecuteIntercept; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
    {
        const trimmed = std.mem.trim(u8, req.query, " \t\r\n");
        if (parseAlterUserSetPassword(trimmed)) |parsed| {
            // Verify the user is changing their own password
            if (state.authenticated_user) |auth_user| {
                if (!std.mem.eql(u8, auth_user, parsed.username)) {
                    var resp = try buildErrorResponse(allocator, "42501", "You can only change your own password", &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                }
            } else {
                var resp = try buildErrorResponse(allocator, "42501", "Authentication required to change passwords", &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            }

            // Validate password against SecurityManager policy BEFORE updating
            if (state.security_manager) |sm| {
                sm.validatePassword(parsed.new_password) catch |err| {
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
                    var resp = try buildErrorResponse(allocator, "28P01", msg, &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                };
            } else {
                // Fallback policy enforcement when SecurityManager is null
                if (validatePasswordFallback(parsed.new_password)) |msg| {
                    var resp = try buildErrorResponse(allocator, "28P01", msg, &.{}, &.{});
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                }
            }

            user_mgmt.updateUserPassword(allocator, parsed.username, parsed.new_password) catch |err| {
                const msg = switch (err) {
                    error.PasswordReuse => "New password must not match the current password",
                    else => "Failed to update password",
                };
                var resp = try buildErrorResponse(allocator, "28P01", msg, &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            };

            // Persist the password change to the auth graph store so it survives restarts.
            if (state.security_manager) |sm| {
                if (sm.getUserIdByUsername(parsed.username)) |user_id| {
                    sm.updatePassword(user_id, parsed.new_password) catch |err| {
                        log.warn("Failed to persist password change to auth graph", &.{
                            Attr.string("username", parsed.username),
                            Attr.string("error", @errorName(err)),
                        });
                    };
                }
            }

            state.password_reset_required = false;

            // Send success response as a status-only execution result
            const status = try proto_util.buildStatus(allocator, "00000", &.{});
            var resp = schema.ExecutionResponse{
                .status = status,
                .payload = null,
            };
            defer resp.deinit(allocator);
            return encodeMessage(allocator, resp);
        }
    }

    // GAP-0284: Block all other queries when password reset is required (parity with QUIC handler).
    // CANARY: REQ=REQ-GAP-0284-PWD-RESET-BLOCK-GRPC; FEATURE="PasswordResetEnforcement"; ASPECT=GrpcExecuteBlock; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
    if (state.password_reset_required) {
        var resp = try buildErrorResponse(allocator, "08P01", "Password reset required. Change password with: ALTER USER <username> SET PASSWORD '<new_password>'", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    }

    const bindings = proto_util.parseParams(allocator, req.params.items) catch |err| {
        var resp = try buildErrorResponse(allocator, "22023", @errorName(err), &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };
    defer proto_util.freeParamBindings(allocator, bindings);

    const order_keys_expr = server_flags.getOrderKeysExpr();
    const parse_opts = geode.ParseOptions{
        .ident_order_only = !order_keys_expr,
        .forbid_orderby_calls = !order_keys_expr,
    };

    var normalized = try query_traits.normalizeExplainCalibrated(allocator, req.query);
    defer normalized.deinit(allocator);

    const query_text = normalized.text;
    if (state.query_text) |qt| allocator.free(qt);
    state.query_text = try allocator.dupe(u8, query_text);

    const outcome = try geode.parseGqlOutcome(query_text, allocator, parse_opts);
    switch (outcome) {
        .Err => |err_info| {
            const msg = if (err_info.has_double_dash_comment)
                diagnostics.defaultMessage(.GB02CommentDisabled)
            else
                err_info.msg;
            var resp = try buildErrorResponse(allocator, "42000", msg, &.{}, &.{});
            defer resp.deinit(allocator);
            return encodeMessage(allocator, resp);
        },
        .Ok => |parse_result_const| {
            var parse_result = parse_result_const;
            defer parse_result.deinit();

            if (parse_result.has_double_dash_comment) {
                var resp = try buildErrorResponse(allocator, "42000", diagnostics.defaultMessage(.GB02CommentDisabled), &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
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

            const catalog = try execution.ensureCatalogInstance(allocator);

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
                                            catalog.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
                                            defer catalog.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
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
                                                catalog.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
                                                defer catalog.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
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
            var exec_context = execution.ExecutionContext{
                .catalog = catalog,
                .user = state.authenticated_user,
                .role = role,
                .token = null,
                .strict_offset_validation = false,
                .session_state = if (state.exec_session) |*s| s else null,
                .transaction_state = if (state.in_txn) .Active else .None,
                .query_param_names = bindings.names,
                .query_param_values = bindings.values,
                .graph_bound = state.graph_bound,
                // GAP-0281: Thread session tenant_id into execution context for FLE hooks
                .tenant_id = if (state.session_config) |cfg| cfg.tenant_id else null,
                .pending_index_rebuilds = null,
            };

            var pending_index_rebuilds = std.StringHashMap(void).init(allocator);
            defer {
                var iter = pending_index_rebuilds.keyIterator();
                while (iter.next()) |k| allocator.free(k.*);
                pending_index_rebuilds.deinit();
            }
            exec_context.pending_index_rebuilds = &pending_index_rebuilds;
            exec_context.pending_index_rebuilds_allocator = allocator;

            var flags = std.ArrayList([]const u8).initCapacity(allocator, 8) catch return error.OutOfMemory;
            defer flags.deinit(allocator);
            var base_flags_buf: server_flags.BaseFlagsBuf = undefined;
            const base_flags = server_flags.computeBaseFlags(&base_flags_buf, ordered, distinct);
            for (base_flags) |flag| {
                try appendFlagIfMissing(allocator, &flags, flag);
            }
            if (traits.has_union) {
                try appendFlagIfMissing(allocator, &flags, server_flags.F_UNION_PHASES);
            }
            if (heur_index) {
                try appendFlagIfMissing(allocator, &flags, server_flags.F_HEUR_INDEX);
            }
            if (parse_result.has_double_solidus_comment) {
                try appendFlagIfMissing(allocator, &flags, "GB03:DoubleSolidusComment");
            }

            // GAP-0289: Enforce per-tenant query concurrency quota before execution.
            const grpc_query_tenant = if (state.session_config) |cfg| cfg.tenant_id else null;
            var grpc_query_quota_acquired = false;
            if (grpc_query_tenant) |tid| {
                if (tenant_quota.getGlobalQuotaManager()) |qm| {
                    qm.acquireQuery(tid) catch {
                        var resp = try buildErrorResponse(allocator, "42000", "Query quota exceeded for tenant", &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };
                    grpc_query_quota_acquired = true;
                }
            }
            defer if (grpc_query_quota_acquired) {
                if (grpc_query_tenant) |tid| {
                    if (tenant_quota.getGlobalQuotaManager()) |qm| {
                        qm.releaseQuery(tid);
                    }
                }
            };

            // #564: Acquire the appropriate store lock based on query type.
            // Without this, gRPC queries ran with no synchronization, allowing
            // concurrent mutations to corrupt shared HashMaps and ArrayLists.
            // P1: Per-graph locking — queries against different graphs no longer serialize.
            const needs_store_lock = analysis.kind != .explain;
            const is_mutation = needs_store_lock and query_traits.isMutatingProgram(&parse_result.program);

            // GAP-0526: Enforce write-permission check before mutation execution.
            // ReadOnly and User roles lack Write permission and must be denied.
            if (is_mutation) {
                if (state.authenticated_role) |role_u8| {
                    const auth_role = @as(user_mgmt.Role, @enumFromInt(role_u8));
                    if (!user_mgmt.hasPermission(auth_role, .Write)) {
                        var resp = try buildErrorResponse(allocator, "42501", "Permission denied: insufficient privileges for data modification", &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    }
                }
            }

            const query_graph_name = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
            var graph_lock_handle: ?graph_store.GraphLockHandle = null;
            if (needs_store_lock) {
                // GAP-0752: Route non-mutating queries through the shared
                // reader lock so concurrent MATCH-by-property traffic no
                // longer serializes behind the exclusive writer lock. The
                // GAP-0001 HashMap rehash race (CWE-362/CWE-416) was caused
                // by mutations running under shared locks; mutations still
                // acquire the exclusive writer lock below, so reads under
                // the shared lock are safe.
                graph_lock_handle = if (is_mutation)
                    graph_store.acquireGraphWriteLock(query_graph_name)
                else
                    graph_store.acquireGraphReadLock(query_graph_name);
            }
            var lock_released = false;
            defer {
                if (!lock_released) {
                    if (graph_lock_handle) |h| {
                        // GAP-0511: Release lock before index rebuild
                        graph_store.releaseGraphLock(h);
                        rebuildPendingIndexes(allocator, query_graph_name, &pending_index_rebuilds);
                    }
                }
            }

            switch (analysis.kind) {
                .explain => {
                    const explain_msg = blk: {
                        if (analysis.target) |target| {
                            if (target.* == .Query) {
                                var planned_query = target.Query;
                                if (try planned_read_runtime.buildPlanIfSupported(allocator, &planned_query, exec_context)) |plan| {
                                    var owned_plan = plan;
                                    defer owned_plan.deinit(allocator);
                                    break :blk try explain_payload.buildExplainPayloadFromPlan(allocator, owned_plan);
                                }
                            }
                        }
                        break :blk try explain_payload.buildExplainPayload(
                            allocator,
                            traits,
                            analysis.union_part_count,
                            normalized.explain_calibrated,
                        );
                    };

                    const status = try proto_util.buildStatus(allocator, "00000", flags.items);
                    var resp = schema.ExecutionResponse{
                        .status = status,
                        .payload = .{ .explain = explain_msg },
                    };
                    defer resp.deinit(allocator);
                    return encodeMessage(allocator, resp);
                },
                .profile => {
                    const target_stmt = analysis.target orelse {
                        var resp = try buildErrorResponse(allocator, "0A000", "PROFILE target missing", &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };

                    if (target_stmt.* == .Query) {
                        var planned_query = target_stmt.Query;
                        if (try planned_read_runtime.executeProfiledIfSupported(
                            allocator,
                            &planned_query,
                            exec_context,
                            bindings.names,
                            bindings.values,
                            true,
                        )) |planned| {
                            var owned_planned = planned;
                            defer owned_planned.deinitMetadata(allocator);
                            defer owned_planned.result.deinit(allocator);

                            for (flags.items) |flag| {
                                try appendFlagToResult(allocator, &owned_planned.result, flag);
                            }

                            const store_ptr = graph_store.getGlobalStore(allocator);
                            const profile_node_count: u64 = @intCast(store_ptr.getNodeCount());
                            const profile_edge_count: u64 = @intCast(store_ptr.getEdgeCount());
                            const profile_is_dirty = store_ptr.isDirty();

                            if (needs_store_lock) {
                                if (graph_lock_handle) |h| {
                                    // GAP-0511: Release lock before index rebuild
                                    graph_store.releaseGraphLock(h);
                                    lock_released = true;
                                    rebuildPendingIndexes(allocator, query_graph_name, &pending_index_rebuilds);
                                }
                            }

                            if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                                if (state.authenticated_user) |auth_user| {
                                    const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                                    _ = rls_filter.applyRLSFilter(allocator, &owned_planned.result, rls_engine, auth_user, rls_graph);
                                }
                            }

                            const profile_msg = try profile_payload.buildProfilePayloadFromTrace(allocator, owned_planned.plan, owned_planned.trace, .{
                                .compact = store.config.compact_profile,
                                .include_mem_curve = store.config.memcurve_profile,
                                .disable_estimates = store.config.disable_estimates,
                                .spill_threshold = state.query_mem_limit_bytes,
                                .committed_txns = state.global_commit_ts,
                                .graph_store_nodes = profile_node_count,
                                .graph_store_edges = profile_edge_count,
                                .graph_store_dirty = profile_is_dirty,
                                .flagger_findings = owned_planned.result.flags.items,
                                .union_part_count = analysis.union_part_count,
                            });

                            const status = try proto_util.buildStatus(allocator, "00000", owned_planned.result.flags.items);
                            var resp = schema.ExecutionResponse{
                                .status = status,
                                .payload = .{ .profile = profile_msg },
                            };
                            defer resp.deinit(allocator);
                            return encodeMessage(allocator, resp);
                        }
                    }

                    var exec_result = execution.executeStatementWithContext(allocator, target_stmt.*, exec_context) catch |err| {
                        const info = proto_util.mapError(err);
                        var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };
                    defer exec_result.deinit(allocator);

                    // CANARY: REQ=REQ-SEC-RLS-ALGO-001; FEATURE="RLS Algorithm Filtering"; ASPECT=gRPCProfileWire; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
                    // Algorithm RLS filter BEFORE lock release — requires store access.
                    const store_ptr = graph_store.getGlobalStore(allocator);
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                            _ = rls_filter.applyAlgorithmRLSFilter(allocator, &exec_result, rls_engine, store_ptr, auth_user, rls_graph);
                        }
                    }

                    // #564: Release lock after execution, before serialization/network I/O
                    if (needs_store_lock) {
                        if (graph_lock_handle) |h| {
                            // GAP-0511: Release lock before index rebuild
                            graph_store.releaseGraphLock(h);
                            lock_released = true;
                            rebuildPendingIndexes(allocator, query_graph_name, &pending_index_rebuilds);
                        }
                    }

                    for (flags.items) |flag| {
                        try appendFlagToResult(allocator, &exec_result, flag);
                    }

                    // S1: Apply RLS filter on gRPC PROFILE path (parity with QUIC handler).
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                            _ = rls_filter.applyRLSFilter(allocator, &exec_result, rls_engine, auth_user, rls_graph);
                        }
                    }
                    const profile_msg = try profile_payload.buildProfilePayload(allocator, traits, exec_result.rows.len, .{
                        .compact = store.config.compact_profile,
                        .include_mem_curve = store.config.memcurve_profile,
                        .disable_estimates = store.config.disable_estimates,
                        .spill_threshold = state.query_mem_limit_bytes,
                        .committed_txns = state.global_commit_ts,
                        .graph_store_nodes = @intCast(store_ptr.getNodeCount()),
                        .graph_store_edges = @intCast(store_ptr.getEdgeCount()),
                        .graph_store_dirty = store_ptr.isDirty(),
                        .flagger_findings = exec_result.flags.items,
                        .union_part_count = analysis.union_part_count,
                    });

                    const status = try proto_util.buildStatus(allocator, "00000", exec_result.flags.items);
                    var resp = schema.ExecutionResponse{
                        .status = status,
                        .payload = .{ .profile = profile_msg },
                    };
                    defer resp.deinit(allocator);

                    return encodeMessage(allocator, resp);
                },
                .rows => {
                    const rls_active = rls_filter.getGlobalRLSFilterEngine() != null and state.authenticated_user != null;
                    if (!rls_active) {
                        if (analysis.target) |target| {
                            if (target.* == .Query) {
                                const query_ptr = &target.Query;
                                if (try node_scan_stream.prepare(allocator, query_ptr, exec_context, bindings.names, bindings.values, flags.items)) |prepared_stream| {
                                    var active_stream = prepared_stream;
                                    errdefer active_stream.deinit();

                                    if (needs_store_lock) {
                                        if (graph_lock_handle) |h| {
                                            // GAP-0511: Release lock before index rebuild
                                            graph_store.releaseGraphLock(h);
                                            lock_released = true;
                                            rebuildPendingIndexes(allocator, query_graph_name, &pending_index_rebuilds);
                                        }
                                    }

                                    const status = try proto_util.buildStatus(allocator, "00000", active_stream.flags);
                                    const schema_def = try active_stream.buildSchema(allocator);
                                    var schema_resp = schema.ExecutionResponse{
                                        .status = status,
                                        .payload = .{ .schema = schema_def },
                                    };
                                    defer schema_resp.deinit(allocator);

                                    state.active_node_scan_stream = active_stream;
                                    state.active_result = true;
                                    state.result_page_index = 0;
                                    state.result_ordered = false;
                                    state.result_order_keys = &.{};

                                    updateTxnStateFromProgram(state, &parse_result.program);
                                    return encodeMessage(allocator, schema_resp);
                                }
                            }
                        }
                    }

                    var exec_result = execution.executeProgramWithContext(allocator, &parse_result.program, exec_context) catch |err| {
                        const info = proto_util.mapError(err);
                        var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                        defer resp.deinit(allocator);
                        return encodeMessage(allocator, resp);
                    };
                    var store_result = false;
                    defer if (!store_result) exec_result.deinit(allocator);

                    // CANARY: REQ=REQ-SEC-RLS-ALGO-001; FEATURE="RLS Algorithm Filtering"; ASPECT=gRPCRowsWire; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
                    // Algorithm RLS filter BEFORE lock release — requires store access.
                    {
                        const algo_store = graph_store.getGlobalStore(allocator);
                        if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                            if (state.authenticated_user) |auth_user| {
                                const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                                _ = rls_filter.applyAlgorithmRLSFilter(allocator, &exec_result, rls_engine, algo_store, auth_user, rls_graph);
                            }
                        }
                    }

                    // #564: Release lock after execution, before serialization/network I/O
                    if (needs_store_lock) {
                        if (graph_lock_handle) |h| {
                            // GAP-0511: Release lock before index rebuild
                            graph_store.releaseGraphLock(h);
                            lock_released = true;
                            rebuildPendingIndexes(allocator, query_graph_name, &pending_index_rebuilds);
                        }
                    }

                    for (flags.items) |flag| {
                        try appendFlagToResult(allocator, &exec_result, flag);
                    }

                    // S1: Apply RLS filter on gRPC rows path (parity with QUIC handler).
                    if (rls_filter.getGlobalRLSFilterEngine()) |rls_engine| {
                        if (state.authenticated_user) |auth_user| {
                            const rls_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
                            _ = rls_filter.applyRLSFilter(allocator, &exec_result, rls_engine, auth_user, rls_graph);
                        }
                    }

                    var order_keys: []const []const u8 = &.{};
                    defer if (!store_result) {
                        for (order_keys) |key| allocator.free(key);
                        if (order_keys.len > 0) allocator.free(order_keys);
                    };
                    if (ordered) {
                        if (findOrderBy(&parse_result.program)) |ob| {
                            order_keys = try buildOrderKeys(allocator, ob, &exec_result);
                        }
                    }

                    const status = try proto_util.buildStatus(allocator, "00000", exec_result.flags.items);
                    const schema_def = try proto_util.buildSchemaDefinition(allocator, &exec_result);
                    var schema_resp = schema.ExecutionResponse{
                        .status = status,
                        .payload = .{ .schema = schema_def },
                    };
                    defer schema_resp.deinit(allocator);

                    // Deep-copy result to prevent use-after-free when AST is freed
                    // (gRPC streaming builds data pages after handleExecute returns)
                    const duped = try execution.duplicateResult(allocator, exec_result);
                    exec_result.deinit(allocator);
                    store_result = true;
                    state.active_result_values = duped;
                    state.active_result = true;
                    state.result_page_index = 0;
                    state.result_ordered = ordered;
                    state.result_order_keys = order_keys;

                    updateTxnStateFromProgram(state, &parse_result.program);
                    return encodeMessage(allocator, schema_resp);
                },
            }
        },
    }
}

fn handlePull(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.PullRequest, &reader, allocator) catch |err| {
        log.err("Failed to decode Pull request", &.{Attr.string("error", @errorName(err))});
        var resp = try buildErrorResponse(allocator, "22023", "Invalid pull request", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        var resp = try buildErrorResponse(allocator, "28000", "Missing session_id", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    }

    const store = getSessionStore() orelse {
        var resp = try buildErrorResponse(allocator, "58000", "Server not initialized", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };

    const entry = store.getEntry(req.session_id) orelse {
        throttleInvalidSessionProbe();
        var resp = try buildErrorResponse(allocator, "28000", "Unknown session", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        .missing => {
            var resp = try buildErrorResponse(allocator, "28000", "Authentication required", &.{}, &.{});
            defer resp.deinit(allocator);
            const pull_resp = schema.PullResponse{ .response = resp };
            return encodeMessage(allocator, pull_resp);
        },
        .invalidated => {
            var resp = try buildErrorResponse(allocator, "28000", "Session invalidated due to credential or role change", &.{}, &.{});
            defer resp.deinit(allocator);
            const pull_resp = schema.PullResponse{ .response = resp };
            return encodeMessage(allocator, pull_resp);
        },
    }

    // Arena allocator for pull page serialization (Issue #446)
    var pull_arena = std.heap.ArenaAllocator.init(allocator);
    defer pull_arena.deinit();
    const pa = pull_arena.allocator();

    if (state.active_node_scan_stream) |*active_stream| {
        var page_result = try active_stream.buildNextPage(allocator, req.page_size);
        defer page_result.result.deinit(allocator);

        const page = try proto_util.buildDataPageFromRows(pa, page_result.result.rows, page_result.final, false, &.{});
        const status = try proto_util.buildStatus(pa, "00000", active_stream.flags);
        const resp = schema.ExecutionResponse{
            .status = status,
            .payload = .{ .page = page },
        };

        const pull_resp = schema.PullResponse{ .response = resp };
        const encoded_tmp = try encodeMessage(pa, pull_resp);
        const encoded = try allocator.dupe(u8, encoded_tmp);

        if (page.final) {
            state.resetResult();
        }

        return encoded;
    }

    const result_ptr = if (state.active_result_values) |*res| res else {
        var resp = try buildErrorResponse(allocator, "02000", "No active result set", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };

    const start = state.result_page_index;

    const page = try proto_util.buildDataPage(pa, result_ptr, start, req.page_size, state.result_ordered, state.result_order_keys);
    state.result_page_index += page.rows.items.len;

    const status = try proto_util.buildStatus(pa, "00000", result_ptr.flags.items);
    const resp = schema.ExecutionResponse{
        .status = status,
        .payload = .{ .page = page },
    };

    const pull_resp = schema.PullResponse{ .response = resp };
    const encoded_tmp = try encodeMessage(pa, pull_resp);
    const encoded = try allocator.dupe(u8, encoded_tmp);

    if (page.final) {
        state.resetResult();
    }

    return encoded;
}

fn handleBegin(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.BeginRequest, &reader, allocator) catch {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    }

    const store = getSessionStore() orelse {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    };

    const entry = store.getEntry(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
            return encodeMessage(allocator, resp);
        },
    }

    if (state.in_txn) {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    }

    state.in_txn = true;
    state.txn_id = @intCast(compat_milliTimestamp());
    state.session_snapshot_ts = state.global_commit_ts;
    txn_undo_log.getGlobalUndoLog(allocator).begin();

    const tx_id_str = try std.fmt.allocPrint(allocator, "{d}", .{state.txn_id});
    const resp = schema.BeginResponse{
        .session_id = try allocator.dupe(u8, req.session_id),
        .tx_id = tx_id_str,
    };
    return encodeMessage(allocator, resp);
}

fn handleCommit(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.CommitRequest, &reader, allocator) catch {
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const store = getSessionStore() orelse {
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = store.getEntry(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.CommitResponse{ .success = false };
            return encodeMessage(allocator, resp);
        },
    }

    if (state.in_txn) {
        const commit_graph = state.current_graph orelse graph_store.DEFAULT_GRAPH_NAME;
        const commit_lock = graph_store.acquireGraphWriteLock(commit_graph);
        defer graph_store.releaseGraphLock(commit_lock);

        const store_ptr = graph_store.getGlobalStore(allocator);
        txn_undo_log.getGlobalUndoLog(allocator).commit(store_ptr);

        state.global_commit_ts += 1;
        state.in_txn = false;
        state.txn_id = 0;
        const resp = schema.CommitResponse{ .success = true };
        return encodeMessage(allocator, resp);
    }

    const resp = schema.CommitResponse{ .success = false };
    return encodeMessage(allocator, resp);
}

fn handleRollback(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.RollbackRequest, &reader, allocator) catch {
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0) {
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const store = getSessionStore() orelse {
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = store.getEntry(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.RollbackResponse{ .success = false };
            return encodeMessage(allocator, resp);
        },
    }

    if (state.in_txn) {
        const store_ptr = graph_store.getGlobalStore(allocator);
        txn_undo_log.getGlobalUndoLog(allocator).rollback(store_ptr) catch |err| {
            log.err("Rollback failed", &.{Attr.string("error", @errorName(err))});
        };
        state.in_txn = false;
        state.txn_id = 0;
        const resp = schema.RollbackResponse{ .success = true };
        return encodeMessage(allocator, resp);
    }

    const resp = schema.RollbackResponse{ .success = false };
    return encodeMessage(allocator, resp);
}

// ============================================================================
// Issue #515: 7 new gRPC message handlers (matching QUIC handler behavior)
// CANARY: REQ=REQ-GRPC-FULL-ROUTING-001; FEATURE="GrpcFullMessageRouting"; ASPECT=HandlerParity; STATUS=IMPL; OWNER=transport; UPDATED=2026-02-13
// ============================================================================

// CANARY: REQ=REQ-TXN-SAVEPOINT-006; FEATURE="TransactionSavepoints"; ASPECT=GrpcSavepoint; STATUS=IMPL; OWNER=transport; UPDATED=2026-04-01
fn handleSavepoint(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.SavepointRequest, &reader, allocator) catch {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0 or req.name.len == 0) {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const sess_store = getSessionStore() orelse {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = sess_store.getEntry(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.SavepointResponse{ .success = false };
            return encodeMessage(allocator, resp);
        },
    }

    if (!state.in_txn) {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const undo = txn_undo_log.getGlobalUndoLog(allocator);
    undo.createSavepoint(req.name) catch {
        const resp = schema.SavepointResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const resp = schema.SavepointResponse{ .success = true };
    return encodeMessage(allocator, resp);
}

// CANARY: REQ=REQ-TXN-SAVEPOINT-007; FEATURE="TransactionSavepoints"; ASPECT=GrpcRollbackTo; STATUS=IMPL; OWNER=transport; UPDATED=2026-04-01
fn handleRollbackTo(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.RollbackToRequest, &reader, allocator) catch {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    if (req.session_id.len == 0 or req.name.len == 0) {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const sess_store = getSessionStore() orelse {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = sess_store.getEntry(req.session_id) orelse {
        throttleInvalidSessionProbe();
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer entry.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const state = entry.state;

    switch (try validateSessionAuth(allocator, state)) {
        .ok => {},
        else => {
            const resp = schema.RollbackToResponse{ .success = false };
            return encodeMessage(allocator, resp);
        },
    }

    if (!state.in_txn) {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    }

    const store_ptr = graph_store.getGlobalStore(allocator);
    const undo = txn_undo_log.getGlobalUndoLog(allocator);
    undo.rollbackToSavepoint(req.name, store_ptr) catch {
        const resp = schema.RollbackToResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const resp = schema.RollbackToResponse{ .success = true };
    return encodeMessage(allocator, resp);
}

fn handleCdcDiag(_: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // GAP-0255: Use the real global CDC engine when available (parity with QUIC handler).
    // Acquire CDC mutex for thread-safe access (parity with procedure_registry).
    const cdc_mutex = execution.getCdcMutex();
    cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (execution.getGlobalCdcEngine()) |eng| {
        const resp = try eng.exportDiagnostics(allocator);
        return encodeMessage(allocator, resp);
    }
    // No CDC engine running — return default diagnostics
    const resp = schema.CdcDiagnosticsResponse{
        .config = .{ .enabled = false },
        .engine = .{ .is_running = false },
        .malformed_snapshots = std.ArrayList(schema.CdcMalformedSnapshot).empty,
        .malformed_hashes = std.ArrayList(schema.CdcMalformedHash).empty,
        .version = try allocator.dupe(u8, @import("build_options").version),
        .timestamp_ms = compat_milliTimestamp(),
    };
    return encodeMessage(allocator, resp);
}

fn handleCdcCtrl(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // GAP-0255: Use the real global CDC engine when available (parity with QUIC handler).
    // Acquire CDC mutex for thread-safe access (parity with procedure_registry).
    const cdc_mutex = execution.getCdcMutex();
    cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (execution.getGlobalCdcEngine()) |eng| {
        var reader: std.Io.Reader = .fixed(request_bytes);
        var req = protobuf.decode(schema.CdcControlRequest, &reader, allocator) catch {
            const resp = schema.CdcControlResponse{
                .success = false,
                .status = try allocator.dupe(u8, "INVALID_REQUEST"),
                .guardrail_epoch = eng.guardrail_epoch,
            };
            return encodeMessage(allocator, resp);
        };
        defer req.deinit(allocator);

        if (std.ascii.eqlIgnoreCase(req.action, "RESET_GUARDRAILS")) {
            eng.resetGuardrailState();
            const resp = schema.CdcControlResponse{
                .success = true,
                .status = try allocator.dupe(u8, "OK"),
                .guardrail_epoch = eng.guardrail_epoch,
            };
            return encodeMessage(allocator, resp);
        } else {
            const resp = schema.CdcControlResponse{
                .success = false,
                .status = try allocator.dupe(u8, "UNSUPPORTED"),
                .guardrail_epoch = eng.guardrail_epoch,
            };
            return encodeMessage(allocator, resp);
        }
    }
    // No CDC engine running — return NO_ENGINE
    const resp = schema.CdcControlResponse{
        .success = false,
        .status = try allocator.dupe(u8, "NO_ENGINE"),
        .guardrail_epoch = 0,
    };
    return encodeMessage(allocator, resp);
}

fn handleBackup(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.BackupRequest, &reader, allocator) catch {
        const resp = schema.BackupResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Invalid backup request"),
        };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    switch (try authorizeAdminSession(req.session_id, allocator)) {
        .ok => {},
        .missing => {
            const resp = schema.BackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Authentication required"),
            };
            return encodeMessage(allocator, resp);
        },
        .invalidated => {
            const resp = schema.BackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Session invalidated due to credential or role change"),
            };
            return encodeMessage(allocator, resp);
        },
        .forbidden => {
            const resp = schema.BackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Permission denied: Admin role required for backup operations"),
            };
            return encodeMessage(allocator, resp);
        },
    }

    // GAP-0255: Acquire shared store lock for backup consistency (parity with QUIC handler).
    // P1: Per-graph locking — back up with a read lock on the default graph.
    const backup_lock_handle = graph_store.acquireGraphReadLock(graph_store.DEFAULT_GRAPH_NAME);
    defer graph_store.releaseGraphLock(backup_lock_handle);

    const backup_dir = "./server_backups";
    var mgr = SimplifiedBackupManager.init(allocator, backup_dir, .{
        .compression = if (req.compress) .zstd else .none,
        .encryption = false,
        .retention_days = 30,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Backup init failed: {s}", .{@errorName(err)});
        const resp = schema.BackupResponse{ .success = false, .message = msg };
        return encodeMessage(allocator, resp);
    };
    defer mgr.deinit();

    if (!std.ascii.eqlIgnoreCase(req.backup_type, "full")) {
        const msg = try allocator.dupe(u8, "Only full backups are supported with GraphStore");
        const resp = schema.BackupResponse{ .success = false, .message = msg };
        return encodeMessage(allocator, resp);
    }

    const metadata = mgr.createFullBackup() catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Backup failed: {s}", .{@errorName(err)});
        const resp = schema.BackupResponse{ .success = false, .message = msg };
        return encodeMessage(allocator, resp);
    };

    const resp = schema.BackupResponse{
        .success = true,
        .message = try allocator.dupe(u8, "Backup completed successfully"),
        .backup_id = try std.fmt.allocPrint(allocator, "{x}", .{metadata.backup_id}),
        .backup_type = try allocator.dupe(u8, @tagName(metadata.backup_type)),
        .size_bytes = metadata.size_bytes,
        .compression = try allocator.dupe(u8, @tagName(metadata.compression)),
        .checksum = try std.fmt.allocPrint(allocator, "{x}", .{metadata.checksum}),
    };
    return encodeMessage(allocator, resp);
}

fn handleRestore(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.RestoreRequest, &reader, allocator) catch {
        const resp = schema.RestoreResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Invalid restore request"),
        };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    switch (try authorizeAdminSession(req.session_id, allocator)) {
        .ok => {},
        .missing => {
            const resp = schema.RestoreResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Authentication required"),
            };
            return encodeMessage(allocator, resp);
        },
        .invalidated => {
            const resp = schema.RestoreResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Session invalidated due to credential or role change"),
            };
            return encodeMessage(allocator, resp);
        },
        .forbidden => {
            const resp = schema.RestoreResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Permission denied: Admin role required for restore operations"),
            };
            return encodeMessage(allocator, resp);
        },
    }

    if (!req.confirm) {
        const resp = schema.RestoreResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Restore requires confirmation"),
        };
        return encodeMessage(allocator, resp);
    }

    var mgr = SimplifiedBackupManager.init(allocator, "./server_backups", .{
        .compression = .zstd,
        .encryption = false,
        .retention_days = 30,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Restore init failed: {s}", .{@errorName(err)});
        const resp = schema.RestoreResponse{ .success = false, .message = msg };
        return encodeMessage(allocator, resp);
    };
    defer mgr.deinit();

    const target_time: i64 = if (req.target_time.len > 0)
        std.fmt.parseInt(i64, req.target_time, 10) catch compat_milliTimestamp()
    else
        compat_milliTimestamp();

    const restore_dir = if (getEnvVarOwned(allocator, "GEODE_DATA_DIR")) |dir| blk: {
        defer allocator.free(dir);
        break :blk try allocator.dupe(u8, dir);
    } else |_| try allocator.dupe(u8, "./data");

    mgr.restoreToPointInTime(target_time, restore_dir) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Restore failed: {s}", .{@errorName(err)});
        const resp = schema.RestoreResponse{ .success = false, .message = msg };
        allocator.free(restore_dir);
        return encodeMessage(allocator, resp);
    };

    const resp = schema.RestoreResponse{
        .success = true,
        .message = try allocator.dupe(u8, "Restore completed"),
        .restore_dir = restore_dir,
        .target_time = try allocator.dupe(u8, if (req.target_time.len > 0) req.target_time else "latest"),
        .restore_timestamp = @intCast(compat_milliTimestamp()),
    };
    return encodeMessage(allocator, resp);
}

fn handleUploadBackup(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.UploadBackupRequest, &reader, allocator) catch {
        const resp = schema.UploadBackupResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Invalid upload request"),
        };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    switch (try authorizeAdminSession(req.session_id, allocator)) {
        .ok => {},
        .missing => {
            const resp = schema.UploadBackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Authentication required"),
            };
            return encodeMessage(allocator, resp);
        },
        .invalidated => {
            const resp = schema.UploadBackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Session invalidated due to credential or role change"),
            };
            return encodeMessage(allocator, resp);
        },
        .forbidden => {
            const resp = schema.UploadBackupResponse{
                .success = false,
                .message = try allocator.dupe(u8, "Permission denied: Admin role required for backup upload"),
            };
            return encodeMessage(allocator, resp);
        },
    }

    if (req.size_bytes == 0 or req.checksum.len == 0) {
        const resp = schema.UploadBackupResponse{
            .success = false,
            .message = try allocator.dupe(u8, "Invalid upload request: missing size or checksum"),
        };
        return encodeMessage(allocator, resp);
    }

    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), "./uploaded_backups") catch {};
    const path = try std.fmt.allocPrint(allocator, "./uploaded_backups/backup_{d}.bin", .{compat_milliTimestamp()});
    // Create empty placeholder file for upload slot
    if (std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{})) |file| {
        file.close(std.Io.Threaded.global_single_threaded.io());
    } else |_| {}

    const resp = schema.UploadBackupResponse{
        .success = true,
        .message = try allocator.dupe(u8, "Upload slot ready"),
        .upload_path = path,
    };
    return encodeMessage(allocator, resp);
}
