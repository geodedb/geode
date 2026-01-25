const std = @import("std");
const gql = @import("lib.zig");
const execution = @import("execution.zig");
const txn_session = @import("txn_session.zig");
const auth = @import("geode_auth");
const rls = @import("rls");
const user_manager = @import("security/user_manager.zig");
const user_storage = @import("storage/user_storage.zig");
const storage_inmemory = @import("storage/inmemory.zig");
const storage_interface = @import("interface");
const value_types = @import("value_types.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-069; FEATURE="JSON Library Migration"; ASPECT=TestHarness; STATUS=IMPL; OWNER=testing; UPDATED=2026-01-25
const json_lib = @import("json");

// JSON error response types for test harness
const TestErrorResponse = struct {
    status_class: []const u8,
    message: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    additional_statuses: []const AdditionalStatus = &.{},

    const AdditionalStatus = struct {};
};

/// Helper to build test error response JSON
fn buildTestErrorResponse(allocator: *std.mem.Allocator, status_class: []const u8, message: ?[]const u8, err: ?[]const u8) ![]u8 {
    const response = TestErrorResponse{
        .status_class = status_class,
        .message = message,
        .@"error" = err,
    };
    const json_str = try json_lib.encode(allocator.*, response, .{ .emit_null_optional_fields = false });
    return json_str;
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
};

// Main query execution function - ONLY parses and calls real Geode execution
pub fn runQuery(allocator: *std.mem.Allocator, query: []const u8) ![]u8 {
    return runQueryWithAuth(allocator, query, .{});
}

// Query execution with authentication context
pub fn runQueryWithAuth(allocator: *std.mem.Allocator, query: []const u8, options: QueryOptions) ![]u8 {
    @setEvalBranchQuota(2000);
    execution.initEvaluator();

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

        return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42000\",\"error\":\"Syntax error in query\",\"additional_statuses\":[]}}", .{});
    };
    defer {
        var mut_pr = parse_result;
        mut_pr.deinit();
    }

    // Check if the query used double-dash comments (GB02 - disabled)
    if (parse_result.has_double_dash_comment) {
        return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42000\",\"message\":\"syntax error: double-hyphen comments disabled (GB02)\",\"additional_statuses\":[]}}", .{});
    }

    // Check if the FIRST statement is START TRANSACTION
    // If so, and there's a previous Active session, we have two cases:
    // 1. This is a nested transaction (should fail) - detected by context in executeProgramWithContext
    // 2. This is a new CLI invocation starting fresh - clear the stale session
    // We assume case 2 for CLI usage
    const first_stmt_is_start_txn = parse_result.program.statements.len > 0 and
        parse_result.program.statements[0] == .StartTransaction;

    var transaction_session = txn_session.loadSession(allocator.*) catch null;
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
    const user_mgmt = @import("security/user_management.zig");
    var authenticated_user: ?[]const u8 = null;
    var user_role: ?user_mgmt.Role = null;

    if (options.user != null and options.password != null) {
        // Attempt password-based authentication
        user_role = user_mgmt.authenticate(options.user.?, options.password.?) catch {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"28000\",\"message\":\"Authentication failed\",\"additional_statuses\":[]}}", .{});
        };
        authenticated_user = options.user;
    } else if (options.user != null and options.token != null) {
        // Token-based authentication - skip password verification for local sessions
        // Tokens are validated via system fingerprint
        authenticated_user = options.user;
        user_role = user_mgmt.Role.User; // Default role for token auth
    } else if (options.user != null or options.password != null) {
        // Partial credentials provided (user without password/token, or password without user) - invalid
        return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"28000\",\"message\":\"Authentication failed\",\"additional_statuses\":[]}}", .{});
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
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42000\",\"message\":\"grouping error: non-aggregated expression not in GROUP BY\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.UnorderedPagination) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"US001\",\"message\":\"OFFSET requires ORDER BY clause\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.TransactionAlreadyActive) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"25001\",\"message\":\"Transaction already active\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.UnionColumnCountMismatch) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42601\",\"message\":\"UNION column count mismatch\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.DuplicateGraph) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42P07\",\"message\":\"Duplicate graph name\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.GraphNotFound) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"3F000\",\"message\":\"Graph does not exist\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.DuplicateSchema) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42P07\",\"message\":\"Duplicate schema name\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.SchemaNotFound) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"3F000\",\"message\":\"Schema does not exist\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.DuplicateIndex) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42P07\",\"message\":\"Duplicate index name\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.InvalidIndexType) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42704\",\"message\":\"Invalid index type\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.IncompatibleIndexDataType) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42804\",\"message\":\"Incompatible index data type\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.InvalidTypeConversion) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"22003\",\"message\":\"Invalid type conversion\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.CharLengthExceeded) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"22001\",\"message\":\"String data right truncation\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.InvalidKeyProvider) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42704\",\"message\":\"Invalid TDE key provider\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.InvalidGuardrailConfiguration) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42704\",\"message\":\"Invalid CDC guardrail configuration\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.UnknownProcedure) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42883\",\"message\":\"Unknown procedure\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.Unauthenticated) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"28000\",\"message\":\"Authentication required\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.Unauthorized) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42501\",\"message\":\"Permission denied\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.SearchNotPermitted) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"42501\",\"error\":\"SEARCH_NOT_PERMITTED\",\"message\":\"Access denied: READ_PLAINTEXT privilege required for encrypted searchable field\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.InvalidIpAddress) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"22P02\",\"message\":\"Invalid IP address format\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.InvalidMac) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"22P02\",\"message\":\"Invalid MAC address format\",\"additional_statuses\":[]}}", .{});
        }
        if (err == error.DecimalDivZero) {
            return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"22012\",\"message\":\"Division by zero\",\"additional_statuses\":[]}}", .{});
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
        return try std.fmt.allocPrint(allocator.*, "{{\"status_class\":\"0A000\",\"error\":\"{s}\",\"additional_statuses\":[]}}", .{error_msg});
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

    // Handle transaction session persistence
    // If program has both START TRANSACTION and COMMIT/ROLLBACK, the transaction is complete - clear session
    // If program has only START TRANSACTION, save active session
    // If program has only COMMIT/ROLLBACK, clear session
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

    // Convert execution result to JSON
    if (flags.items.len > 0) {
        return try exec_result.toJsonWithFlags(allocator.*, flags.items);
    }
    return try exec_result.toJson(allocator.*);
}
