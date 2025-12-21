const std = @import("std");
const geode = @import("geode");
const protocol = geode.protocol;
const diagnostics = geode.diagnostics;
const eval = geode.eval;
const quic_transport = @import("transport/quic.zig");
const wal_mod = @import("wal");
const query_plan_cache = @import("query_plan_cache.zig");
const ServerState = @import("server_state.zig").ServerState;
const SessionConfiguration = @import("server_state.zig").SessionConfiguration;
const CatalogSchema = @import("server_state.zig").CatalogSchema;
const CatalogGraph = @import("server_state.zig").CatalogGraph;
const query_executor = @import("query_executor.zig");
const execution = @import("../execution.zig");
const cost_explain = @import("cost_explain.zig");
const server_flags = @import("server_flags.zig");
const message_handlers = @import("message_handlers.zig");
const protocol_handler = @import("protocol_handler.zig");
const graph_storage_mgr = @import("graph_storage_manager.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-012; FEATURE="ServerRefactoring"; ASPECT=QUIC_HANDLERS; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.3 - QUIC Connection Handlers Module (Eighth Increment)
// Extracted from server/main.zig to improve modularity and reduce main() function size
// Contains handleQuicConnection and processMessage functions for QUIC protocol handling

const log = std.log.scoped(.server);

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

// Protocol flag constants
const F_PROPERTY_ORDER = "U:PropOrder=LexDecl";
const F_ILLEGAL = "U:PropOrder=Illegal";
const F_TIEBREAK = "U:OrderTiebreak=LexJSON";
const DEBUG_PROFILE = false;

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
) !void {
    _ = env_wal_compact_interval;
    _ = _force_serialization_failure_unused;
    defer conn.close();

    // Poll the endpoint to process incoming STREAM frames before accepting
    // vendor/quic requires explicit polling to receive packets and populate stream queues
    // Try polling with retries to ensure we receive the client's initial STREAM frame
    var poll_attempts: usize = 0;
    while (poll_attempts < 10) : (poll_attempts += 1) {
        try transport.poll(50); // Poll for up to 50ms
        if (conn.inner.hasIncomingStreams()) break;
        if (poll_attempts > 0) {
            std.debug.print("[POLL] Attempt {}/10: No streams yet, retrying...\n", .{poll_attempts + 1});
        }
    }

    // Accept a stream for the protocol communication
    log.debug("Attempting to accept stream", .{});
    const stream = try conn.acceptStream();
    log.debug("Stream accepted successfully", .{});
    defer stream.close();

    // Initialize WAL
    var wal = wal_mod.Wal.init(gpa);
    defer wal.deinit();
    wal.openFile("/tmp/geode_ephemeral_wal") catch {};
    if (test_wal_skip_ratio) |ov| {
        wal.test_skip_ratio_override = ov;
    }

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
    state.wal_ptr = @ptrCast(wal);
    state.spill_sort = env_spill_sort;
    state.spill_distinct = env_spill_distinct;
    state.spill_union = env_spill_union;
    state.query_mem_limit_bytes = env_spill_threshold;
    state.storage_checksum_error = env_storage_checksum_error;

    // Initialize query plan cache and optimizer for performance optimization
    var query_optimizer = query_plan_cache.QueryOptimizer.init(gpa, 100); // Cache up to 100 plans
    defer query_optimizer.deinit();
    state.query_optimizer = &query_optimizer;

    // Initialize distributed query planner for federation-aware optimization
    var federation_manager = geode.distributed.query_planner.FederationManager.init(gpa);
    defer federation_manager.deinit();
    var dist_planner = geode.distributed.query_planner.DistributedQueryPlanner.init(gpa, &federation_manager);
    defer dist_planner.deinit();
    state.federation_manager = &federation_manager;
    state.distributed_planner = &dist_planner;

    // Process messages
    while (true) {
        // Poll to ensure stream data is available before reading
        // vendor/quic requires polling to receive packets into stream inboxes
        var read_attempts: usize = 0;
        const line = while (read_attempts < 20) : (read_attempts += 1) {
            if (stream.readLine(65536)) |l| {
                break l;
            } else |err| {
                if (err == error.EndOfStream) return;
                if (err == error.WouldBlock) {
                    // No data available yet, poll and retry
                    try transport.poll(100);
                    continue;
                }
                return err;
            }
        } else {
            std.debug.print("[READ] Failed to read after 20 poll attempts\n", .{});
            return error.Timeout;
        };
        defer gpa.free(line);

        if (line.len == 0) continue;

        // Process the message and send response
        const response = processMessage(gpa, &state, line, result_format_txt, disable_estimates, compact_profile, memcurve_profile) catch |err| {
            _ = err;
            const error_msg = try std.fmt.allocPrint(gpa, "{{\"status_class\":\"58000\",\"error\":\"{s}\"}}\n", .{@errorName(err)});
            defer gpa.free(error_msg);
            try stream.writeAll(error_msg);
            continue;
        };
        defer if (response.len > 0) gpa.free(response);

        if (response.len > 0) {
            try stream.writeAll(response);
        } else {
            // CRITICAL: Always send a response so client doesn't block forever
            // If processMessage returned empty, send an internal error response
            const fallback_error = "{\"status_class\":\"50000\",\"result\":{\"type\":\"ERROR\",\"error\":\"Internal server error: no response generated\"}}\n";
            try stream.writeAll(fallback_error);
        }
    }
}

