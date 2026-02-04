const std = @import("std");
const geode = @import("geode");
const schema = @import("schema");
const protobuf = @import("protobuf");
const GrpcServer = @import("grpc_server").GrpcServer;
const proto_util = geode.proto_util;
const server_flags = geode.server_flags;
const diagnostics = geode.diagnostics;
const execution = geode.execution;
const graph_store = geode.graph_store;
const server_state = geode.server_state;
const txn_undo_log = geode.txn_undo_log;
const user_mgmt = geode.user_management;
const gql_ast = geode.gql.ast;
const gql_print = geode.printer;
const wal_manager = geode.wal_manager;
const geode_auth = @import("geode_auth");

const logging = @import("logging");
const log = logging.scoped("grpc");
const Attr = logging.Attr;

pub const GrpcConfig = struct {
    spill_sort: usize = 0,
    spill_distinct: usize = 0,
    spill_union: usize = 0,
    spill_threshold: usize = 0,
    storage_checksum_error: bool = false,
    security_manager: ?*geode_auth.SecurityManager = null,
};

const SessionEntry = struct {
    state: *server_state.ServerState,
    mutex: std.Thread.Mutex = .{},
};

const SessionStore = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
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
    ) ![]const u8 {
        const session_id = try std.fmt.allocPrint(self.allocator, "sess_{d}", .{std.time.milliTimestamp()});
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
        if (tenant_id) |tenant| {
            state.session_config = server_state.SessionConfiguration.init(self.allocator);
            state.session_config.?.tenant_id = try self.allocator.dupe(u8, tenant);
        }

        const entry = try self.allocator.create(SessionEntry);
        entry.* = .{ .state = state };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.sessions.put(session_id, entry);
        return session_id;
    }

    pub fn getEntry(self: *SessionStore, session_id: []const u8) ?*SessionEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sessions.get(session_id);
    }
};

var g_session_store: ?*SessionStore = null;

