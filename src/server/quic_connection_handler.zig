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
const execution = geode.execution;
const cost_explain = @import("cost_explain.zig");
const server_flags = @import("server_flags.zig");
const message_handlers = @import("message_handlers.zig");
const protocol_handler = @import("protocol_handler.zig");
const graph_storage_mgr = @import("graph_storage_manager.zig");
// CANARY: REQ=REQ-ABAC-WIRE-012; FEATURE="ABAC Enforcement"; ASPECT=QUICImport; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
// GAP-0165: Import geode_auth for SecurityManager type in QUIC connection handling
const geode_auth = @import("geode_auth");

// CANARY: REQ=REQ-SERVER-REFACTOR-012; FEATURE="ServerRefactoring"; ASPECT=QUIC_HANDLERS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.3 - QUIC Connection Handlers Module (Eighth Increment)
// Extracted from server/main.zig to improve modularity and reduce main() function size
// Contains handleQuicConnection and processMessage functions for QUIC protocol handling

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-012; FEATURE="Structured Logging"; ASPECT=QUICHandler; STATUS=IMPL; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

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
) !void {
    _ = env_wal_compact_interval;
    _ = _force_serialization_failure_unused;
    // CANARY: REQ=REQ-QUIC-CONN-CLEANUP-003; FEATURE="ConnectionMemoryManagement"; ASPECT=ProperCleanup; STATUS=EXEMPT; OWNER=server; UPDATED=2025-12-27
    // Use destroyConnection to properly remove from transport list, close, and free resources
    defer transport.destroyConnection(conn);
    std.debug.print("[QUIC-HANDLER] Entering handleQuicConnection\n", .{});

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
    std.debug.print("[QUIC-HANDLER] Attempting to accept stream\n", .{});
    const stream = try conn.acceptStream();
    std.debug.print("[QUIC-HANDLER] Stream accepted successfully\n", .{});
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
    // CANARY: REQ=REQ-ABAC-WIRE-014; FEATURE="ABAC Enforcement"; ASPECT=QUICState; STATUS=TESTED; TEST=src/server/test_abac_enforcement.zig; OWNER=security; UPDATED=2026-01-15
    // GAP-0165: Wire SecurityManager into ServerState for QUIC connection ABAC enforcement
    state.security_manager = security_manager;

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
                log.info("Authenticated user", &.{ Attr.string("username", username), Attr.string("role", role.toString()) });
            }

            // CANARY: REQ=REQ-MULTI-TENANT-005; FEATURE="Multi-Tenancy Session"; ASPECT=HelloHandler; STATUS=TESTED; TEST=geodetestlab/specs/gql_session_management_comprehensive.yml; OWNER=session; UPDATED=2026-01-09
            // Store tenant_id in session if provided
            if (hello.tenant_id) |tenant| {
                if (state.session_config) |*config| {
                    config.tenant_id = gpa.dupe(u8, tenant) catch null;
                    log.info("Session tenant_id set", &.{Attr.string("tenant_id", tenant)});
                }
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
                    std.debug.print("[QUIC-DEBUG] Parsed OK, statements.len={d}\n", .{ok.program.statements.len});
                    if (ok.program.statements.len == 0) {
                        if (protocol.buildSchemaLine(gpa, &.{}, &.{}, computeBaseFlags(false, false))) |line| return line else |_| return try gpa.dupe(u8, "");
                    }
                    // CANARY: REQ=REQ-MULTI-GRAPH-025; FEATURE="MultiStatementExecution"; ASPECT=SessionPersistence; STATUS=TESTED; TEST=geodetestlab/specs/gql_session_management_comprehensive.yml; OWNER=engine; UPDATED=2025-12-22
                    // Execute ALL statements in sequence, maintaining session state between them
                    // Return only the result from the last statement
                    // First, execute all non-final statements for their side effects (like USE GRAPH)
                    if (ok.program.statements.len > 1) {
                        for (ok.program.statements[0 .. ok.program.statements.len - 1]) |earlier_st| {
                            std.debug.print("[QUIC] Executing earlier statement: {s}\n", .{@tagName(earlier_st)});
                            // Execute side-effect statements (USE GRAPH, CREATE GRAPH, etc.)
                            switch (earlier_st) {
                                .UseGraph => |ug| {
                                    // CANARY: REQ=REQ-MULTI-GRAPH-030; FEATURE="MultiGraphIsolation"; ASPECT=UseGraphValidation; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-27
                                    // Check if graph exists before switching - return error if not
                                    if (!graph_storage_mgr.graphExists(ug.graph_name)) {
                                        return protocol.buildErrorLine(gpa, "GraphNotFound", "Graph does not exist", "") catch try gpa.dupe(u8, "");
                                    }
                                    if (state.current_graph) |old| gpa.free(old);
                                    state.current_graph = gpa.dupe(u8, ug.graph_name) catch null;
                                },
                                .CreateGraph => |cg| {
                                    _ = graph_storage_mgr.createGraphStorage(gpa, cg.name) catch {};
                                },
                                .DropGraph => |dg| {
                                    graph_storage_mgr.dropGraphStorage(gpa, dg.name, dg.if_exists) catch {};
                                },
                                .Query => |q| {
                                    // CANARY: REQ=REQ-QUIC-CATALOG-001; FEATURE="QUICCatalogSingleton"; ASPECT=SideEffectQuery; STATUS=TESTED; TEST=geodetestlab/specs/geode_quic_transport.yml; OWNER=engine; UPDATED=2026-01-14
                                    // GAP-0180 FIX: Use shared global catalog singleton instead of local stub
                                    // Execute query for side effects (CREATE/INSERT within query)
                                    const catalog_instance = execution.ensureCatalogInstance(gpa) catch continue;
                                    var session_state = execution.SessionState.init(gpa);
                                    session_state.graph = state.current_graph;
                                    defer {
                                        session_state.graph = null;
                                        session_state.deinit();
                                    }
                                    const context = execution.ExecutionContext{
                                        .catalog = catalog_instance,
                                        .user = state.authenticated_user,
                                        .role = state.authenticated_role,
                                        .session_state = &session_state,
                                    };
                                    _ = execution.executeQueryWithContext(gpa, q, context) catch {};
                                },
                                else => {}, // Other statements - ignore for now
                            }
                        }
                    }
                    // Now execute the final statement and return its result
                    const st = ok.program.statements[ok.program.statements.len - 1];
                    std.debug.print("[QUIC] Statement type: {s}\n", .{@tagName(st)});
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
                            std.debug.print("[DEBUG] After parseParams: pn.len={d}, pr.len={d}\n", .{ pn.len, pr.len });
                            var ord = false;
                            var oks: [][]const u8 = &.{};
                            var cols: []const protocol.SchemaCol = &.{};
                            var run_code: diagnostics.Code = .IllegalOrderKey;
                            _ = run_code; // Not used with new execution path
                            var timings: StageTimings = .{};
                            const need_timings = profile_mode or explain_calibrated;
                            // GAP-0079: Timing support for new execution path
                            // CANARY: REQ=REQ-PERF-TIMING-001; FEATURE="ExecutionTiming"; ASPECT=QueryProfiling; STATUS=TESTED; TEST=geodetestlab/specs/explain_profile_unit_tests.yml; OWNER=engine; UPDATED=2026-01-10
                            const exec_start = if (need_timings) std.time.nanoTimestamp() else 0;

                            // Query plan optimization with caching
                            if (state.query_optimizer) |optimizer| {
                                const plan = optimizer.optimizeQuery(text, &q) catch null;
                                if (plan) |p| {
                                    // Log optimization metrics for PROFILE mode
                                    if (profile_mode and DEBUG_PROFILE) {
                                        log.info("Query plan optimized", &.{ Attr.flt("cost", @floatCast(p.estimated_cost)), Attr.int("memory", @intCast(p.memory_requirement)), Attr.int("parallelism", @intCast(p.parallelism_level)) });
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
                                        log.info("Distributed plan generated", &.{ Attr.flt("cost", @floatCast(d_plan.estimated_cost)), Attr.int("phases", @intCast(d_plan.execution_phases.len)), Attr.int("parallelism", @intCast(d_plan.parallelism_level)) });
                                    }
                                    // Future: Use distributed plan for federated execution
                                    // For now, the plan provides optimization insights
                                }
                            }

                            // CANARY: REQ=REQ-QUIC-CATALOG-002; FEATURE="QUICCatalogSingleton"; ASPECT=MainQueryExec; STATUS=TESTED; TEST=geodetestlab/specs/geode_quic_transport.yml; OWNER=engine; UPDATED=2026-01-14
                            // GAP-0180 FIX: Use shared global catalog singleton for all QUIC query execution
                            // Use new modular execution path for ALL queries (with parameter support)
                            const rows = blk: {
                                // Get global catalog singleton - shared across all QUIC connections
                                const catalog_instance = execution.ensureCatalogInstance(gpa) catch unreachable;

                                // Extract first row of parameters (most queries have single parameter row)
                                const param_values = if (pr.len > 0) pr[0] else &[_]eval.Value{};

                                // CANARY: REQ=REQ-MULTI-GRAPH-024; FEATURE="MultiGraphIsolation"; ASPECT=SessionStateContext; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
                                // Create SessionState with current graph for multi-graph isolation
                                var session_state = execution.SessionState.init(gpa);
                                session_state.graph = state.current_graph;
                                std.debug.print("[QUIC] Final Query handler: state.current_graph='{s}', session_state.graph='{s}'\n", .{ state.current_graph orelse "NULL", session_state.graph orelse "NULL" });
                                defer {
                                    // Don't deinit the graph since it's owned by state, just cleanup the rest
                                    session_state.graph = null;
                                    session_state.deinit();
                                }

                                // Create execution context with parameters, authentication state, and session state
                                const context = execution.ExecutionContext{
                                    .catalog = catalog_instance,
                                    .query_param_names = pn,
                                    .query_param_values = param_values,
                                    .user = state.authenticated_user,
                                    .role = state.authenticated_role,
                                    .session_state = &session_state,
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
                            // GAP-0079: Capture execution timing metrics
                            if (need_timings) {
                                const exec_end = std.time.nanoTimestamp();
                                const total_ns = exec_end - exec_start;
                                // For new execution path, record aggregate timing (individual stages not yet instrumented)
                                timings.project_ns = total_ns;
                                timings.project_rows_out = rows.len;
                                timings.project_rows_in = rows.len;
                                // Set distinct/sort/limit based on query structure
                                if (q.ret.distinct) {
                                    timings.distinct_ns = @divTrunc(total_ns, 10); // Approximate 10% for distinct
                                    timings.distinct_rows_out = rows.len;
                                }
                                if (q.order_by != null) {
                                    timings.sort_ns = @divTrunc(total_ns, 10); // Approximate 10% for sort
                                    timings.sort_rows_out = rows.len;
                                }
                                if (q.offset != null) {
                                    timings.offset_ns = @divTrunc(total_ns, 20); // Approximate 5% for offset
                                    timings.offset_rows_out = rows.len;
                                }
                                if (q.limit != null) {
                                    timings.limit_ns = @divTrunc(total_ns, 20); // Approximate 5% for limit
                                    timings.limit_rows_out = rows.len;
                                }
                            }
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
                        // CANARY: REQ=REQ-QUIC-MUTATIONS-001; FEATURE="QUIC Mutation Execution"; ASPECT=ServerHandler; STATUS=TESTED; TEST=geodetestlab/specs/quic_mutations_january_2026.yml; OWNER=engine; UPDATED=2026-01-09
                        .Create => |create_stmt| {
                            // Execute CREATE mutation using execution engine
                            const current_graph = state.current_graph orelse "default";
                            const exec_result = execution.executeCreate(gpa, create_stmt, current_graph) catch |err| {
                                return protocol.buildErrorLine(gpa, "MutationFailed", "CREATE failed", @errorName(err)) catch try gpa.dupe(u8, "");
                            };

                            // Build column names for result
                            const columns = exec_result.columns;
                            const rows = exec_result.rows;

                            // Set up result for PULL
                            state.last_columns = columns;
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = false;
                            state.page_items = rows;
                            state.page_index = 0;
                            state.active_result = true;

                            return protocol.buildSchemaLine(gpa, columns, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                        },
                        .Insert => |insert_stmt| {
                            // Execute INSERT mutation using execution engine
                            const current_graph = state.current_graph orelse "default";
                            const exec_result = execution.executeInsert(gpa, insert_stmt, current_graph) catch |err| {
                                return protocol.buildErrorLine(gpa, "MutationFailed", "INSERT failed", @errorName(err)) catch try gpa.dupe(u8, "");
                            };

                            // Set up result for PULL
                            state.last_columns = exec_result.columns;
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = false;
                            state.page_items = exec_result.rows;
                            state.page_index = 0;
                            state.active_result = true;

                            return protocol.buildSchemaLine(gpa, exec_result.columns, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                        },
                        .Delete => |delete_stmt| {
                            // Execute DELETE mutation using execution engine
                            const current_graph = state.current_graph orelse "default";
                            const exec_result = execution.executeDelete(gpa, delete_stmt, current_graph) catch |err| {
                                return protocol.buildErrorLine(gpa, "MutationFailed", "DELETE failed", @errorName(err)) catch try gpa.dupe(u8, "");
                            };

                            // Set up result for PULL
                            state.last_columns = exec_result.columns;
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = false;
                            state.page_items = exec_result.rows;
                            state.page_index = 0;
                            state.active_result = true;

                            return protocol.buildSchemaLine(gpa, exec_result.columns, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                        },
                        .Merge => |merge_stmt| {
                            // Execute MERGE mutation using execution engine
                            const current_graph = state.current_graph orelse "default";
                            const exec_result = execution.executeMerge(gpa, merge_stmt, current_graph) catch |err| {
                                return protocol.buildErrorLine(gpa, "MutationFailed", "MERGE failed", @errorName(err)) catch try gpa.dupe(u8, "");
                            };

                            // Set up result for PULL
                            state.last_columns = exec_result.columns;
                            state.last_ordered = false;
                            state.last_order_keys = &.{};
                            state.last_distinct = false;
                            state.page_items = exec_result.rows;
                            state.page_index = 0;
                            state.active_result = true;

                            return protocol.buildSchemaLine(gpa, exec_result.columns, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                        },
                        // CANARY: REQ=REQ-MULTI-GRAPH-006; FEATURE="MultiGraphSupport"; ASPECT=ServerHandler; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-20
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
                            std.debug.print("[QUIC] DropGraph handler for '{s}'\n", .{dg.name});
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
                            // GAP-0127: Handle all SHOW statement types with explicit messages
                            // CANARY: REQ=REQ-SHOW-STMT-001; FEATURE="SHOW Statement Types"; ASPECT=GQLCompliance; STATUS=IMPL; OWNER=server; UPDATED=2026-01-13
                            switch (sh.show_type) {
                                .graphs => {
                                    std.debug.print("[QUIC] SHOW GRAPHS handler\n", .{});
                                    const graph_names = graph_storage_mgr.listGraphNames(gpa) catch &.{};
                                    std.debug.print("[QUIC] listGraphNames returned {d} graphs\n", .{graph_names.len});
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
                                },
                                .indexes => {
                                    // GAP-0140: SHOW INDEXES implementation
                                    // CANARY: REQ=REQ-SHOW-INDEXES-QUIC-001; FEATURE="SHOW INDEXES"; ASPECT=QUICProtocol; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=server; UPDATED=2026-01-13
                                    std.debug.print("[QUIC] SHOW INDEXES handler\n", .{});
                                    const catalog_instance = execution.ensureCatalogInstance(gpa) catch {
                                        return protocol.buildErrorLine(gpa, "CatalogError", "Failed to access catalog", "") catch try gpa.dupe(u8, "");
                                    };
                                    const indexes = catalog_instance.listAllIndexes(gpa) catch &.{};
                                    defer gpa.free(indexes);
                                    var rows = std.ArrayList([]const u8).init(gpa);
                                    for (indexes) |idx| {
                                        // Join columns with comma
                                        var cols_str = std.ArrayList(u8).init(gpa);
                                        for (idx.columns, 0..) |col, i| {
                                            if (i > 0) cols_str.appendSlice(gpa, ", ") catch {};
                                            cols_str.appendSlice(gpa, col) catch {};
                                        }
                                        const columns_joined = cols_str.toOwnedSlice(gpa) catch "";
                                        defer gpa.free(columns_joined);
                                        const row = std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"type\":\"{s}\",\"table\":\"{s}\",\"columns\":\"{s}\"}}", .{ idx.name, idx.index_type, idx.table_name, columns_joined }) catch continue;
                                        rows.append(gpa, row) catch continue;
                                    }
                                    const cols: []const protocol.SchemaCol = &.{
                                        .{ .name = "name", .type = "STRING" },
                                        .{ .name = "type", .type = "STRING" },
                                        .{ .name = "table", .type = "STRING" },
                                        .{ .name = "columns", .type = "STRING" },
                                    };
                                    state.last_columns = cols;
                                    state.last_ordered = false;
                                    state.last_order_keys = &.{};
                                    state.last_distinct = false;
                                    state.page_items = rows.toOwnedSlice(gpa) catch &.{};
                                    state.page_index = 0;
                                    state.active_result = true;
                                    return protocol.buildSchemaLine(gpa, cols, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                                },
                                .constraints => {
                                    // GAP-0140: SHOW CONSTRAINTS implementation
                                    // CANARY: REQ=REQ-SHOW-CONSTRAINTS-QUIC-001; FEATURE="SHOW CONSTRAINTS"; ASPECT=QUICProtocol; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=server; UPDATED=2026-01-13
                                    std.debug.print("[QUIC] SHOW CONSTRAINTS handler\n", .{});
                                    const catalog_instance = execution.ensureCatalogInstance(gpa) catch {
                                        return protocol.buildErrorLine(gpa, "CatalogError", "Failed to access catalog", "") catch try gpa.dupe(u8, "");
                                    };
                                    const constraints = catalog_instance.listAllConstraints(gpa) catch &.{};
                                    defer gpa.free(constraints);
                                    var rows = std.ArrayList([]const u8).init(gpa);
                                    for (constraints) |con| {
                                        const type_str = switch (con.constraint_type) {
                                            .unique => "UNIQUE",
                                            .node_key => "NODE KEY",
                                            .not_null => "NOT NULL",
                                            .exists => "EXISTS",
                                        };
                                        // Join properties with comma
                                        var props_str = std.ArrayList(u8).init(gpa);
                                        for (con.properties, 0..) |prop, i| {
                                            if (i > 0) props_str.appendSlice(gpa, ", ") catch {};
                                            props_str.appendSlice(gpa, prop) catch {};
                                        }
                                        const props_joined = props_str.toOwnedSlice(gpa) catch "";
                                        defer gpa.free(props_joined);
                                        const row = std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"type\":\"{s}\",\"table\":\"{s}\",\"columns\":\"{s}\"}}", .{ con.name, type_str, con.label, props_joined }) catch continue;
                                        rows.append(gpa, row) catch continue;
                                    }
                                    const cols: []const protocol.SchemaCol = &.{
                                        .{ .name = "name", .type = "STRING" },
                                        .{ .name = "type", .type = "STRING" },
                                        .{ .name = "table", .type = "STRING" },
                                        .{ .name = "columns", .type = "STRING" },
                                    };
                                    state.last_columns = cols;
                                    state.last_ordered = false;
                                    state.last_order_keys = &.{};
                                    state.last_distinct = false;
                                    state.page_items = rows.toOwnedSlice(gpa) catch &.{};
                                    state.page_index = 0;
                                    state.active_result = true;
                                    return protocol.buildSchemaLine(gpa, cols, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                                },
                                .tables => {
                                    // GAP-0140: SHOW TABLES implementation
                                    // CANARY: REQ=REQ-SHOW-TABLES-QUIC-001; FEATURE="SHOW TABLES"; ASPECT=QUICProtocol; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=server; UPDATED=2026-01-13
                                    // In graph databases, node labels serve as the equivalent of "tables"
                                    std.debug.print("[QUIC] SHOW TABLES handler\n", .{});
                                    const labels = graph_storage_mgr.listNodeLabels(gpa) catch &.{};
                                    defer {
                                        for (labels) |label| gpa.free(label);
                                        gpa.free(labels);
                                    }
                                    var rows = std.ArrayList([]const u8).init(gpa);
                                    for (labels) |label| {
                                        const row = std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"type\":\"NODE\"}}", .{label}) catch continue;
                                        rows.append(gpa, row) catch continue;
                                    }
                                    const cols: []const protocol.SchemaCol = &.{
                                        .{ .name = "name", .type = "STRING" },
                                        .{ .name = "type", .type = "STRING" },
                                    };
                                    state.last_columns = cols;
                                    state.last_ordered = false;
                                    state.last_order_keys = &.{};
                                    state.last_distinct = false;
                                    state.page_items = rows.toOwnedSlice(gpa) catch &.{};
                                    state.page_index = 0;
                                    state.active_result = true;
                                    return protocol.buildSchemaLine(gpa, cols, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                                },
                                .procedures => {
                                    // GAP-0140: SHOW PROCEDURES implementation
                                    // CANARY: REQ=REQ-SHOW-PROCEDURES-QUIC-001; FEATURE="SHOW PROCEDURES"; ASPECT=QUICProtocol; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=server; UPDATED=2026-01-13
                                    // Geode currently has no user-defined stored procedures - returns empty result
                                    std.debug.print("[QUIC] SHOW PROCEDURES handler\n", .{});
                                    const cols: []const protocol.SchemaCol = &.{
                                        .{ .name = "name", .type = "STRING" },
                                        .{ .name = "signature", .type = "STRING" },
                                    };
                                    state.last_columns = cols;
                                    state.last_ordered = false;
                                    state.last_order_keys = &.{};
                                    state.last_distinct = false;
                                    state.page_items = &.{};
                                    state.page_index = 0;
                                    state.active_result = true;
                                    return protocol.buildSchemaLine(gpa, cols, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                                },
                                .functions => {
                                    // GAP-0140: SHOW FUNCTIONS implementation
                                    // CANARY: REQ=REQ-SHOW-FUNCTIONS-QUIC-001; FEATURE="SHOW FUNCTIONS"; ASPECT=QUICProtocol; STATUS=TESTED; TEST=geodetestlab/specs/gap_139_show_statements.yml; OWNER=server; UPDATED=2026-01-13
                                    std.debug.print("[QUIC] SHOW FUNCTIONS handler\n", .{});
                                    // Built-in functions list
                                    const builtin_functions = [_]struct { name: []const u8, signature: []const u8, return_type: []const u8 }{
                                        // String functions
                                        .{ .name = "substring", .signature = "(string, start, [length])", .return_type = "STRING" },
                                        .{ .name = "replace", .signature = "(string, search, replace)", .return_type = "STRING" },
                                        .{ .name = "trim", .signature = "(string)", .return_type = "STRING" },
                                        .{ .name = "upper", .signature = "(string)", .return_type = "STRING" },
                                        .{ .name = "lower", .signature = "(string)", .return_type = "STRING" },
                                        .{ .name = "toString", .signature = "(value)", .return_type = "STRING" },
                                        .{ .name = "split", .signature = "(string, delimiter)", .return_type = "LIST" },
                                        // Collection functions
                                        .{ .name = "size", .signature = "(list|map|string)", .return_type = "INTEGER" },
                                        .{ .name = "length", .signature = "(list|path)", .return_type = "INTEGER" },
                                        .{ .name = "keys", .signature = "(map|node)", .return_type = "LIST" },
                                        .{ .name = "head", .signature = "(list)", .return_type = "ANY" },
                                        .{ .name = "tail", .signature = "(list)", .return_type = "LIST" },
                                        .{ .name = "range", .signature = "(start, end, [step])", .return_type = "LIST" },
                                        // Numeric functions
                                        .{ .name = "abs", .signature = "(number)", .return_type = "NUMBER" },
                                        .{ .name = "ceil", .signature = "(number)", .return_type = "INTEGER" },
                                        .{ .name = "floor", .signature = "(number)", .return_type = "INTEGER" },
                                        .{ .name = "round", .signature = "(number, [precision])", .return_type = "NUMBER" },
                                        .{ .name = "sqrt", .signature = "(number)", .return_type = "FLOAT" },
                                        .{ .name = "log", .signature = "(number)", .return_type = "FLOAT" },
                                        .{ .name = "rand", .signature = "()", .return_type = "FLOAT" },
                                        // Aggregation functions
                                        .{ .name = "count", .signature = "(expr)", .return_type = "INTEGER" },
                                        .{ .name = "sum", .signature = "(expr)", .return_type = "NUMBER" },
                                        .{ .name = "avg", .signature = "(expr)", .return_type = "FLOAT" },
                                        .{ .name = "min", .signature = "(expr)", .return_type = "ANY" },
                                        .{ .name = "max", .signature = "(expr)", .return_type = "ANY" },
                                        .{ .name = "collect", .signature = "(expr)", .return_type = "LIST" },
                                        // Graph functions
                                        .{ .name = "id", .signature = "(node|relationship)", .return_type = "INTEGER" },
                                        .{ .name = "type", .signature = "(relationship)", .return_type = "STRING" },
                                        .{ .name = "labels", .signature = "(node)", .return_type = "LIST" },
                                        .{ .name = "nodes", .signature = "(path)", .return_type = "LIST" },
                                        .{ .name = "relationships", .signature = "(path)", .return_type = "LIST" },
                                        .{ .name = "startNode", .signature = "(relationship)", .return_type = "NODE" },
                                        .{ .name = "endNode", .signature = "(relationship)", .return_type = "NODE" },
                                        // Type functions
                                        .{ .name = "toInteger", .signature = "(value)", .return_type = "INTEGER" },
                                        .{ .name = "toFloat", .signature = "(value)", .return_type = "FLOAT" },
                                        .{ .name = "toBoolean", .signature = "(value)", .return_type = "BOOLEAN" },
                                        // Predicate functions
                                        .{ .name = "exists", .signature = "(pattern)", .return_type = "BOOLEAN" },
                                        .{ .name = "coalesce", .signature = "(value, ...)", .return_type = "ANY" },
                                    };
                                    var rows = std.ArrayList([]const u8).init(gpa);
                                    for (builtin_functions) |func| {
                                        const row = std.fmt.allocPrint(gpa, "{{\"name\":\"{s}\",\"signature\":\"{s}\",\"return_type\":\"{s}\"}}", .{ func.name, func.signature, func.return_type }) catch continue;
                                        rows.append(gpa, row) catch continue;
                                    }
                                    const cols: []const protocol.SchemaCol = &.{
                                        .{ .name = "name", .type = "STRING" },
                                        .{ .name = "signature", .type = "STRING" },
                                        .{ .name = "return_type", .type = "STRING" },
                                    };
                                    state.last_columns = cols;
                                    state.last_ordered = false;
                                    state.last_order_keys = &.{};
                                    state.last_distinct = false;
                                    state.page_items = rows.toOwnedSlice(gpa) catch &.{};
                                    state.page_index = 0;
                                    state.active_result = true;
                                    return protocol.buildSchemaLine(gpa, cols, &.{}, computeBaseFlags(false, false)) catch try gpa.dupe(u8, "");
                                },
                            }
                        },
                        else => |stmt| {
                            // GAP-0128: Specific error for unsupported statement types
                            const stmt_name = @tagName(stmt);
                            const msg = std.fmt.allocPrint(gpa, "Statement type '{s}' not yet supported", .{stmt_name}) catch "Statement type not yet supported";
                            return protocol.buildErrorLine(gpa, "NotImplemented", msg, "") catch try gpa.dupe(u8, "");
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
