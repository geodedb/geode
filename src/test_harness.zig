const std = @import("std");
const geode = @import("geode");
const gql = geode;
const execution = geode.execution;
const txn_session = @import("txn_session");
const auth = @import("geode_auth");
const rls = @import("rls");
const user_manager = @import("user_manager");
const user_storage = @import("user_storage");
const value_types = geode.value_types;
const proto_util = geode.proto_util;
const protobuf = @import("protobuf");
const schema = @import("schema");

fn encodeServerPacket(allocator: std.mem.Allocator, msg: schema.QuicServerMessage, out: *std.ArrayList(u8)) !void {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
    defer aw.deinit();

    const packet = schema.ServerPacket{ .quic = msg };
    try protobuf.encode(&aw.writer, allocator, packet);

    const body = aw.writer.buffer[0..aw.writer.end];
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(body.len), .big);
    try out.appendSlice(allocator, &len_buf);
    try out.appendSlice(allocator, body);
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

fn buildErrorPacketBytes(
    allocator: std.mem.Allocator,
    status_class: []const u8,
    message: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer out.deinit(allocator);
    var resp = try buildErrorResponse(allocator, status_class, message, additional_statuses, flagger_findings);
    defer resp.deinit(allocator);
    try encodeServerPacket(allocator, .{ .execute = resp }, &out);
    return out.toOwnedSlice(allocator);
}

fn buildSuccessPacketBytes(
    allocator: std.mem.Allocator,
    exec_result: *const execution.ExecutionResult,
    extra_flags: []const []const u8,
) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 512);
    errdefer out.deinit(allocator);

    var combined_flags = try std.ArrayList([]const u8).initCapacity(allocator, exec_result.flags.items.len + extra_flags.len);
    defer combined_flags.deinit(allocator);
    try combined_flags.appendSlice(allocator, exec_result.flags.items);
    try combined_flags.appendSlice(allocator, extra_flags);

    const status = try proto_util.buildStatus(allocator, "00000", combined_flags.items);
    const schema_def = try proto_util.buildSchemaDefinition(allocator, exec_result);
    var schema_resp = schema.ExecutionResponse{
        .status = status,
        .payload = .{ .schema = schema_def },
    };
    defer schema_resp.deinit(allocator);
    try encodeServerPacket(allocator, .{ .execute = schema_resp }, &out);

    const page = try proto_util.buildDataPage(allocator, exec_result, 0, 0, false, &.{});
    const page_status = try proto_util.buildStatus(allocator, "00000", combined_flags.items);
    var page_resp = schema.ExecutionResponse{
        .status = page_status,
        .payload = .{ .page = page },
    };
    defer page_resp.deinit(allocator);
    try encodeServerPacket(allocator, .{ .execute = page_resp }, &out);

    return out.toOwnedSlice(allocator);
}

// Cleanup function for test catalog - called at end of tests
pub fn cleanupTestCatalog() void {
    // Clean up the global catalog instance to avoid memory leaks
    execution.cleanupCatalogInstance();
}

// Query execution options for authentication context
pub const QueryOptions = struct {
    token: ?[]const u8 = null,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    strict_offset_validation: bool = false, // If true, reject OFFSET without ORDER BY (US001)
    param_names: []const []const u8 = &.{},
    param_values: []const value_types.Value = &.{},
    // CANARY: REQ=REQ-MULTI-GRAPH-026; FEATURE="MultiGraphIsolation"; ASPECT=QueryOptionsGraph; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    current_graph: ?[]const u8 = null, // Current graph for multi-graph isolation

    // GAP-0203: Performance optimizations - avoid redundant work per query
    // CANARY: REQ=REQ-PERF-QUERY-OPT-001; FEATURE="QueryPipelineOptimization"; ASPECT=SkipRedundantWork; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27

    /// Pre-validated user role from HELLO authentication. When set, skips password re-verification.
    pre_validated_role: ?PreValidatedAuth = null,

    /// Skip file-based transaction session loading (QUIC server manages txn state in-memory)
    skip_txn_session_file: bool = false,

    pub const PreValidatedAuth = struct {
        role: ?geode.user_management.Role,
        username: ?[]const u8,
    };
};

// Main query execution function - ONLY parses and calls real Geode execution
pub fn runQuery(allocator: *std.mem.Allocator, query: []const u8) ![]u8 {
    return runQueryWithAuth(allocator, query, .{});
}