fn initServerState(allocator: std.mem.Allocator, config: GrpcConfig) !*server_state.ServerState {
    const wal_mgr = try wal_manager.getOrCreateWalManager(allocator);
    const state = try allocator.create(server_state.ServerState);
    state.* = .{ .allocator = allocator };
    state.exec_session = execution.SessionState.init(allocator);
    state.telemetry_paging = if (std.process.getEnvVarOwned(allocator, "GEODE_TELEMETRY_PAGING")) |v| blk: {
        defer allocator.free(v);
        break :blk true;
    } else |_| false;
    state.txn_manager.init(allocator);
    state.inserted_values = .{};
    state.catalog_schemas = std.HashMap([]const u8, server_state.CatalogSchema, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    state.catalog_graphs = std.HashMap([]const u8, server_state.CatalogGraph, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    state.graph_types = std.HashMap([]const u8, server_state.GraphTypeDefinition, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
    state.wal_ptr = @ptrCast(wal_mgr);
    state.spill_sort = config.spill_sort;
    state.spill_distinct = config.spill_distinct;
    state.spill_union = config.spill_union;
    state.query_mem_limit_bytes = config.spill_threshold;
    state.storage_checksum_error = config.storage_checksum_error;
    state.security_manager = config.security_manager;
    state.query_optimizer_enabled = if (std.process.getEnvVarOwned(allocator, "GEODE_ENABLE_QUERY_OPTIMIZER")) |v| blk: {
        defer allocator.free(v);
        if (v.len == 0) break :blk false;
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) break :blk true;
        break :blk false;
    } else |_| false;
    return state;
}

fn deinitServerState(state: *server_state.ServerState) void {
    const alloc = state.allocator;
    state.resetResult();
    if (state.exec_session) |*sess| sess.deinit();
    if (state.session_config) |*cfg| cfg.deinit();
    if (state.authenticated_user) |u| alloc.free(u);
    if (state.authenticated_password) |p| alloc.free(p);
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
            state.txn_id = @intCast(std.time.milliTimestamp());
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

    pub fn init(
        allocator: std.mem.Allocator,
        port: u16,
        cert_path: ?[]const u8,
        key_path: ?[]const u8,
        config: GrpcConfig,
    ) !GeodeGrpcServer {
        _ = cert_path;
        _ = key_path;

        const server = try GrpcServer.init(allocator, port, "secret-key");

        const store = try allocator.create(SessionStore);
        store.* = SessionStore.init(allocator, config);
        g_session_store = store;

        var self = GeodeGrpcServer{
            .allocator = allocator,
            .server = server,
            .session_store = store,
        };

        try self.registerHandlers();
        return self;
    }

    pub fn deinit(self: *GeodeGrpcServer) void {
        self.session_store.deinit();
        self.allocator.destroy(self.session_store);
        g_session_store = null;
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

fn handlePacket(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var packet = protobuf.decode(schema.ClientPacket, &reader, allocator) catch |err| {
        log.err("Failed to decode gRPC packet", &.{Attr.err("error", err)});
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
            const resp_bytes = try handleHandshake(req_bytes, allocator);
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
        else => buildPacketError(allocator, "0A000", "Unsupported client message"),
    };
}

fn handlePing(_: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const response = schema.PingResponse{ .ok = true };
    return encodeMessage(allocator, response);
}

fn handleHandshake(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.HelloRequest, &reader, allocator) catch |err| {
        log.err("Failed to decode HELLO request", &.{Attr.err("error", err)});
        const resp = schema.HelloResponse{
            .success = false,
            .session_id = "",
            .error_message = "Invalid request",
            .capabilities = std.ArrayList([]const u8){},
        };
        return encodeMessage(allocator, resp);
    };
    defer req.deinit(allocator);

    const store = g_session_store orelse {
        const resp = schema.HelloResponse{
            .success = false,
            .session_id = "",
            .error_message = "Server not initialized",
            .capabilities = std.ArrayList([]const u8){},
        };
        return encodeMessage(allocator, resp);
    };

    var caps = std.ArrayList([]const u8).initCapacity(allocator, 3) catch return error.OutOfMemory;
    try caps.append(allocator, try allocator.dupe(u8, "GRPC"));
    try caps.append(allocator, try allocator.dupe(u8, "PROTOBUF"));
    try caps.append(allocator, try allocator.dupe(u8, "TLS1.3"));

    if (user_mgmt.isAuthEnabled()) {
        if (req.username.len == 0 or req.password.len == 0) {
            const resp = schema.HelloResponse{
                .success = false,
                .session_id = "",
                .error_message = "Authentication required",
                .capabilities = caps,
            };
            return encodeMessage(allocator, resp);
        }
        const role = user_mgmt.authenticate(req.username, req.password) catch {
            const resp = schema.HelloResponse{
                .success = false,
                .session_id = "",
                .error_message = "Authentication failed",
                .capabilities = caps,
            };
            return encodeMessage(allocator, resp);
        };
        const session_id = try store.createSession(req.username, req.password, role, req.tenant_id);
        const resp = schema.HelloResponse{
            .success = true,
            .session_id = try allocator.dupe(u8, session_id),
            .error_message = "",
            .capabilities = caps,
        };
        return encodeMessage(allocator, resp);
    }

    const session_id = try store.createSession("", "", null, req.tenant_id);
    const resp = schema.HelloResponse{
        .success = true,
        .session_id = try allocator.dupe(u8, session_id),
        .error_message = "",
        .capabilities = caps,
    };
    return encodeMessage(allocator, resp);
}

fn handleExecute(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.ExecuteRequest, &reader, allocator) catch |err| {
        log.err("Failed to decode Execute request", &.{Attr.err("error", err)});
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

    const store = g_session_store orelse {
        var resp = try buildErrorResponse(allocator, "58000", "Server not initialized", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };

    const entry = store.getEntry(req.session_id) orelse {
        var resp = try buildErrorResponse(allocator, "28000", "Unknown session", &.{}, &.{});
        defer resp.deinit(allocator);
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lock();
    defer entry.mutex.unlock();
    const state = entry.state;

    state.resetResult();

    if (user_mgmt.isAuthEnabled() and state.authenticated_user == null) {
        var resp = try buildErrorResponse(allocator, "28000", "Authentication required", &.{}, &.{});
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

    const outcome = try geode.parseGqlOutcome(req.query, allocator, parse_opts);
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

            const order_by_ptr = findOrderBy(&parse_result.program);
            const ordered = order_by_ptr != null;

            const role = if (state.authenticated_role) |role_u8|
                @as(user_mgmt.Role, @enumFromInt(role_u8))
            else
                null;

            const catalog = try execution.ensureCatalogInstance(allocator);
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

            var exec_result = execution.executeProgramWithContext(allocator, &parse_result.program, exec_context) catch |err| {
                const info = proto_util.mapError(err);
                var resp = try buildErrorResponse(allocator, info.code, info.message, &.{}, &.{});
                defer resp.deinit(allocator);
                return encodeMessage(allocator, resp);
            };
            var store_result = false;
            defer if (!store_result) exec_result.deinit(allocator);

            var order_keys: []const []const u8 = &.{};
            defer if (!store_result) {
                for (order_keys) |key| allocator.free(key);
                if (order_keys.len > 0) allocator.free(order_keys);
            };
            if (order_by_ptr) |ob| {
                order_keys = try buildOrderKeys(allocator, ob, &exec_result);
            }

            const base_flags = server_flags.computeBaseFlags(ordered, false);
            for (base_flags) |flag| {
                try appendFlagIfMissing(allocator, &exec_result.flags, flag);
            }
            if (parse_result.has_double_solidus_comment) {
                try appendFlagIfMissing(allocator, &exec_result.flags, "GB03:DoubleSolidusComment");
            }

            const status = try proto_util.buildStatus(allocator, "00000", exec_result.flags.items);
            const schema_def = try proto_util.buildSchemaDefinition(allocator, &exec_result);
            var schema_resp = schema.ExecutionResponse{
                .status = status,
                .payload = .{ .schema = schema_def },
            };
            defer schema_resp.deinit(allocator);

            store_result = true;
            state.active_result_values = exec_result;
            state.active_result = true;
            state.result_page_index = 0;
            state.result_ordered = ordered;
            state.result_order_keys = order_keys;

            updateTxnStateFromProgram(state, &parse_result.program);
            if (!state.in_txn) {
                graph_store.getGlobalStore(allocator).saveIfDirty();
            }

            return encodeMessage(allocator, schema_resp);
        },
    }
}

fn handlePull(request_bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_bytes);
    var req = protobuf.decode(schema.PullRequest, &reader, allocator) catch |err| {
        log.err("Failed to decode Pull request", &.{Attr.err("error", err)});
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

    const store = g_session_store orelse {
        var resp = try buildErrorResponse(allocator, "58000", "Server not initialized", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };

    const entry = store.getEntry(req.session_id) orelse {
        var resp = try buildErrorResponse(allocator, "28000", "Unknown session", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };

    entry.mutex.lock();
    defer entry.mutex.unlock();
    const state = entry.state;

    const result_ptr = if (state.active_result_values) |*res| res else {
        var resp = try buildErrorResponse(allocator, "02000", "No active result set", &.{}, &.{});
        defer resp.deinit(allocator);
        const pull_resp = schema.PullResponse{ .response = resp };
        return encodeMessage(allocator, pull_resp);
    };

    const start = state.result_page_index;
    const page = try proto_util.buildDataPage(allocator, result_ptr, start, req.page_size, state.result_ordered, state.result_order_keys);
    state.result_page_index += page.rows.items.len;

    const status = try proto_util.buildStatus(allocator, "00000", result_ptr.flags.items);
    const resp = schema.ExecutionResponse{
        .status = status,
        .payload = .{ .page = page },
    };
    var resp_copy = resp;
    defer resp_copy.deinit(allocator);

    const pull_resp = schema.PullResponse{ .response = resp };
    const encoded = try encodeMessage(allocator, pull_resp);

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

    const store = g_session_store orelse {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    };

    const entry = store.getEntry(req.session_id) orelse {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lock();
    defer entry.mutex.unlock();
    const state = entry.state;

    if (state.in_txn) {
        const resp = schema.BeginResponse{ .session_id = "", .tx_id = "" };
        return encodeMessage(allocator, resp);
    }

    state.in_txn = true;
    state.txn_id = @intCast(std.time.milliTimestamp());
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

    const store = g_session_store orelse {
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = store.getEntry(req.session_id) orelse {
        const resp = schema.CommitResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lock();
    defer entry.mutex.unlock();
    const state = entry.state;

    if (state.in_txn) {
        txn_undo_log.getGlobalUndoLog(allocator).commit();
        state.in_txn = false;
        state.txn_id = 0;
        graph_store.getGlobalStore(allocator).saveIfDirty();
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

    const store = g_session_store orelse {
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };
    const entry = store.getEntry(req.session_id) orelse {
        const resp = schema.RollbackResponse{ .success = false };
        return encodeMessage(allocator, resp);
    };

    entry.mutex.lock();
    defer entry.mutex.unlock();
    const state = entry.state;

    if (state.in_txn) {
        const store_ptr = graph_store.getGlobalStore(allocator);
        txn_undo_log.getGlobalUndoLog(allocator).rollback(store_ptr) catch |err| {
            log.err("Rollback failed", &.{Attr.err("error", err)});
        };
        state.in_txn = false;
        state.txn_id = 0;
        store_ptr.saveIfDirty();
        const resp = schema.RollbackResponse{ .success = true };
        return encodeMessage(allocator, resp);
    }

    const resp = schema.RollbackResponse{ .success = false };
    return encodeMessage(allocator, resp);
}