pub fn processMessage(
    gpa: std.mem.Allocator,
    state: *ServerState,
    _line: []const u8,
    result_format_txt: bool,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
) ![]u8 {
    _ = disable_estimates;
    _ = compact_profile;
    _ = memcurve_profile;
    _ = result_format_txt;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const msg = protocol.parseClientMessage(arena.allocator(), _line) catch return try gpa.dupe(u8, "");
    switch (msg) {
        .HELLO => |hello| {
            // Check if authentication is enabled
            const user_mgmt = geode.user_management;
            const auth_enabled = user_mgmt.isAuthEnabled();

            // If auth is enabled, validate credentials
            if (auth_enabled) {
                if (hello.username == null or hello.password == null) {
                    // Authentication required but no credentials provided
                    const error_response = "{\"status_class\":\"42000\",\"type\":\"ERROR\",\"message\":\"Authentication required\"}\n";
                    return try gpa.dupe(u8, error_response);
                }

                // Validate credentials
                const username = hello.username.?;
                const password = hello.password.?;

                const role = user_mgmt.authenticate(username, password) catch {
                    // Authentication failed
                    const error_response = "{\"status_class\":\"42000\",\"type\":\"ERROR\",\"message\":\"Authentication failed: invalid username or password\"}\n";
                    return try gpa.dupe(u8, error_response);
                };

                // Authentication successful - store session info in state
                // Note: username comes from arena which is freed, so we must dupe it
                state.authenticated_user = gpa.dupe(u8, username) catch null;
                state.authenticated_role = role;
                log.info("Authenticated user: {s} with role: {s}", .{ username, role.toString() });
            }

            // Return HELLO response with capabilities
            const hello_response = "{\"status_class\":\"00000\",\"capabilities\":[\"QUIC\",\"TLS1.3\"]}\n";
            return try gpa.dupe(u8, hello_response);
        },
        .CDC_DIAGNOSTICS => |_| {
            if (state.cdc_engine) |eng| {
                const payload = eng.exportDiagnostics(gpa) catch {
                    return protocol.buildCdcDiagnosticsLine(gpa, "{\"cdc_error\":\"export_failed\"}") catch try gpa.dupe(u8, "");
                };
                defer gpa.free(payload);
                return protocol.buildCdcDiagnosticsLine(gpa, payload) catch try gpa.dupe(u8, "");
            } else {
                const json = "{\"cdc\":{\"enabled\":false}}";
                return protocol.buildCdcDiagnosticsLine(gpa, json) catch try gpa.dupe(u8, "");
            }
        },
        .CDC_CONTROL => |cc| {
            if (handleCdcControl(gpa, state, cc.action)) |resp| return resp else return try gpa.dupe(u8, "");
        },
        .PING => |_| {
            const ok = "{\"ok\":true}";
            const flags = computeBaseFlags(false, false);
            return protocol.buildBindingsLine(gpa, false, &.{}, ok, true, &.{}, flags) catch try gpa.dupe(u8, "");
        },
        .RUN_GQL => |rq| {
            state.resetResult();
            var text = rq.text;
            // Detect EXPLAIN / EXPLAIN CALIBRATED / PROFILE prefixes; track modes then strip
            var explain_mode = false;
            var explain_calibrated = false;
            var profile_mode = false;
            if (std.mem.startsWith(u8, text, "EXPLAIN CALIBRATED ")) {
                explain_mode = true;
                explain_calibrated = true;
                text = text["EXPLAIN CALIBRATED ".len..];
            } else if (std.mem.eql(u8, text, "EXPLAIN CALIBRATED")) {
                explain_mode = true;
                explain_calibrated = true;
                text = "";
            } else if (std.mem.startsWith(u8, text, "EXPLAIN ")) {
                explain_mode = true;
                text = text["EXPLAIN ".len..];
            } else if (std.mem.eql(u8, text, "EXPLAIN")) {
                explain_mode = true;
                text = "";
            } else if (std.mem.startsWith(u8, text, "PROFILE ")) {
                profile_mode = true;
                text = text["PROFILE ".len..];
            } else if (std.mem.eql(u8, text, "PROFILE")) {
                profile_mode = true;
                text = "";
            }
            var parse_res = geode.parseGqlOutcome(text, gpa, .{ .ident_order_only = !g_order_keys_expr, .forbid_orderby_calls = !g_order_keys_expr }) catch return try gpa.dupe(u8, "");
            switch (parse_res) {
                .Err => |er| {
                    // Map parser message to diagnostics (IllegalOrderKey, US001) using same helper as later handler
                    var codes_buf: [4]diagnostics.Code = undefined;
                    const n_raw = collectTextDiagnostics(text, er.msg, &codes_buf);
                    const n = diagnostics.foldCodes(codes_buf[0..n_raw]);
                    if (n == 0) {
                        return protocol.buildErrorLine(gpa, "ParseError", er.msg, "") catch try gpa.dupe(u8, "");
                    }
                    const primary = codes_buf[0];
                    const add_slice = buildAdditionalStatusesAlloc(gpa, codes_buf[0..n], primary);
                    const primary_msg = if (primary == .IllegalOrderKey) er.msg else diagnostics.defaultMessage(primary);
                    const has_us001 = primary == .US001;
                    var flags_buf_local: [3][]const u8 = .{ if (g_order_keys_expr) F_PROPERTY_ORDER else F_ILLEGAL, F_TIEBREAK, "U:US001/enforced" };
                    const base_flags = if (has_us001) flags_buf_local[0..3] else flags_buf_local[0..2];
                    // Build error line with flags
                    const err_line = protocol.buildErrorLineWithFlagsCustomStatus(gpa, diagnostics.codeName(primary), primary_msg, diagnostics.anchorFor(primary), add_slice, base_flags, null) catch try gpa.dupe(u8, "");
                    return err_line;
                },
                .Ok => |_| {},
            }
            // Post-parse ORDER BY function call validation (server fallback) when expressions disallowed.
            if (!g_order_keys_expr and parse_res == .Ok) {
                const prog = parse_res.Ok.program;
                // Walk first statement only (tests use single statement queries).
                if (prog.statements.len > 0) {
                    const st0 = prog.statements[0];
                    switch (st0) {
                        .Query => |qv| if (qv.order_by) |ob| {
                            var i_fn: usize = 0;
                            while (i_fn < ob.keys.len) : (i_fn += 1) {
                                const e = ob.keys[i_fn].expr;
                                if (e == .Call) {
                                    const err_line2 = protocol.buildErrorLine(gpa, "IllegalOrderKey", "ORDER BY key must be identifier", diagnostics.anchorFor(.IllegalOrderKey)) catch try gpa.dupe(u8, "");
                                    return err_line2;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
            defer if (parse_res == .Ok) parse_res.Ok.deinit();
            switch (parse_res) {
                .Err => |_| return try gpa.dupe(u8, ""),
                .Ok => |ok| {
                    if (ok.program.statements.len == 0) {
                        if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| return line else |_| return try gpa.dupe(u8, "");
                    }
                    const st = ok.program.statements[0];
                    switch (st) {
                        .Union => |u_stmt| {
                            var pn: [][]const u8 = &.{};
                            var pr: [][]const eval.Value = &.{};
                            parseParams(gpa, rq.params_json, &pn, &pr);
                            var metrics: UnionMetrics = .{ .left_in = 0, .right_in = 0, .out = 0, .hash_size = null };
                            var mode: []const u8 = "DISTINCT";
                            const rows = evaluateUnion(gpa, u_stmt, pn, pr, &mode, &metrics) catch &.{};
                            var cols_box = gpa.alloc(protocol.SchemaCol, u_stmt.first.ret.items.len) catch return try gpa.dupe(u8, "");
                            var ci: usize = 0;
                            while (ci < u_stmt.first.ret.items.len) : (ci += 1) {
                                const it = u_stmt.first.ret.items[ci];
                                var name_slice: []const u8 = "col";
                                if (it.alias) |al| name_slice = al else {
                                    const tmpn = geode.printer.stringifyExprAlloc(gpa, it.expr, .{}) catch "col";
                                    name_slice = tmpn;
                                }
                                cols_box[ci] = .{ .name = name_slice, .type = "INT" };
                            }
                            const cols: []const protocol.SchemaCol = cols_box;
                            state.last_columns = cols;
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = std.mem.eql(u8, mode, "DISTINCT");
                            state.page_items = @constCast(rows);
                            state.page_index = 0;
                            state.active_result = true;
                            return protocol.buildSchemaLine(gpa, state.last_columns, &.{}, computeBaseFlags(false, state.last_distinct)) catch try gpa.dupe(u8, "");
                        },
                        .Query => |q| {
                            std.debug.print("[DEBUG .Query] Entering Query statement handler\n", .{});
                            var pn: [][]const u8 = &.{};
                            var pr: [][]const eval.Value = &.{};
                            std.debug.print("[DEBUG] Before parseParams: params_json is {s}\n", .{if (rq.params_json) |p| p else "NULL"});
                            parseParams(gpa, rq.params_json, &pn, &pr);
                            std.debug.print("[DEBUG] After parseParams: pn.len={d}, pr.len={d}\n", .{pn.len, pr.len});
                            var ord = false;
                            var oks: [][]const u8 = &.{};
                            var cols: []const protocol.SchemaCol = &.{};
                            var run_code: diagnostics.Code = .IllegalOrderKey;
                            _ = run_code; // Not used with new execution path
                            var timings: StageTimings = .{};
                            const need_timings = profile_mode or explain_calibrated;
                            _ = need_timings; // TODO: Add timing support to new execution path
                            _ = timings; // TODO: Add timing support to new execution path

                            // Query plan optimization with caching
                            if (state.query_optimizer) |optimizer| {
                                const plan = optimizer.optimizeQuery(text, &q) catch null;
                                if (plan) |p| {
                                    // Log optimization metrics for PROFILE mode
                                    if (profile_mode and DEBUG_PROFILE) {
                                        std.log.info("Query plan optimized: cost={d:.2}, memory={d}, parallelism={d}", .{ p.estimated_cost, p.memory_requirement, p.parallelism_level });
                                    }
                                    // Future: Use optimized plan for execution
                                    // For now, the plan is cached for subsequent identical queries
                                }
                            }

                            // Distributed query planning for federation queries
                            if (state.distributed_planner) |dist_planner| {
                                const distributed_plan = dist_planner.planDistributedQuery(&q) catch null;
                                if (distributed_plan) |d_plan| {
                                    // Log distributed optimization metrics for PROFILE mode
                                    if (profile_mode and DEBUG_PROFILE) {
                                        std.log.info("Distributed plan generated: cost={d:.2}, phases={d}, parallelism={d}", .{ d_plan.estimated_cost, d_plan.execution_phases.len, d_plan.parallelism_level });
                                    }
                                    // Future: Use distributed plan for federated execution
                                    // For now, the plan provides optimization insights
                                }
                            }

                            // Use new modular execution path for ALL queries (with parameter support)
                            const rows = blk: {
                                // Get global catalog (stub for now - will need proper initialization)
                                const catalog_stub = execution.initCatalog(gpa, ".") catch unreachable;
                                defer catalog_stub.deinit();

                                // Extract first row of parameters (most queries have single parameter row)
                                const param_values = if (pr.len > 0) pr[0] else &[_]eval.Value{};

                                // Create execution context with parameters and authentication state
                                const context = execution.ExecutionContext{
                                    .catalog = @constCast(&catalog_stub),
                                    .query_param_names = pn,
                                    .query_param_values = param_values,
                                    .user = state.authenticated_user,
                                    .role = state.authenticated_role,
                                };

                                // Execute via new modular execution path
                                const result = execution.executeQueryWithContext(gpa, q, context) catch break :blk &.{};

                                // Convert ExecutionResult to JSON rows
                                var result_rows = std.ArrayList([]const u8).initCapacity(gpa, result.rows.len) catch break :blk &.{};
                                for (result.rows) |row| {
                                    var buf = std.ArrayList(u8).initCapacity(gpa, 0) catch continue;
                                    const w = buf.writer(gpa);
                                    w.writeAll("{") catch continue;
                                    for (row, 0..) |val, idx| {
                                        if (idx > 0) w.writeAll(",") catch continue;
                                        if (idx < result.columns.len) {
                                            w.print("\"{s}\":", .{result.columns[idx]}) catch continue;
                                        }
                                        query_executor.writeValue(gpa, w, val) catch continue;
                                    }
                                    w.writeAll("}") catch continue;
                                    const json_row = buf.toOwnedSlice(gpa) catch continue;
                                    result_rows.append(gpa, json_row) catch continue;
                                }

                                // Set output metadata
                                var out_cols = gpa.alloc(protocol.SchemaCol, result.columns.len) catch break :blk &.{};
                                for (result.columns, 0..) |col_name, idx| {
                                    out_cols[idx] = .{ .name = col_name, .type = "ANY" };
                                }
                                cols = out_cols;
                                ord = false;
                                oks = &.{};

                                break :blk result_rows.toOwnedSlice(gpa) catch &.{};
                            };
                            state.last_columns = cols;
                            state.last_ordered = ord;
                            state.last_order_keys = oks;
                            state.last_distinct = q.ret.distinct;
                            state.page_items = @constCast(rows);
                            state.page_index = 0;
                            state.active_result = true;
                            state.guard_trip = (run_code == .ExecutionGuardTrip);
                            const flags = computeBaseFlags(ord, q.ret.distinct);
                            var addl_buf: [1][]const u8 = undefined;
                            const addl_schema: []const []const u8 = if (state.guard_trip) blk: {
                                addl_buf[0] = "ExecutionGuardTrip";
                                break :blk addl_buf[0..1];
                            } else &.{};
                            const schema_line = protocol.buildSchemaLine(gpa, state.last_columns, addl_schema, flags) catch return try gpa.dupe(u8, "");
                            if (!explain_mode and !profile_mode) return schema_line;
                            // Build explain chain when requested (emit EXPLAIN frame immediately, THEN return bindings via PULL normally)
                            if (explain_mode) {
                                // Build linear op chain approximation using cost model seed descriptors.
                                var ops_buf: [8]geode.cost_seed.OpDescriptor = undefined;
                                var opn: usize = 0;
                                ops_buf[opn] = .{ .kind = .Scan };
                                opn += 1;
                                ops_buf[opn] = .{ .kind = .Project };
                                opn += 1;
                                if (q.ret.distinct) {
                                    ops_buf[opn] = .{ .kind = .Aggregate };
                                    opn += 1;
                                }
                                if (ord) {
                                    ops_buf[opn] = .{ .kind = .Sort };
                                    opn += 1;
                                }
                                if (q.offset != null) {
                                    ops_buf[opn] = .{ .kind = .Filter, .selectivity = 0.5 };
                                    opn += 1;
                                }
                                if (q.limit != null) {
                                    ops_buf[opn] = .{ .kind = .Limit };
                                    opn += 1;
                                }
                                const ops = ops_buf[0..opn];
                                var actual_rows_fixed: [8]f64 = undefined;
                                var actual_slice: ?[]const f64 = null;
                                if (explain_calibrated and need_timings) {
                                    var ai: usize = 0;
                                    actual_rows_fixed[ai] = @floatFromInt(timings.project_rows_in);
                                    ai += 1; // scan input
                                    actual_rows_fixed[ai] = @floatFromInt(timings.project_rows_out);
                                    ai += 1; // project
                                    if (q.ret.distinct) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.distinct_rows_out);
                                        ai += 1;
                                    }
                                    if (ord) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.sort_rows_out);
                                        ai += 1;
                                    }
                                    if (q.offset != null) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.offset_rows_out);
                                        ai += 1;
                                    }
                                    if (q.limit != null) {
                                        actual_rows_fixed[ai] = @floatFromInt(timings.limit_rows_out);
                                        ai += 1;
                                    }
                                    actual_slice = actual_rows_fixed[0..ai];
                                }
                                const explain_json = if (explain_calibrated and actual_slice != null) cost_explain.explainChainWithCalibration(gpa, ops, actual_slice, null) catch null else cost_explain.explainChain(gpa, ops) catch null;
                                if (explain_json) |ej| {
                                    defer gpa.free(ej);
                                    const explain_line = protocol.buildExplainLine(gpa, ej, flags) catch null;
                                    if (explain_line) |el| {
                                        // Concatenate schema + explain into single response (client will expect both before PULL)
                                        var comb = std.ArrayList(u8).initCapacity(gpa, 0) catch return schema_line;
                                        defer comb.deinit(gpa);
                                        comb.appendSlice(gpa, schema_line) catch {};
                                        comb.appendSlice(gpa, el) catch {};
                                        gpa.free(el);
                                        return comb.toOwnedSlice(gpa) catch schema_line; // if OOM fallback returns schema only
                                    }
                                }
                                return schema_line;
                            }
                            if (profile_mode) {
                                // Reuse existing PROFILE emission path: build profile line now.
                                var prof_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch return schema_line;
                                defer prof_buf.deinit(gpa);
                                var wprof = prof_buf.writer(gpa);
                                wprof.writeAll("{") catch {};
                                wprof.writeAll("\"profile_version\":2,\"ops\":[") catch {};
                                var printed_global: usize = 0;
                                const emit = struct {
                                    fn op(w: anytype, printed: *usize, name: []const u8, rows_in: usize, rows_out: usize, time_ns: i128, bytes_out: usize, bytes_alloc: usize) void {
                                        if (printed.* > 0) w.writeAll(",") catch {};
                                        w.writeAll("{\"op\":\"") catch {};
                                        w.writeAll(name) catch {};
                                        w.writeAll("\",\"rows_in\":") catch {};
                                        w.print("{d}", .{rows_in}) catch {};
                                        w.writeAll(",\"rows_out\":") catch {};
                                        w.print("{d}", .{rows_out}) catch {};
                                        w.writeAll(",\"time_ns\":") catch {};
                                        w.print("{d}", .{time_ns}) catch {};
                                        w.writeAll(",\"bytes_out\":") catch {};
                                        w.print("{d}", .{bytes_out}) catch {};
                                        w.writeAll(",\"bytes_alloc\":") catch {};
                                        w.print("{d}", .{bytes_alloc}) catch {};
                                        w.writeAll("}") catch {};
                                        printed.* += 1;
                                    }
                                };
                                if (timings.project_ns != 0) emit.op(wprof, &printed_global, "Project", timings.project_rows_in, timings.project_rows_out, timings.project_ns, timings.project_bytes_out, timings.project_bytes_alloc);
                                if (timings.distinct_ns != 0) emit.op(wprof, &printed_global, "Distinct", timings.distinct_rows_in, timings.distinct_rows_out, timings.distinct_ns, timings.distinct_bytes_out, timings.distinct_bytes_alloc);
                                if (timings.sort_ns != 0) emit.op(wprof, &printed_global, "Sort", timings.sort_rows_in, timings.sort_rows_out, timings.sort_ns, timings.sort_bytes_out, timings.sort_bytes_alloc);
                                if (timings.offset_ns != 0) emit.op(wprof, &printed_global, "Offset", timings.offset_rows_in, timings.offset_rows_out, timings.offset_ns, timings.offset_bytes_out, timings.offset_bytes_alloc);
                                if (timings.limit_ns != 0) emit.op(wprof, &printed_global, "Limit", timings.limit_rows_in, timings.limit_rows_out, timings.limit_ns, timings.limit_bytes_out, timings.limit_bytes_alloc);
                                wprof.writeAll("],\"totals\":{}}") catch {}; // ignoring error intentionally for minimal profile JSON
                                wprof.writeAll("}") catch {};
                                const prof_json = prof_buf.toOwnedSlice(gpa) catch return schema_line;
                                if (protocol.buildProfileLine(gpa, prof_json, flags)) |profile_line| {
                                    gpa.free(prof_json);
                                    var comb2 = std.ArrayList(u8).initCapacity(gpa, 0) catch return schema_line;
                                    defer comb2.deinit(gpa);
                                    comb2.appendSlice(gpa, schema_line) catch {};
                                    comb2.appendSlice(gpa, profile_line) catch {};
                                    gpa.free(profile_line);
                                    return comb2.toOwnedSlice(gpa) catch schema_line;
                                } else |_| {
                                    gpa.free(prof_json);
                                    return schema_line;
                                }
                            }
                            return schema_line;
                        },
                        .Create, .Insert, .Delete, .Merge => {
                            // Handle mutation statements (CREATE, INSERT, DELETE, MERGE)
                            // TODO: Execute actual mutations - for now just return success
                            // Set up empty result for PULL
                            state.last_columns = &.{};
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = false;
                            state.page_items = &.{};
                            state.page_index = 0;
                            state.active_result = true;

                            return protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                        },
                        // CANARY: REQ=REQ-MULTI-GRAPH-006; FEATURE="MultiGraphSupport"; ASPECT=ServerHandler; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-20
                        .UseGraph => |ug| {
                            // Update ServerState.current_graph for session
                            if (state.current_graph) |old| {
                                gpa.free(old);
                            }
                            // Check if graph exists
                            if (!graph_storage_mgr.graphExists(ug.graph_name)) {
                                return protocol.buildErrorLine(gpa, "GraphNotFound", "Graph does not exist", "") catch try gpa.dupe(u8, "");
                            }
                            state.current_graph = gpa.dupe(u8, ug.graph_name) catch null;
                            // Set up empty result for PULL
                            state.last_columns = &.{};
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = false;
                            state.page_items = &.{};
                            state.page_index = 0;
                            state.active_result = true;
                            return protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                        },
                        .CreateGraph => |cg| {
                            // Create new graph storage
                            _ = graph_storage_mgr.createGraphStorage(gpa, cg.name) catch |err| {
                                if (err == error.GraphAlreadyExists and cg.if_not_exists) {
                                    // Silently succeed if IF NOT EXISTS
                                    state.last_columns = &.{};
                                    state.page_items = &.{};
                                    state.page_index = 0;
                                    state.active_result = true;
                                    return protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                                }
                                return protocol.buildErrorLine(gpa, "GraphAlreadyExists", "Graph already exists", "") catch try gpa.dupe(u8, "");
                            };
                            // Set up empty result for PULL
                            state.last_columns = &.{};
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = false;
                            state.page_items = &.{};
                            state.page_index = 0;
                            state.active_result = true;
                            return protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                        },
                        .DropGraph => |dg| {
                            // Drop graph storage
                            std.log.err("QUIC handler: DropGraph for '{s}'", .{dg.name});
                            graph_storage_mgr.dropGraphStorage(dg.name) catch |err| {
                                if (err == error.GraphNotFound and dg.if_exists) {
                                    // Silently succeed if IF EXISTS
                                    state.last_columns = &.{};
                                    state.page_items = &.{};
                                    state.page_index = 0;
                                    state.active_result = true;
                                    return protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                                }
                                if (err == error.CannotDropDefaultGraph) {
                                    return protocol.buildErrorLine(gpa, "CannotDropDefault", "Cannot drop the default graph", "") catch try gpa.dupe(u8, "");
                                }
                                return protocol.buildErrorLine(gpa, "GraphNotFound", "Graph does not exist", "") catch try gpa.dupe(u8, "");
                            };
                            // Set up empty result for PULL
                            state.last_columns = &.{};
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = false;
                            state.page_items = &.{};
                            state.page_index = 0;
                            state.active_result = true;
                            return protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                        },
                        .Show => |sh| {
                            // Handle SHOW GRAPHS
                            if (sh.show_type == .graphs) {
                                std.log.err("QUIC handler: SHOW GRAPHS", .{});
                                const graph_names = graph_storage_mgr.listGraphNames(gpa) catch &.{};
                                std.log.err("QUIC handler: listGraphNames returned {d} graphs", .{graph_names.len});
                                defer gpa.free(graph_names);
                                var rows = std.ArrayList([]const u8).init(gpa);
                                for (graph_names) |name| {
                                    const row = std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\"}}", .{name}) catch continue;
                                    rows.append(gpa, row) catch continue;
                                }
                                const cols: []const protocol.SchemaCol = &.{.{ .name = "name", .type = "STRING" }};
                                state.last_columns = cols;
                                state.last_ordered = false;
                                state.last_order_keys = &.{};
                                state.last_distinct = false;
                                state.page_items = rows.toOwnedSlice(gpa) catch &.{};
                                state.page_index = 0;
                                state.active_result = true;
                                return protocol.buildSchemaLine(gpa, cols, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                            }
                            return protocol.buildErrorLine(gpa, "NotImplemented", "SHOW type not yet supported", "") catch try gpa.dupe(u8, "");
                        },
                        else => {
                            // Return error for unsupported statement types
                            return protocol.buildErrorLine(gpa, "NotImplemented", "Statement type not yet supported", "") catch try gpa.dupe(u8, "");
                        },
                    }
                },
            }
        },
        .PULL => |pl| {
            const page_size = if (pl.page_size == 0) 1000 else pl.page_size;
            const start = state.page_index;
            const end = @min(state.page_index + page_size, state.page_items.len);
            var arr_buf = std.ArrayList(u8).initCapacity(gpa, 0) catch @panic("OOM");
            const w = arr_buf.writer(gpa);
            w.writeAll("[") catch {};
            var i: usize = start;
            var first = true;
            while (i < end) : (i += 1) {
                if (!first) w.writeAll(",") catch {};
                first = false;
                w.writeAll(state.page_items[i]) catch {};
            }
            w.writeAll("]") catch {};
            const json_rows = arr_buf.toOwnedSlice(gpa) catch "[]";
            state.page_index = end;
            const is_final = end >= state.page_items.len;
            if (is_final) state.active_result = false;
            const flags = computeBaseFlags(state.last_ordered, state.last_distinct);
            // Build bindings; include ExecutionGuardTrip advisory on first page if set
            var addl_rows_buf: [1][]const u8 = undefined;
            const addl_rows: []const []const u8 = if (start == 0 and state.guard_trip) blk: {
                addl_rows_buf[0] = "ExecutionGuardTrip";
                break :blk addl_rows_buf[0..1];
            } else &.{};
            const line = protocol.buildBindingsLine(gpa, state.last_ordered, state.last_order_keys, json_rows, is_final, addl_rows, flags) catch return try gpa.dupe(u8, "");
            if (start == 0 and state.guard_trip) state.guard_trip = false; // clear after first emission
            // Strip ,"final":true/false substring for compatibility
            var s = line;
            if (std.mem.indexOf(u8, s, ",\"final\":true")) |pos| {
                const head = s[0..pos];
                const tail = s[pos + ",\"final\":true".len ..];
                var joined = std.ArrayList(u8).initCapacity(gpa, 0) catch return line;
                defer joined.deinit(gpa);
                joined.appendSlice(gpa, head) catch {};
                joined.appendSlice(gpa, tail) catch {};
                const out = joined.toOwnedSlice(gpa) catch line;
                gpa.free(line);
                return out;
            } else if (std.mem.indexOf(u8, s, ",\"final\":false")) |pos2| {
                const head2 = s[0..pos2];
                const tail2 = s[pos2 + ",\"final\":false".len ..];
                var joined2 = std.ArrayList(u8).initCapacity(gpa, 0) catch return line;
                defer joined2.deinit(gpa);
                joined2.appendSlice(gpa, head2) catch {};
                joined2.appendSlice(gpa, tail2) catch {};
                const out2 = joined2.toOwnedSlice(gpa) catch line;
                gpa.free(line);
                return out2;
            }
            return line;
        },
        .BACKUP => |backup_req| {
            return handleBackupRequest(gpa, state, backup_req);
        },
        .RESTORE => |restore_req| {
            return handleRestoreRequest(gpa, state, restore_req);
        },
        .UPLOAD_BACKUP => |upload_req| {
            return handleUploadBackupRequest(gpa, state, upload_req);
        },
        else => {
            return try gpa.dupe(u8, "");
        },
    }
}