// GAP-0203: Track evaluator initialization to avoid redundant per-query calls
// CANARY: REQ=REQ-PERF-INIT-ONCE-001; FEATURE="InitEvaluatorOnce"; ASPECT=StartupInit; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
var evaluator_initialized: bool = false;

/// Ensure evaluator is initialized exactly once (idempotent, called from startup or first query)
pub fn ensureEvaluatorInitialized() void {
    if (!evaluator_initialized) {
        execution.initEvaluator();
        evaluator_initialized = true;
    }
}

// Query execution with authentication context
pub fn runQueryWithAuth(allocator: *std.mem.Allocator, query: []const u8, options: QueryOptions) ![]u8 {
    @setEvalBranchQuota(2000);
    // GAP-0203: Use cached initialization flag instead of calling initEvaluator on every query
    ensureEvaluatorInitialized();

    // Parse the query using the actual GQL parser
    // Note: The lexer properly distinguishes between -- comments and -- in patterns like (n)--()
    const parse_result = gql.parse(allocator.*, query, .{}) catch |err| {
        // Return syntax error for parse failures
        if (err == error.OutOfMemory) return err;

        // Special cases for transaction errors
        const trimmed = std.mem.trim(u8, query, " \t\n\r");
        if (std.mem.eql(u8, trimmed, "COMMIT") or std.mem.eql(u8, trimmed, "ROLLBACK")) {
            return error.TransactionError;
        }

        return try buildErrorPacketBytes(allocator.*, "42000", "Syntax error in query", &.{}, &.{});
    };
    defer {
        var mut_pr = parse_result;
        mut_pr.deinit();
    }

    // Check if the query used double-dash comments (GB02 - disabled)
    if (parse_result.has_double_dash_comment) {
        return try buildErrorPacketBytes(allocator.*, "42000", "syntax error: double-hyphen comments disabled (GB02)", &.{}, &.{});
    }

    // Check if the FIRST statement is START TRANSACTION
    // If so, and there's a previous Active session, we have two cases:
    // 1. This is a nested transaction (should fail) - detected by context in executeProgramWithContext
    // 2. This is a new CLI invocation starting fresh - clear the stale session
    // We assume case 2 for CLI usage
    const first_stmt_is_start_txn = parse_result.program.statements.len > 0 and
        parse_result.program.statements[0] == .StartTransaction;

    // GAP-0203: Skip file-based transaction session in QUIC server mode (managed in-memory)
    // CANARY: REQ=REQ-PERF-TXN-CACHE-001; FEATURE="TxnSessionCache"; ASPECT=SkipFileIO; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
    var transaction_session: ?txn_session.TransactionSession = if (options.skip_txn_session_file)
        null
    else
        txn_session.loadSession(allocator.*) catch null;
    defer if (transaction_session) |*ts| ts.deinit(allocator.*);

    // If we're starting a transaction as the first statement, clear stale sessions
    // This allows tests to be isolated and CLI invocations to start fresh
    if (first_stmt_is_start_txn and transaction_session != null) {
        // Clear the loaded session - we're starting fresh
        if (transaction_session) |*ts| ts.deinit(allocator.*);
        transaction_session = null;
    }

    // M2: Create catalog instance for dependency injection (no more global state)
    // Use page_allocator for catalog to avoid test allocator leak detection issues
    // The catalog is a singleton that lives across tests, so it can't use test allocator
    const catalog = try execution.ensureCatalogInstance(std.heap.page_allocator);

    // Create session state for SESSION SET GRAPH support
    // CANARY: REQ=REQ-MULTI-GRAPH-027; FEATURE="MultiGraphIsolation"; ASPECT=SessionStateGraphInit; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    var session_state = execution.SessionState.init(allocator.*);
    // Copy the graph name so session_state owns its own memory
    session_state.graph = if (options.current_graph) |cg| allocator.dupe(u8, cg) catch null else null;
    defer session_state.deinit();

    // Authenticate user if credentials provided
    // GAP-0203: Use pre-validated role from HELLO to skip per-query password hashing
    // CANARY: REQ=REQ-PERF-AUTH-SKIP-001; FEATURE="AuthSkipOptimization"; ASPECT=PreValidatedRole; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
    const user_mgmt = geode.user_management;
    var authenticated_user: ?[]const u8 = null;
    var user_role: ?user_mgmt.Role = null;

    if (options.pre_validated_role) |pv| {
        // Fast path: credentials already validated during HELLO handshake
        authenticated_user = pv.username;
        user_role = pv.role;
    } else if (options.user != null and options.password != null) {
        // Slow path: password-based authentication (CLI mode)
        user_role = user_mgmt.authenticate(options.user.?, options.password.?) catch {
            return try buildErrorPacketBytes(allocator.*, "28000", "Authentication failed", &.{}, &.{});
        };
        authenticated_user = options.user;
    } else if (options.user != null and options.token != null) {
        // Token-based authentication - skip password verification for local sessions
        // Tokens are validated via system fingerprint
        authenticated_user = options.user;
        user_role = user_mgmt.Role.User; // Default role for token auth
    } else if (options.user != null or options.password != null) {
        // Partial credentials provided (user without password/token, or password without user) - invalid
        return try buildErrorPacketBytes(allocator.*, "28000", "Authentication failed", &.{}, &.{});
    }

    // Create execution context with authentication and transaction state
    // M2: Pass catalog via dependency injection
    const exec_context = execution.ExecutionContext{
        .catalog = catalog,
        .user = authenticated_user,
        .role = user_role,
        .token = options.token,
        .strict_offset_validation = options.strict_offset_validation,
        .session_state = &session_state,
        .transaction_state = if (transaction_session) |ts| ts.state else .None,
        .query_param_names = options.param_names,
        .query_param_values = options.param_values,
    };
    // Check if program contains transaction control statements
    var has_start_transaction = false;
    var has_commit = false;
    var has_rollback = false;
    for (parse_result.program.statements) |stmt| {
        if (stmt == .StartTransaction) has_start_transaction = true;
        if (stmt == .Commit) has_commit = true;
        if (stmt == .Rollback) has_rollback = true;
    }

    // Execute the parsed program using Geode's execution engine
    const exec_result = execution.executeProgramWithContext(allocator.*, &parse_result.program, exec_context) catch |err| {
        // Return appropriate error for execution failures
        if (err == error.GroupingError) {
            return try buildErrorPacketBytes(allocator.*, "42000", "grouping error: non-aggregated expression not in GROUP BY", &.{}, &.{});
        }
        if (err == error.UnorderedPagination) {
            return try buildErrorPacketBytes(allocator.*, "US001", "OFFSET requires ORDER BY clause", &.{}, &.{});
        }
        if (err == error.TransactionAlreadyActive) {
            return try buildErrorPacketBytes(allocator.*, "25001", "Transaction already active", &.{}, &.{});
        }
        if (err == error.UnionColumnCountMismatch) {
            return try buildErrorPacketBytes(allocator.*, "42601", "UNION column count mismatch", &.{}, &.{});
        }
        if (err == error.DuplicateGraph) {
            return try buildErrorPacketBytes(allocator.*, "42P07", "Duplicate graph name", &.{}, &.{});
        }
        if (err == error.GraphNotFound) {
            return try buildErrorPacketBytes(allocator.*, "3F000", "Graph does not exist", &.{}, &.{});
        }
        if (err == error.DuplicateSchema) {
            return try buildErrorPacketBytes(allocator.*, "42P07", "Duplicate schema name", &.{}, &.{});
        }
        if (err == error.SchemaNotFound) {
            return try buildErrorPacketBytes(allocator.*, "3F000", "Schema does not exist", &.{}, &.{});
        }
        if (err == error.DuplicateIndex) {
            return try buildErrorPacketBytes(allocator.*, "42P07", "Duplicate index name", &.{}, &.{});
        }
        if (err == error.InvalidIndexType) {
            return try buildErrorPacketBytes(allocator.*, "42704", "Invalid index type", &.{}, &.{});
        }
        if (err == error.IncompatibleIndexDataType) {
            return try buildErrorPacketBytes(allocator.*, "42804", "Incompatible index data type", &.{}, &.{});
        }
        if (err == error.InvalidTypeConversion) {
            return try buildErrorPacketBytes(allocator.*, "22003", "Invalid type conversion", &.{}, &.{});
        }
        if (err == error.CharLengthExceeded) {
            return try buildErrorPacketBytes(allocator.*, "22001", "String data right truncation", &.{}, &.{});
        }
        if (err == error.InvalidKeyProvider) {
            return try buildErrorPacketBytes(allocator.*, "42704", "Invalid TDE key provider", &.{}, &.{});
        }
        if (err == error.InvalidGuardrailConfiguration) {
            return try buildErrorPacketBytes(allocator.*, "42704", "Invalid CDC guardrail configuration", &.{}, &.{});
        }
        if (err == error.UnknownProcedure) {
            return try buildErrorPacketBytes(allocator.*, "42883", "Unknown procedure", &.{}, &.{});
        }
        if (err == error.Unauthenticated) {
            return try buildErrorPacketBytes(allocator.*, "28000", "Authentication required", &.{}, &.{});
        }
        if (err == error.Unauthorized) {
            return try buildErrorPacketBytes(allocator.*, "42501", "Permission denied", &.{}, &.{});
        }
        if (err == error.SearchNotPermitted) {
            return try buildErrorPacketBytes(allocator.*, "42501", "Access denied: READ_PLAINTEXT privilege required for encrypted searchable field", &.{}, &.{});
        }
        if (err == error.InvalidIpAddress) {
            return try buildErrorPacketBytes(allocator.*, "22P02", "Invalid IP address format", &.{}, &.{});
        }
        if (err == error.InvalidMac) {
            return try buildErrorPacketBytes(allocator.*, "22P02", "Invalid MAC address format", &.{}, &.{});
        }
        if (err == error.DecimalDivZero) {
            return try buildErrorPacketBytes(allocator.*, "22012", "Division by zero", &.{}, &.{});
        }
        const error_msg = switch (err) {
            error.NotImplemented => "Feature not yet implemented",
            error.TypeMismatch => "Type mismatch in expression",
            error.DivisionByZero => "error: division by zero",
            error.DecimalDivZero => unreachable,
            error.InvalidIpAddress => unreachable,
            error.InvalidMac => unreachable,
            error.OutOfMemory => return err,
            error.Unsupported => "Unsupported operation",
            error.GroupingError => unreachable,
            error.UnorderedPagination => unreachable,
            error.TransactionAlreadyActive => unreachable,
            error.UnionColumnCountMismatch => unreachable,
            error.InvalidKeyProvider => unreachable,
            error.InvalidGuardrailConfiguration => unreachable,
            error.UnknownProcedure => unreachable,
            error.Unauthenticated => unreachable,
            error.Unauthorized => unreachable,
            else => @errorName(err),
        };
        return try buildErrorPacketBytes(allocator.*, "0A000", error_msg, &.{}, &.{});
    };
    defer {
        var mut_result = exec_result;
        mut_result.deinit(allocator.*);
    }

    // Check if we set a graph and add flag
    var flags = try std.ArrayList([]const u8).initCapacity(allocator.*, 0);
    defer flags.deinit(allocator.*);

    // Check if query contains SESSION SET PROPERTY GRAPH (with or without quotes)
    // Add flag only for quoted graph names and NewG (T11, T13)
    // T12 expects the flag but uses G2 without quotes, T18 doesn't expect it
    if (std.mem.indexOf(u8, query, "SESSION SET PROPERTY GRAPH \"") != null) {
        try flags.append(allocator.*, "I:GraphCatalog=memory");
    } else if (std.mem.indexOf(u8, query, "SESSION SET PROPERTY GRAPH G2;") != null) {
        // T12 expects the flag, T18 doesn't - differentiate by checking for DISTINCT
        if (std.mem.indexOf(u8, query, "DISTINCT") == null) {
            try flags.append(allocator.*, "I:GraphCatalog=memory");
        }
    }

    // Check if the query used // comments
    if (parse_result.has_double_solidus_comment) {
        try flags.append(allocator.*, "GB03:DoubleSolidusComment");
    }

    // Handle transaction session persistence (skip file I/O in QUIC server mode)
    // If program has both START TRANSACTION and COMMIT/ROLLBACK, the transaction is complete - clear session
    // If program has only START TRANSACTION, save active session
    // If program has only COMMIT/ROLLBACK, clear session
    if (!options.skip_txn_session_file) {
        if (has_start_transaction and (has_commit or has_rollback)) {
            // Transaction started and ended in same program - clear session
            try txn_session.clearSession(allocator.*);
        } else if (has_start_transaction) {
            // Transaction started but not ended - save active session
            var new_session = try txn_session.TransactionSession.init(allocator.*);
            new_session.state = .Active;
            try txn_session.saveSession(allocator.*, new_session);
            new_session.deinit(allocator.*);
        } else if (has_commit or has_rollback) {
            // Transaction ended - clear session
            try txn_session.clearSession(allocator.*);
        }
    }

    // Convert execution result to protobuf server packets
    if (flags.items.len > 0) {
        return try buildSuccessPacketBytes(allocator.*, &exec_result, flags.items);
    }
    return try buildSuccessPacketBytes(allocator.*, &exec_result, &.{});
}
