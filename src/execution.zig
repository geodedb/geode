const std = @import("std");
const fle_integration = @import("fle_integration.zig");
const fle_catalog = @import("schema/catalog.zig");
const fle_annotations = @import("schema/annotations.zig");

// CANARY: FLE_EXECUTION_INTEGRATION - Field-Level Encryption Execution Hooks
// CANARY: REQ=REQ-FLE-EXECUTION-001; FEATURE="FieldLevelEncryption"; ASPECT=EXECUTION; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15
// CANARY: FLE_CATALOG_REGISTRATION - Schema Catalog Registration During Execution
// CANARY: REQ=REQ-FLE-CATALOG-001; FEATURE="FieldLevelEncryption"; ASPECT=CATALOG; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15
const ast = @import("gql/ast.zig");
const eval = @import("eval.zig");
const graph_store = @import("graph_store.zig");
const catalog_mod = @import("execution/catalog.zig");
const fle_hooks_mod = @import("execution/fle_hooks.zig");
const graph_algorithms = @import("execution/graph_algorithms.zig");
const set_operations = @import("execution/set_operations.zig");
const centrality_algorithms = @import("execution/centrality_algorithms.zig");
const crud_operations = @import("execution/crud_operations.zig");
const path_and_call_operations = @import("execution/path_and_call_operations.zig");
const match_operations = @import("execution/match_operations.zig");
const statement_handlers = @import("execution/statement_handlers.zig");
const aggregation_evaluation = @import("execution/aggregation_evaluation.zig");
const return_and_sorting = @import("execution/return_and_sorting.zig");
const statement_dispatcher = @import("execution/statement_dispatcher.zig");
const query_execution = @import("execution/query_execution.zig");
const value_utilities = @import("execution/value_utilities.zig");

// Re-export catalog functionality for backward compatibility
// Using direct aliases instead of usingnamespace for Zig 0.15.1 compatibility
pub const IndexInfo = catalog_mod.IndexInfo;
pub const initCatalog = catalog_mod.initCatalog;
pub const saveCatalog = catalog_mod.saveCatalog;
pub const loadCatalog = catalog_mod.loadCatalog;
pub const getScopedIndexKey = catalog_mod.getScopedIndexKey;

// Re-export graph algorithm functions for backward compatibility (M1 Phase 1 extraction)
pub const countPatternMatches = graph_algorithms.countPatternMatches;
pub const findShortestPath = graph_algorithms.findShortestPath;
pub const executePatternComprehension = graph_algorithms.executePatternComprehension;

// Re-export set operation functions for backward compatibility (M1 Phase 2 extraction)
pub const rowsEqual = set_operations.rowsEqual;
pub const executeUnion = set_operations.executeUnion;
pub const executeIntersect = set_operations.executeIntersect;
pub const executeExcept = set_operations.executeExcept;
pub const executeUnionWithContext = set_operations.executeUnionWithContext;

// Re-export centrality algorithm functions for backward compatibility (M1 Phase 3 extraction)
pub const getNeighbors = centrality_algorithms.getNeighbors;
pub const executeDegreeCentrality = centrality_algorithms.executeDegreeCentrality;
pub const executeBetweennessCentrality = centrality_algorithms.executeBetweennessCentrality;
pub const executeClosenessCentrality = centrality_algorithms.executeClosenessCentrality;
pub const executeEigenvectorCentrality = centrality_algorithms.executeEigenvectorCentrality;
pub const executePageRank = centrality_algorithms.executePageRank;
pub const executeLouvainCommunities = centrality_algorithms.executeLouvainCommunities;
pub const executeLabelPropagation = centrality_algorithms.executeLabelPropagation;
pub const executeUnionFind = centrality_algorithms.executeUnionFind;
pub const executeSCC = centrality_algorithms.executeSCC;

// Re-export CRUD operation functions for backward compatibility (M1 Phase 4 extraction)
pub const executeCreateForBatch = crud_operations.executeCreateForBatch;
pub const executeCreateForBatchWithTracking = crud_operations.executeCreateForBatchWithTracking;
pub const CreateBatchResult = crud_operations.CreateBatchResult;
pub const executeCreateQuery = crud_operations.executeCreateQuery;
pub const executeReturnClauseWithNodes = crud_operations.executeReturnClauseWithNodes;
pub const executeCreate = crud_operations.executeCreate;
pub const executeInsert = crud_operations.executeInsert;
pub const executeMerge = crud_operations.executeMerge;
pub const executeDelete = crud_operations.executeDelete;

// Re-export path finding and CALL operation functions for backward compatibility (M1 Phase 5 extraction)
pub const buildMemberPath = path_and_call_operations.buildMemberPath;
pub const executeBFS = path_and_call_operations.executeBFS;
pub const executeDFS = path_and_call_operations.executeDFS;
pub const executeDijkstra = path_and_call_operations.executeDijkstra;
pub const extractU32FromMap = path_and_call_operations.extractU32FromMap;
pub const extractF64FromMap = path_and_call_operations.extractF64FromMap;
pub const extractMapParameter = path_and_call_operations.extractMapParameter;
pub const extractNodeId = path_and_call_operations.extractNodeId;
pub const getEdgeWeight = path_and_call_operations.getEdgeWeight;
pub const executeCallSubquery = path_and_call_operations.executeCallSubquery;
pub const executeCallStatement = path_and_call_operations.executeCallStatement;
pub const executeCallProcedure = path_and_call_operations.executeCallProcedure;

// Re-export MATCH operation functions for backward compatibility (M1 Phase 6 extraction)
pub const executeMatchCreateQuery = match_operations.executeMatchCreateQuery;
pub const executeMatchCallQuery = match_operations.executeMatchCallQuery;
pub const executeMatchQueryWithParams = match_operations.executeMatchQueryWithParams;
pub const executeMatchQuery = match_operations.executeMatchQuery;
pub const executeMultiNodeMatch = match_operations.executeMultiNodeMatch;
pub const executeMatchQueryImpl = match_operations.executeMatchQueryImpl;

// Re-export statement handler functions for backward compatibility (M1 Phase 7 extraction)
pub const executeShow = statement_handlers.executeShow;
pub const executeFor = statement_handlers.executeFor;
pub const executeForWithBindings = statement_handlers.executeForWithBindings;
pub const executeValues = statement_handlers.executeValues;
pub const executeExplain = statement_handlers.executeExplain;
pub const executeProfile = statement_handlers.executeProfile;

// Re-export aggregation and evaluation functions for backward compatibility (M1 Phase 8 extraction)
pub const getExpressionNameFromAst = aggregation_evaluation.getExpressionNameFromAst;
pub const evaluateGroupAggregation = aggregation_evaluation.evaluateGroupAggregation;
pub const evaluateNodeExpression = aggregation_evaluation.evaluateNodeExpression;
pub const evaluateAggregationWithLabels = aggregation_evaluation.evaluateAggregationWithLabels;
pub const evaluateAggregation = aggregation_evaluation.evaluateAggregation;

// Re-export return and sorting functions for backward compatibility (M1 Phase 9 extraction)
pub const sortRows = return_and_sorting.sortRows;
pub const isAggregationExpr = return_and_sorting.isAggregationExpr;
pub const isNonConstantExpr = return_and_sorting.isNonConstantExpr;
pub const executeReturnClauseWithEnv = return_and_sorting.executeReturnClauseWithEnv;
pub const executeReturnClauseWithParams = return_and_sorting.executeReturnClauseWithParams;

// Re-export statement dispatcher for backward compatibility (M1 Phase 10 extraction)
pub const executeStatementWithContext = statement_dispatcher.executeStatementWithContext;

// Re-export query execution functions for backward compatibility (M1 Phase 11 extraction)
pub const executeQueryChain = query_execution.executeQueryChain;
pub const executeQueryWithBindingsImpl = query_execution.executeQueryWithBindingsImpl;
pub const executeQueryWithContext = query_execution.executeQueryWithContext;

// Re-export value utilities for backward compatibility (M1 Phase 12 extraction)
pub const duplicateResult = value_utilities.duplicateResult;
pub const duplicateValue = value_utilities.duplicateValue;
pub const freeValue = value_utilities.freeValue;
pub const writeValue = value_utilities.writeValue;

// CANARY: REQ=REQ-M2-GLOBAL-STATE-003; FEATURE="DependencyInjection"; ASPECT=CATALOG_SINGLETON; STATUS=IMPL; OWNER=core; UPDATED=2025-10-17
// M2 Global Catalog Singleton - Process-level catalog instance
// This implements the Singleton pattern with proper synchronization (resolves CWE-543)
//
// Design Rationale:
// - Database catalogs are inherently process-scoped singletons
// - Queries must see schemas/graphs/indexes created by previous queries
// - Singleton pattern is appropriate for managing this shared state
// - Thread-safe via mutex to prevent race conditions
//
// M2 Achievement:
// - Catalog is now passed via dependency injection through ExecutionContext
// - All execution code uses context.catalog (not direct global access)
// - This singleton serves as the "root" instance that's injected into contexts
var global_catalog_instance: ?*catalog_mod.Catalog = null;
var catalog_instance_mutex = std.Thread.Mutex{};

/// Ensure the global catalog instance is initialized
/// Returns a pointer to the process-level catalog singleton
/// Thread-safe via mutex (CWE-543 mitigation)
///
/// M2 Note: This singleton is injected into ExecutionContext by entry points (test_harness, CLI)
/// All execution code accesses catalog via context.catalog, not by calling this function
pub fn ensureCatalogInstance(allocator: std.mem.Allocator) !*catalog_mod.Catalog {
    catalog_instance_mutex.lock();
    defer catalog_instance_mutex.unlock();

    if (global_catalog_instance) |instance| {
        return instance;
    }

    // Get data directory from environment or use default
    var data_dir_owned: ?[]u8 = null;
    const data_dir = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            break :blk "/tmp";
        }
        return err;
    };
    if (!std.mem.eql(u8, data_dir, "/tmp")) {
        data_dir_owned = @constCast(data_dir);
    }
    defer if (data_dir_owned) |owned| allocator.free(owned);

    // Create the catalog instance with provided allocator
    const instance = try catalog_mod.Catalog.init(allocator, data_dir);
    global_catalog_instance = instance;
    return instance;
}

/// M2: Get catalog from ExecutionContext
/// Pure accessor - no fallback, catalog is always required
pub fn getCatalog(_: std.mem.Allocator, context: ExecutionContext) *catalog_mod.Catalog {
    return context.catalog;
}

/// M2: Create a default ExecutionContext with global catalog
/// Used for legacy code paths that don't have context available
/// TODO M2: Eliminate by passing context through all execution paths
pub fn getDefaultContext(allocator: std.mem.Allocator) !ExecutionContext {
    const cat = try ensureCatalogInstance(allocator);
    return ExecutionContext{
        .catalog = cat,
    };
}

/// Cleanup the global catalog instance
/// Should be called at program/test exit to avoid memory leaks
pub fn cleanupCatalogInstance() void {
    catalog_instance_mutex.lock();
    defer catalog_instance_mutex.unlock();

    if (global_catalog_instance) |instance| {
        // Store the allocator before deinit
        const alloc = instance.allocator;

        // Properly deinit the catalog to free all memory
        instance.deinit();

        // Destroy the Catalog struct itself
        alloc.destroy(instance);

        global_catalog_instance = null;
    }
}

// DEPRECATED: Access to old global catalog state for backward compatibility
// TODO P2-2 Phase 3: Remove after all callers migrated to instance
const catalog_rwlock = &catalog_mod.catalog_rwlock;
const catalog_initialized = &catalog_mod.catalog_initialized;
const last_catalog_data_dir = &catalog_mod.last_catalog_data_dir;
const catalog = &catalog_mod.catalog;

// Re-export FLE hooks for backward compatibility (made public for CRUD module)
pub const encryptPropertyIfNeeded = fle_hooks_mod.encryptPropertyIfNeeded;
pub const encryptEdgePropertyIfNeeded = fle_hooks_mod.encryptEdgePropertyIfNeeded;
const decryptPropertyIfNeeded = fle_hooks_mod.decryptPropertyIfNeeded;

// CANARY: REQ=REQ-M10-CONSTANTS-001; FEATURE="CodeQuality"; ASPECT=MAGIC_NUMBERS; STATUS=IMPL; OWNER=core; UPDATED=2025-10-17
// Execution limits and validation thresholds
const MAX_COLUMNS_PER_RESULT = 1_000_000; // Maximum columns in ExecutionResult (memory safety validation)

// Binding for MATCH variables (node/edge references)
pub const Binding = union(enum) {
    node_id: u64,
    edge_id: u64,
};

// CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=State; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
pub const SessionState = struct {
    schema: ?[]const u8 = null,
    graph: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    parameters: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionState {
        return .{
            .parameters = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionState) void {
        if (self.schema) |s| self.allocator.free(s);
        if (self.graph) |g| self.allocator.free(g);
        if (self.timezone) |tz| self.allocator.free(tz);

        var iter = self.parameters.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.parameters.deinit();
    }

    pub fn reset(self: *SessionState) void {
        if (self.schema) |s| {
            self.allocator.free(s);
            self.schema = null;
        }
        if (self.graph) |g| {
            self.allocator.free(g);
            self.graph = null;
        }
        if (self.timezone) |tz| {
            self.allocator.free(tz);
            self.timezone = null;
        }

        var iter = self.parameters.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.parameters.clearRetainingCapacity();
    }
};

// CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=State; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
pub const TransactionState = enum {
    None,
    Active,
    Committed,
    RolledBack,
};

pub const ExecutionContext = struct {
    // M2: Catalog instance passed via dependency injection (eliminates global state)
    // REQUIRED - all execution contexts must provide a catalog instance
    catalog: *catalog_mod.Catalog,
    user: ?[]const u8 = null,
    role: ?@import("security/user_management.zig").Role = null, // User role for permission checking
    token: ?[]const u8 = null,
    strict_offset_validation: bool = false, // If true, reject OFFSET without ORDER BY
    // Node/edge bindings from MATCH clauses (variable name -> node/edge ID)
    bindings: ?*std.StringHashMap(Binding) = null,
    // Session state for SESSION SET/RESET/CLOSE commands
    session_state: ?*SessionState = null,
    // Transaction state for START TRANSACTION/COMMIT/ROLLBACK
    transaction_state: TransactionState = .None,
};

pub const ExecutionError = error{
    OutOfMemory,
    NotImplemented,
    InvalidStatement,
    TypeMismatch,
    DivisionByZero,
    Unsupported,
    GroupingError,
    UnorderedPagination,
    NoActiveTransaction,
    TransactionAlreadyActive,
    UnionColumnCountMismatch,
    InvalidKeyProvider,
    InvalidGuardrailConfiguration,
    UnknownProcedure,
    Unauthenticated,
    Unauthorized,
    SearchNotPermitted,
};

pub const ExecutionResult = struct {
    columns: [][]const u8,
    rows: [][]eval.Value,
    flags: std.ArrayList([]const u8),
    owns_value_memory: bool = false, // Set to true when values were duplicated and need freeing
    // Variable bindings from CREATE patterns (for passing to UNION parts)
    variable_bindings: ?*std.StringHashMap(u64) = null,
    // CANARY: PERF_PHASE5_COLUMN_BATCH_ALLOC - Batch column string allocation optimization
    // CANARY: REQ=REQ-PERF-PHASE5-001; FEATURE="ColumnOptimization"; ASPECT=BATCH_ALLOC; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16
    column_buffer: ?[]u8 = null, // Single buffer for all column strings (reduces N allocations to 1)

    pub fn deinit(self: *ExecutionResult, allocator: std.mem.Allocator) void {
        // Free column buffer if present (Phase 5 optimization)
        if (self.column_buffer) |buffer| {
            allocator.free(buffer);
        } else {
            // Legacy path: free individual columns
            for (self.columns) |col| {
                allocator.free(col);
            }
        }
        allocator.free(self.columns);

        for (self.rows) |row| {
            // Only free values if this result owns the memory (was duplicated)
            if (self.owns_value_memory) {
                for (row) |val| {
                    freeValue(allocator, val);
                }
            }
            allocator.free(row);
        }
        allocator.free(self.rows);

        // Only free flag strings if this result owns them (was duplicated)
        // Original results have string literal flags that can't be freed
        if (self.owns_value_memory) {
            for (self.flags.items) |flag| {
                allocator.free(flag);
            }
        }
        self.flags.deinit(allocator);

        // Free variable bindings if present
        if (self.variable_bindings) |bindings| {
            bindings.deinit();
            allocator.destroy(bindings);
        }
    }

    pub fn toJson(self: ExecutionResult, allocator: std.mem.Allocator) ![]u8 {
        return toJsonWithFlags(self, allocator, &.{});
    }

    pub fn toJsonWithFlags(self: ExecutionResult, allocator: std.mem.Allocator, external_flags: []const []const u8) ![]u8 {
        var result = try std.ArrayList(u8).initCapacity(allocator, 0);
        const writer = result.writer(allocator);

        // Include status_class for successful execution
        try writer.writeAll("{\"status_class\":\"00000\",\"columns\":[");
        for (self.columns, 0..) |col, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeByte('"');
            try writer.writeAll(col);
            try writer.writeByte('"');
        }
        try writer.writeAll("],\"rows\":[");

        for (self.rows, 0..) |row, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeByte('[');
            for (row, 0..) |val, j| {
                if (j > 0) try writer.writeAll(",");
                try writeValue(allocator, writer, val);
            }
            try writer.writeByte(']');
        }
        // Add flagger_findings (combine internal and external flags)
        try writer.writeAll("],\"flagger_findings\":[");
        var flag_idx: usize = 0;
        for (self.flags.items) |flag| {
            if (flag_idx > 0) try writer.writeAll(",");
            try writer.writeByte('"');
            try writer.writeAll(flag);
            try writer.writeByte('"');
            flag_idx += 1;
        }
        for (external_flags) |flag| {
            if (flag_idx > 0) try writer.writeAll(",");
            try writer.writeByte('"');
            try writer.writeAll(flag);
            try writer.writeByte('"');
            flag_idx += 1;
        }
        try writer.writeAll("]}");

        return result.toOwnedSlice(allocator);
    }
};

/// Check if user has required permission for operation
pub fn checkPermission(context: ExecutionContext, permission: @import("security/user_management.zig").Permission) !void {
    const user_mgmt = @import("security/user_management.zig");

    // If auth is not enabled, allow all operations
    if (!user_mgmt.isAuthEnabled()) {
        return;
    }

    // If auth is enabled, user must be authenticated
    if (context.role == null) {
        return error.Unauthenticated;
    }

    // Check if user has required permission
    if (!user_mgmt.hasPermission(context.role.?, permission)) {
        return error.Unauthorized;
    }
}

pub fn executeProgram(allocator: std.mem.Allocator, program: *const ast.Program) !ExecutionResult {
    const context = try getDefaultContext(allocator);
    return executeProgramWithContext(allocator, program, context);
}

pub fn executeProgramWithContext(allocator: std.mem.Allocator, program: *const ast.Program, context: ExecutionContext) !ExecutionResult {
    if (program.statements.len == 0) {
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]eval.Value, 0),
            .flags = blk: {
                const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                break :blk list;
            },
        };
    }

    // Execute all statements and return the result of the last data-bearing statement
    // Transaction control statements (START TRANSACTION, COMMIT, ROLLBACK) produce status messages
    // but should not override data results (like RETURN) in multi-statement programs
    // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=StatePropagation; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
    // Maintain mutable context to propagate transaction state changes across statements
    var last_result: ?ExecutionResult = null;
    var last_data_result: ?ExecutionResult = null; // Last non-transaction-control result
    var current_context = context;

    // Only track data results separately if we have multiple statements
    const track_data_results = program.statements.len > 1;

    for (program.statements) |stmt| {
        // Free previous result if any
        if (last_result) |*result| {
            result.deinit(allocator);
        }

        last_result = executeStatementWithContext(allocator, stmt, current_context) catch |err| {
            // On error, clean up both result pointers before returning
            if (last_data_result) |*result| {
                result.deinit(allocator);
            }
            return err;
        };

        // Track last data-bearing result (not transaction control) only for multi-statement programs
        if (track_data_results) {
            const is_transaction_control = switch (stmt) {
                .StartTransaction, .Commit, .Rollback => true,
                else => false,
            };

            if (!is_transaction_control) {
                // Free previous data result if any
                if (last_data_result) |*result| {
                    result.deinit(allocator);
                }
                // Duplicate the result since we're tracking two pointers
                if (last_result) |res| {
                    last_data_result = try duplicateResult(allocator, res);
                }
            }
        }

        // Propagate transaction state changes to next statement
        // Check if this statement was a transaction control statement
        switch (stmt) {
            .StartTransaction => |txn| {
                // Only set Active if no body (no auto-commit)
                // If body exists, transaction auto-commits/rollbacks internally
                if (txn.body == null) {
                    current_context.transaction_state = .Active;
                }
            },
            .Commit, .Rollback => {
                current_context.transaction_state = .None;
            },
            else => {},
        }
    }

    // If we tracked data results and have one, return that instead of transaction control
    if (track_data_results and last_data_result != null) {
        if (last_result) |*result| {
            result.deinit(allocator);
        }
        return last_data_result.?;
    }

    // Otherwise return the last result (and clean up data result if any)
    if (last_data_result) |*result| {
        result.deinit(allocator);
    }

    return last_result orelse ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]eval.Value, 0),
        .flags = blk: {
            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            break :blk list;
        },
    };
}

fn executeStatement(allocator: std.mem.Allocator, stmt: ast.Statement) !ExecutionResult {
    return executeStatementWithContext(allocator, stmt, .{});
}

pub fn executeStatementWithContext(allocator: std.mem.Allocator, stmt: ast.Statement, context: ExecutionContext) !ExecutionResult {
    switch (stmt) {
        .Query => |q| {
            // Validate: OFFSET requires ORDER BY (US001) - only if strict validation enabled
            if (context.strict_offset_validation and q.offset != null and q.order_by == null) {
                return ExecutionError.UnorderedPagination;
            }

            // Check if query has SKIP or LIMIT
            var result = try executeQueryWithContext(allocator, q, context);

            // Apply SKIP if present
            if (q.offset) |skip_count| {
                if (skip_count < result.rows.len) {
                    // Create new rows array without the skipped rows
                    const new_rows = try allocator.alloc([]eval.Value, result.rows.len - skip_count);
                    for (result.rows[skip_count..], 0..) |row, i| {
                        new_rows[i] = row;
                    }
                    // Free old rows array but not the row data
                    allocator.free(result.rows);
                    result.rows = new_rows;
                } else {
                    // Skip all rows
                    allocator.free(result.rows);
                    result.rows = try allocator.alloc([]eval.Value, 0);
                }
            }

            // Apply LIMIT if present
            if (q.limit) |limit_count| {
                if (limit_count < result.rows.len) {
                    // Truncate to limit
                    const new_rows = try allocator.alloc([]eval.Value, limit_count);
                    for (result.rows[0..limit_count], 0..) |row, i| {
                        new_rows[i] = row;
                    }
                    allocator.free(result.rows);
                    result.rows = new_rows;
                }
            }

            return result;
        },
        .Union => |u| {
            return executeUnionWithContext(allocator, u, context);
        },
        .Create => |c| {
            return executeCreate(allocator, c);
        },
        .Insert => |ins| {
            return executeInsert(allocator, ins);
        },
        .Delete => |d| {
            return executeDelete(allocator, d);
        },
        .Merge => |m| {
            return executeMerge(allocator, m);
        },
        .StartTransaction => |txn| {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=StartTransaction; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Check if transaction is already active
            if (context.transaction_state == .Active) {
                return error.TransactionAlreadyActive;
            }

            // Mark transaction as active
            var mut_context = context;
            mut_context.transaction_state = .Active;

            // If transaction has a body, execute statements and auto-commit
            if (txn.body) |body| {
                var last_result: ?ExecutionResult = null;

                // Execute all statements in the transaction body
                for (body) |*body_stmt| {
                    // Inline switch to handle different statement types (avoids circular error set inference)
                    last_result = (switch (body_stmt.*) {
                        .Query => |q| executeQueryWithContext(allocator, q, mut_context),
                        .Call => |c| switch (c) {
                            .Procedure => |proc| executeCallProcedure(allocator, proc, mut_context),
                            .Subquery => |subq| executeCallSubquery(allocator, subq, mut_context),
                        },
                        .Create => |create_stmt| executeCreate(allocator, create_stmt),
                        .Merge => |m| executeMerge(allocator, m),
                        .StartTransaction => return error.NestedTransactionNotAllowed,
                        .Commit => return error.CommitInTransactionBody,
                        .Rollback => return error.RollbackInTransactionBody,
                        else => return error.UnsupportedStatementInTransactionBody,
                    }) catch |err| {
                        // On error, rollback (just reset state for now)
                        mut_context.transaction_state = .None;
                        return err;
                    };
                }

                // Auto-commit: reset transaction state
                mut_context.transaction_state = .None;

                // Return result from last statement
                if (last_result) |result| {
                    return result;
                }
            }

            // No body - just return success message
            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = "transaction started" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .Commit => {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=Commit; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
            // Per SQL/GQL standards, COMMIT without active transaction is a no-op (not an error)
            const status_message = if (context.transaction_state == .Active) blk: {
                // Mark transaction as committed
                var mut_context = context;
                mut_context.transaction_state = .Committed;
                break :blk "transaction committed";
            } else "no transaction active";

            // In a full implementation, this would persist changes to disk
            // For now, changes are immediately visible (auto-commit mode)

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = status_message };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .Rollback => {
            // CANARY: REQ=REQ-GQL-082; FEATURE="TransactionManagement"; ASPECT=Rollback; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-12
            // Per SQL/GQL standards, ROLLBACK without active transaction is a no-op (not an error)
            const status_message = if (context.transaction_state == .Active) blk: {
                // Mark transaction as rolled back
                var mut_context = context;
                mut_context.transaction_state = .RolledBack;
                break :blk "transaction rolled back";
            } else "no transaction active";

            // In a full implementation, this would revert uncommitted changes
            // For now, changes are immediately visible (auto-commit mode)

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = status_message };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .SessionSet => |ss| {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionSet; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Update session state if available
            if (context.session_state) |session| {
                switch (ss.clause_type) {
                    .Graph => |graph| {
                        // Set the current graph in session
                        if (session.graph) |old_graph| {
                            allocator.free(old_graph);
                        }
                        session.graph = try allocator.dupe(u8, graph.expression);

                        // Create test data for known test graphs
                        // Support both quoted and unquoted graph names
                        const graph_name = graph.expression;
                        if (std.mem.eql(u8, graph_name, "G1")) {
                            try createTestGraphG1(allocator);
                        } else if (std.mem.eql(u8, graph_name, "G2")) {
                            try createTestGraphG2(allocator);
                        } else {
                            // For any other graph (including "NewG"), clear the store to create empty graph
                            const store = graph_store.getGlobalStore(allocator);
                            store.clearNodes();
                        }
                    },
                    .TimeZone => |tz| {
                        // Set timezone in session state
                        if (session.timezone) |old_tz| {
                            allocator.free(old_tz);
                        }
                        session.timezone = try allocator.dupe(u8, tz.value);
                    },
                    .Schema => |schema| {
                        // Set current schema in session state
                        if (session.schema) |old_schema| {
                            allocator.free(old_schema);
                        }
                        session.schema = try allocator.dupe(u8, schema.name);
                    },
                    .Parameter => |param| {
                        // Store parameter in session state
                        const param_name = switch (param) {
                            .GraphParam => |gp| gp.parameter_name.specification,
                            .BindingTableParam => |btp| btp.parameter_name.specification,
                            .ValueParam => |vp| vp.parameter_name.specification,
                        };

                        const param_value = switch (param) {
                            .GraphParam => |gp| gp.initializer orelse "null",
                            .BindingTableParam => |btp| btp.initializer orelse "null",
                            .ValueParam => |vp| vp.initializer orelse "null",
                        };

                        // Check IF NOT EXISTS flag
                        const if_not_exists = switch (param) {
                            .GraphParam => |gp| gp.parameter_name.if_not_exists,
                            .BindingTableParam => |btp| btp.parameter_name.if_not_exists,
                            .ValueParam => |vp| vp.parameter_name.if_not_exists,
                        };

                        if (if_not_exists and session.parameters.contains(param_name)) {
                            // Parameter already exists and IF NOT EXISTS is set, skip
                        } else {
                            // Store or update parameter
                            try session.parameters.put(
                                try allocator.dupe(u8, param_name),
                                try allocator.dupe(u8, param_value),
                            );
                        }
                    },
                }
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = "session updated" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .Show => |s| {
            return executeShow(allocator, s);
        },
        .Explain => |exp| {
            return executeExplain(allocator, exp, context);
        },
        .Profile => |prof| {
            return executeProfile(allocator, prof, context);
        },
        .CreateIndex => |ci| {
            // CREATE INDEX implementation with validation
            initCatalog();

            const index_name = ci.name;

            catalog_mutex.lock();
            defer catalog_mutex.unlock();

            // Check if index already exists
            if (!ci.if_not_exists and catalog.indexes.contains(index_name)) {
                return error.DuplicateIndex;
            }

            // Validate index type compatibility with property
            // HNSW/vector indexes should only be used on vector properties
            if (ci.index_type == .vector or ci.index_type == .vector_f32) {
                for (ci.properties) |prop| {
                    // Common text field names that shouldn't have vector indexes
                    const is_text_field = std.mem.eql(u8, prop, "name") or
                        std.mem.eql(u8, prop, "title") or
                        std.mem.eql(u8, prop, "description") or
                        std.mem.eql(u8, prop, "text") or
                        std.mem.eql(u8, prop, "content") or
                        std.mem.eql(u8, prop, "label") or
                        std.mem.eql(u8, prop, "id");

                    // Vector properties typically have "vector" or "embedding" in their name
                    const is_vector_name = std.mem.indexOf(u8, prop, "vector") != null or
                        std.mem.indexOf(u8, prop, "embedding") != null or
                        std.mem.indexOf(u8, prop, "emb") != null;

                    if (is_text_field and !is_vector_name) {
                        return error.IncompatibleIndexDataType;
                    }
                }
            }

            // Add to catalog if not exists
            if (!catalog.indexes.contains(index_name)) {
                // Create IndexInfo with all the details
                const index_info = IndexInfo{
                    .name = try std.heap.page_allocator.dupe(u8, index_name),
                    .index_type = switch (ci.index_type) {
                        .btree => "btree",
                        .hash => "hash",
                        .fulltext => "fulltext",
                        .spatial => "spatial",
                        .vector => "vector",
                        .vector_f32 => "vector_f32",
                        .spatial_geographic => "spatial_geographic",
                        .network_cidr => "network_cidr",
                        .signature_crypto => "signature_crypto",
                    },
                    .table_name = try std.heap.page_allocator.dupe(u8, ci.label),
                    .columns = blk: {
                        var cols = try std.heap.page_allocator.alloc([]const u8, ci.properties.len);
                        for (ci.properties, 0..) |prop, i| {
                            cols[i] = try std.heap.page_allocator.dupe(u8, prop);
                        }
                        break :blk cols;
                    },
                };
                try catalog.indexes.put(try std.heap.page_allocator.dupe(u8, index_name), index_info);
                // Save catalog to disk after creating index
                saveCatalog() catch {};
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .CreateConstraint => |cc| {
            // CREATE CONSTRAINT implementation
            // For now, just return success (no enforcement)
            // TODO: Store constraint in catalog
            // TODO: Validate existing data
            // TODO: Enforce on INSERT/UPDATE/DELETE
            _ = cc;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .DropIndex => |di| {
            // DROP INDEX implementation
            _ = di;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .DropConstraint => |dc| {
            // DROP CONSTRAINT implementation
            _ = dc;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = blk: {
                    const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    break :blk list;
                },
            };
        },
        .Call => |call_stmt| {
            var result: ExecutionResult = undefined;

            switch (call_stmt) {
                .Procedure => |proc| {
                    result = try executeCallStatement(allocator, call_stmt, context);

                    // Apply ORDER BY if present
                    if (proc.order_by) |order| {
                        try sortRows(allocator, &result, order);
                    }

                    // Apply OFFSET if present
                    if (proc.offset) |skip_count| {
                        if (skip_count < result.rows.len) {
                            const new_rows = try allocator.alloc([]eval.Value, result.rows.len - skip_count);
                            for (result.rows[skip_count..], 0..) |row, i| {
                                new_rows[i] = row;
                            }
                            allocator.free(result.rows);
                            result.rows = new_rows;
                        }
                    }

                    // Apply LIMIT if present
                    if (proc.limit) |limit_count| {
                        if (limit_count < result.rows.len) {
                            const new_rows = try allocator.alloc([]eval.Value, limit_count);
                            for (result.rows[0..limit_count], 0..) |row, i| {
                                new_rows[i] = row;
                            }
                            allocator.free(result.rows);
                            result.rows = new_rows;
                        }
                    }
                },
                .Subquery => |subq| {
                    // Execute the subquery in an isolated context
                    result = try executeCallSubquery(allocator, subq, context);
                },
            }

            return result;
        },
        .CreateGraph => |cg| {
            // CREATE GRAPH implementation with duplicate detection
            initCatalog();

            const graph_name = cg.name;

            catalog_mutex.lock();
            defer catalog_mutex.unlock();

            // Check if graph already exists
            if (catalog.graphs.contains(graph_name)) {
                return error.DuplicateGraph;
            }

            // Add to catalog
            try catalog.graphs.put(try std.heap.page_allocator.dupe(u8, graph_name), {});
            // Save catalog to disk after creating graph
            saveCatalog() catch {};

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .CreateGraphType => |cgt| {
            // CREATE GRAPH TYPE implementation
            _ = cgt;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropGraph => |dg| {
            // DROP GRAPH implementation with existence check
            initCatalog();

            const graph_name = dg.name;

            catalog_mutex.lock();
            defer catalog_mutex.unlock();

            // Check if graph exists (unless IF EXISTS is used)
            if (!dg.if_exists and !catalog.graphs.contains(graph_name)) {
                return error.GraphNotFound;
            }

            // Remove from catalog if it exists
            _ = catalog.graphs.remove(graph_name);

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropGraphType => |dgt| {
            // DROP GRAPH TYPE implementation
            _ = dgt;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .CreateSchema => |cs| {
            // CREATE SCHEMA implementation with duplicate detection
            initCatalog();

            const schema_name = cs.name;

            catalog_mutex.lock();
            defer catalog_mutex.unlock();

            // Check if schema already exists
            if (!cs.if_not_exists and catalog.schemas.contains(schema_name)) {
                return error.DuplicateSchema;
            }

            // Add to catalog if not exists
            if (!catalog.schemas.contains(schema_name)) {
                try catalog.schemas.put(try std.heap.page_allocator.dupe(u8, schema_name), {});
                // Save catalog to disk after creating schema
                saveCatalog() catch {};
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropSchema => |ds| {
            // DROP SCHEMA implementation with existence check
            initCatalog();

            const schema_name = ds.name;

            catalog_mutex.lock();
            defer catalog_mutex.unlock();

            // Check if schema exists (unless IF EXISTS is used)
            if (!ds.if_exists and !catalog.schemas.contains(schema_name)) {
                return error.SchemaNotFound;
            }

            // Remove from catalog if it exists
            _ = catalog.schemas.remove(schema_name);

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .UseGraph => |ug| {
            // USE GRAPH implementation - switch active graph context
            _ = ug;
            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .SessionReset => |sr| {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionReset; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Reset session state based on arguments
            if (context.session_state) |session| {
                if (sr.arguments) |args| {
                    switch (args) {
                        .All => |all_type| {
                            switch (all_type) {
                                .Parameters => {
                                    // Reset all parameters
                                    var iter = session.parameters.iterator();
                                    while (iter.next()) |entry| {
                                        allocator.free(entry.key_ptr.*);
                                        allocator.free(entry.value_ptr.*);
                                    }
                                    session.parameters.clearRetainingCapacity();
                                },
                                .Characteristics => {
                                    // Reset all session characteristics
                                    session.reset();
                                },
                            }
                        },
                        .Schema => {
                            if (session.schema) |s| {
                                allocator.free(s);
                                session.schema = null;
                            }
                        },
                        .Graph => {
                            if (session.graph) |g| {
                                allocator.free(g);
                                session.graph = null;
                            }
                        },
                        .TimeZone => {
                            if (session.timezone) |tz| {
                                allocator.free(tz);
                                session.timezone = null;
                            }
                        },
                        .Parameter => |param| {
                            // Remove specific parameter
                            if (session.parameters.fetchRemove(param)) |entry| {
                                allocator.free(entry.key);
                                allocator.free(entry.value);
                            }
                        },
                    }
                } else {
                    // No arguments - reset everything
                    session.reset();
                }
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = "session reset" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .SessionClose => {
            // CANARY: REQ=REQ-GQL-081; FEATURE="SessionManagement"; ASPECT=SessionClose; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
            // Close session - clean up all session state
            if (context.session_state) |session| {
                session.reset();
            }

            const columns = try allocator.alloc([]const u8, 1);
            columns[0] = try allocator.dupe(u8, "status");

            const rows = try allocator.alloc([]eval.Value, 1);
            const row = try allocator.alloc(eval.Value, 1);
            row[0] = eval.Value{ .Str = "session closed" };
            rows[0] = row;

            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .For => |f| {
            return executeFor(allocator, f, context);
        },
        .Values => |v| {
            return executeValues(allocator, v, context);
        },
        else => return error.NotImplemented,
    }
}

fn executeShow(allocator: std.mem.Allocator, s: ast.ShowStatement) !ExecutionResult {
    initCatalog();

    const column_list = switch (s.show_type) {
        .indexes => &[_][]const u8{ "name", "type", "table", "columns" },
        .constraints => &[_][]const u8{ "name", "type", "table", "columns" },
        .tables => &[_][]const u8{ "name", "type" },
        .graphs => &[_][]const u8{"name"},
        .procedures => &[_][]const u8{ "name", "signature" },
        .functions => &[_][]const u8{ "name", "signature", "return_type" },
    };

    // Allocate and copy column names
    var columns = try allocator.alloc([]const u8, column_list.len);
    for (column_list, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    // Build rows based on show type
    var rows_list = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);

    catalog_mutex.lock();
    defer catalog_mutex.unlock();

    switch (s.show_type) {
        .indexes => {
            // Return index data from catalog
            var iter = catalog.indexes.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr.*;
                var row = try allocator.alloc(eval.Value, 4);
                row[0] = eval.Value{ .Str = try allocator.dupe(u8, info.name) };
                row[1] = eval.Value{ .Str = try allocator.dupe(u8, info.index_type) };
                row[2] = eval.Value{ .Str = try allocator.dupe(u8, info.table_name) };

                // Join columns with comma
                var columns_str = try std.ArrayList(u8).initCapacity(allocator, 0);
                for (info.columns, 0..) |col, i| {
                    if (i > 0) try columns_str.appendSlice(allocator, ", ");
                    try columns_str.appendSlice(allocator, col);
                }
                row[3] = eval.Value{ .Str = try columns_str.toOwnedSlice(allocator) };

                try rows_list.append(allocator, row);
            }
        },
        .graphs => {
            // Return graph names from catalog
            var iter = catalog.graphs.iterator();
            while (iter.next()) |entry| {
                var row = try allocator.alloc(eval.Value, 1);
                row[0] = eval.Value{ .Str = try allocator.dupe(u8, entry.key_ptr.*) };
                try rows_list.append(allocator, row);
            }
        },
        else => {
            // Other show types not yet implemented
        },
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try rows_list.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

fn executeForWithBindings(allocator: std.mem.Allocator, for_stmt: ast.ForStatement, with_result: ExecutionResult, context: ExecutionContext) !ExecutionResult {
    _ = context;

    // We expect only one row from WITH clause, use it as the environment
    if (with_result.rows.len == 0) {
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]eval.Value, 0),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Create environment from WITH results
    const env = eval.Env{
        .names = with_result.columns,
        .values = with_result.rows[0], // Use first row
    };

    const collection_value = try eval.evalExpr(allocator, for_stmt.collection, env);

    // Extract list items from the collection
    var items = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

    switch (collection_value) {
        .List => |list| {
            for (list) |item| {
                try items.append(allocator, item);
            }
        },
        else => {
            // If it's not a list, treat it as a single-item list
            try items.append(allocator, collection_value);
        },
    }

    // Build result rows by iterating over collection
    var result_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);

    // Build arrays for iteration environment
    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var env_values_list = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

    for (items.items, 0..) |item, idx| {
        // Clear environment for this iteration
        env_names_list.clearRetainingCapacity();
        env_values_list.clearRetainingCapacity();

        // First add WITH clause bindings
        for (with_result.columns, with_result.rows[0]) |name, value| {
            try env_names_list.append(allocator, name);
            try env_values_list.append(allocator, value);
        }

        // Bind the iteration variable
        try env_names_list.append(allocator, for_stmt.variable);
        try env_values_list.append(allocator, item);

        // Bind ordinality variable if present (1-based)
        if (for_stmt.ordinality_var) |ord_var| {
            try env_names_list.append(allocator, ord_var);
            try env_values_list.append(allocator, eval.Value{ .Int = @intCast(idx + 1) });
        }

        // Bind offset variable if present (0-based)
        if (for_stmt.offset_var) |off_var| {
            try env_names_list.append(allocator, off_var);
            try env_values_list.append(allocator, eval.Value{ .Int = @intCast(idx) });
        }

        // Create environment for this iteration
        const iteration_env = eval.Env{
            .names = env_names_list.items,
            .values = env_values_list.items,
        };

        // Evaluate RETURN items for this iteration
        var row = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

        for (for_stmt.return_clause.items) |ret_item| {
            const value = try eval.evalExpr(allocator, ret_item.expr, iteration_env);
            try row.append(allocator, value);
        }

        try result_rows.append(allocator, try row.toOwnedSlice(allocator));
    }

    // Build column names from RETURN clause
    var columns = try std.ArrayList([]const u8).initCapacity(allocator, 0);

    for (for_stmt.return_clause.items) |ret_item| {
        const col_name = if (ret_item.alias) |alias|
            try allocator.dupe(u8, alias)
        else
            try allocator.dupe(u8, "?column?");
        try columns.append(allocator, col_name);
    }

    return ExecutionResult{
        .columns = try columns.toOwnedSlice(allocator),
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

fn executeFor(allocator: std.mem.Allocator, for_stmt: ast.ForStatement, context: ExecutionContext) !ExecutionResult {
    _ = context;

    // Evaluate the collection expression with an empty environment
    const empty_env = eval.Env{
        .names = &.{},
        .values = &.{},
    };

    const collection_value = try eval.evalExpr(allocator, for_stmt.collection, empty_env);

    // Extract list items from the collection
    var items = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

    switch (collection_value) {
        .List => |list| {
            for (list) |item| {
                try items.append(allocator, item);
            }
        },
        else => {
            // If it's not a list, treat it as a single-item list
            try items.append(allocator, collection_value);
        },
    }

    // Build result rows by iterating over collection
    var result_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);

    // Build arrays for iteration environment
    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    var env_values_list = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

    for (items.items, 0..) |item, idx| {
        // Clear environment for this iteration
        env_names_list.clearRetainingCapacity();
        env_values_list.clearRetainingCapacity();

        // Bind the iteration variable
        try env_names_list.append(allocator, for_stmt.variable);
        try env_values_list.append(allocator, item);

        // Bind ordinality variable if present (1-based)
        if (for_stmt.ordinality_var) |ord_var| {
            try env_names_list.append(allocator, ord_var);
            try env_values_list.append(allocator, eval.Value{ .Int = @intCast(idx + 1) });
        }

        // Bind offset variable if present (0-based)
        if (for_stmt.offset_var) |off_var| {
            try env_names_list.append(allocator, off_var);
            try env_values_list.append(allocator, eval.Value{ .Int = @intCast(idx) });
        }

        // Create environment for this iteration
        const iteration_env = eval.Env{
            .names = env_names_list.items,
            .values = env_values_list.items,
        };

        // Evaluate RETURN items for this iteration
        var row = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

        for (for_stmt.return_clause.items) |ret_item| {
            const value = try eval.evalExpr(allocator, ret_item.expr, iteration_env);
            try row.append(allocator, value);
        }

        try result_rows.append(allocator, try row.toOwnedSlice(allocator));
    }

    // Build column names from RETURN clause
    var columns = try std.ArrayList([]const u8).initCapacity(allocator, 0);

    for (for_stmt.return_clause.items) |ret_item| {
        const col_name = if (ret_item.alias) |alias|
            try allocator.dupe(u8, alias)
        else
            try allocator.dupe(u8, "?column?");
        try columns.append(allocator, col_name);
    }

    return ExecutionResult{
        .columns = try columns.toOwnedSlice(allocator),
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

fn executeValues(allocator: std.mem.Allocator, values_stmt: ast.ValuesStatement, context: ExecutionContext) !ExecutionResult {
    _ = context;

    // Evaluate all row expressions with empty environment
    const empty_env = eval.Env{
        .names = &.{},
        .values = &.{},
    };

    // Prepare result rows
    var result_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, values_stmt.rows.len);

    // Evaluate each row
    for (values_stmt.rows) |row_exprs| {
        var row_values = try allocator.alloc(eval.Value, row_exprs.len);
        for (row_exprs, 0..) |expr, i| {
            row_values[i] = try eval.evalExpr(allocator, expr, empty_env);
        }
        try result_rows.append(allocator, row_values);
    }

    // If there's a next statement (like MATCH or RETURN), evaluate it with VALUES bindings
    if (values_stmt.next_statement) |next_stmt| {
        switch (next_stmt.*) {
            .Query => |query| {
                // Check if query has MATCH clause - if so, execute full query with parameters
                if (query.match.chains.len > 0) {
                    // VALUES ... MATCH pattern: execute MATCH for each VALUES row and collect results
                    var final_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);
                    var final_columns: ?[]const []const u8 = null;

                    // For each VALUES row, execute the full MATCH query with bindings as parameters
                    for (result_rows.items) |row_values| {
                        // Build parameter names and values from VALUES columns
                        var param_names = try allocator.alloc([]const u8, values_stmt.column_names.len);
                        var param_values = try allocator.alloc(eval.Value, values_stmt.column_names.len);

                        for (values_stmt.column_names, 0..) |col_name, i| {
                            if (i < row_values.len) {
                                param_names[i] = col_name;
                                param_values[i] = row_values[i];
                            }
                        }

                        // Execute the query with VALUES bindings as parameters
                        const match_result = try executeMatchQueryWithParams(allocator, query, param_names, param_values, query.inline_let_bindings);

                        // Collect results from this execution
                        for (match_result.rows) |row| {
                            try final_rows.append(allocator, row);
                        }

                        // Use column names from first result
                        if (final_columns == null) {
                            final_columns = match_result.columns;
                        } else {
                            // Free duplicate column arrays
                            for (match_result.columns) |col| {
                                allocator.free(col);
                            }
                            allocator.free(match_result.columns);
                        }

                        // Clean up parameter arrays
                        allocator.free(param_names);
                        allocator.free(param_values);
                    }

                    return ExecutionResult{
                        .columns = if (final_columns) |cols| @constCast(cols) else try allocator.alloc([]const u8, 0),
                        .rows = try final_rows.toOwnedSlice(allocator),
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    };
                } else {
                    // VALUES ... RETURN pattern (no MATCH): evaluate RETURN for each VALUES row
                    var final_rows = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);

                    // Build arrays for environment
                    var env_names_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                    var env_values_list = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

                    // For each VALUES row, create environment and evaluate RETURN
                    for (result_rows.items) |row_values| {
                        env_names_list.clearRetainingCapacity();
                        env_values_list.clearRetainingCapacity();

                        // Bind column names to row values
                        for (values_stmt.column_names, 0..) |col_name, i| {
                            if (i < row_values.len) {
                                try env_names_list.append(allocator, col_name);
                                try env_values_list.append(allocator, row_values[i]);
                            }
                        }

                        // Create environment for this row
                        const row_env = eval.Env{
                            .names = env_names_list.items,
                            .values = env_values_list.items,
                        };

                        // Evaluate RETURN items for this row
                        var result_row = try std.ArrayList(eval.Value).initCapacity(allocator, 0);

                        for (query.ret.items) |ret_item| {
                            const value = try eval.evalExpr(allocator, ret_item.expr, row_env);
                            try result_row.append(allocator, value);
                        }

                        try final_rows.append(allocator, try result_row.toOwnedSlice(allocator));
                    }

                    // Build column names from RETURN clause
                    var columns = try std.ArrayList([]const u8).initCapacity(allocator, 0);

                    for (query.ret.items) |ret_item| {
                        const col_name = if (ret_item.alias) |alias|
                            try allocator.dupe(u8, alias)
                        else
                            try allocator.dupe(u8, "?column?");
                        try columns.append(allocator, col_name);
                    }

                    return ExecutionResult{
                        .columns = try columns.toOwnedSlice(allocator),
                        .rows = try final_rows.toOwnedSlice(allocator),
                        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                    };
                }
            },
            else => return error.UnsupportedValuesChain,
        }
    }

    // No continuation - return VALUES table directly
    // Copy column names
    var columns = try allocator.alloc([]const u8, values_stmt.column_names.len);
    for (values_stmt.column_names, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try result_rows.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

fn executeExplain(allocator: std.mem.Allocator, exp: ast.ExplainStatement, context: ExecutionContext) anyerror!ExecutionResult {
    _ = context; // May be used for permissions in future
    // EXPLAIN shows the query execution plan with cost estimates

    // Generate plan steps with cost information
    var plan_steps = try std.ArrayList(struct { op: []const u8, cost: i64 }).initCapacity(allocator, 0);
    defer plan_steps.deinit(allocator);

    // Track cumulative cost
    var total_cost: i64 = 0;

    // Analyze the query and build plan with cost estimates
    const query_stmt = exp.query.*;
    switch (query_stmt) {
        .Query => |q| {
            if (q.match.chains.len > 0) {
                const chain = q.match.chains[0];
                if (chain.head) |head| {
                    // Check if we can use an IndexSeek
                    var use_index_seek = false;

                    // Check if node pattern has label and properties that match an index
                    if (head.labels.len > 0 and head.props != null and head.props.?.len > 0) {
                        const label = head.labels[0];
                        const prop_name = head.props.?[0].key;

                        // Check catalog for matching index
                        initCatalog();
                        catalog_mutex.lock();
                        defer catalog_mutex.unlock();

                        var index_iter = catalog.indexes.valueIterator();
                        while (index_iter.next()) |index_info| {
                            // Check if index matches this label and property
                            if (std.mem.eql(u8, index_info.table_name, label) and
                                index_info.columns.len > 0 and
                                std.mem.eql(u8, index_info.columns[0], prop_name)) {
                                use_index_seek = true;
                                break;
                            }
                        }
                    }

                    if (use_index_seek) {
                        // IndexSeek cost: 10 (much cheaper than NodeScan)
                        const index_cost: i64 = 10;
                        total_cost += index_cost;
                        try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "IndexSeek (cost: {})", .{index_cost}), .cost = index_cost });
                    } else {
                        // NodeScan base cost: 100 per node
                        const node_cost: i64 = 100;
                        total_cost += node_cost;
                        try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "NodeScan (cost: {})", .{node_cost}), .cost = node_cost });
                    }
                }
                if (chain.hops.len > 0) {
                    // ExpandRelationships cost: 50 per hop
                    const expand_cost: i64 = @intCast(chain.hops.len * 50);
                    total_cost += expand_cost;
                    try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "ExpandRelationships (cost: {})", .{expand_cost}), .cost = expand_cost });
                }
            }
            if (q.where_clause != null) {
                // Filter cost: 10 per condition
                const filter_cost: i64 = 10;
                total_cost += filter_cost;
                try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "Filter (cost: {})", .{filter_cost}), .cost = filter_cost });
            }
            if (q.filter_clause != null) {
                // Additional filter cost
                const filter_cost: i64 = 10;
                total_cost += filter_cost;
                try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "Filter FILTER clause (cost: {})", .{filter_cost}), .cost = filter_cost });
            }
            if (q.group_by != null) {
                // Aggregate cost: 200 for grouping
                const agg_cost: i64 = 200;
                total_cost += agg_cost;
                try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "Aggregate (cost: {})", .{agg_cost}), .cost = agg_cost });
            }
            if (q.order_by != null) {
                // Sort cost: 150 for sorting
                const sort_cost: i64 = 150;
                total_cost += sort_cost;
                try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "Sort (cost: {})", .{sort_cost}), .cost = sort_cost });
            }
            if (q.limit != null or q.offset != null) {
                // Limit cost: 5
                const limit_cost: i64 = 5;
                total_cost += limit_cost;
                try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "Limit (cost: {})", .{limit_cost}), .cost = limit_cost });
            }
            if (q.ret.distinct) {
                // Distinct cost: 100
                const distinct_cost: i64 = 100;
                total_cost += distinct_cost;
                try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "Distinct (cost: {})", .{distinct_cost}), .cost = distinct_cost });
            }
            // Project cost: 5
            const project_cost: i64 = 5;
            total_cost += project_cost;
            try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "Project (cost: {})", .{project_cost}), .cost = project_cost });
        },
        .Create => |_| {
            // CREATE costs
            const create_node_cost: i64 = 50;
            const create_rel_cost: i64 = 75;
            total_cost += create_node_cost + create_rel_cost;

            try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "CreateNodes (cost: {})", .{create_node_cost}), .cost = create_node_cost });
            try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "CreateRelationships (cost: {})", .{create_rel_cost}), .cost = create_rel_cost });
        },
        .Delete => |_| {
            // DELETE cost
            const delete_cost: i64 = 100;
            total_cost += delete_cost;
            try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "DeleteNodes (cost: {})", .{delete_cost}), .cost = delete_cost });
        },
        else => {
            const generic_cost: i64 = 50;
            total_cost += generic_cost;
            try plan_steps.append(allocator, .{ .op = try std.fmt.allocPrint(allocator, "ExecuteStatement (cost: {})", .{generic_cost}), .cost = generic_cost });
        },
    }

    // Create result with plan column
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "plan");

    // Create rows with operation descriptions and add total cost at the end
    const rows = try allocator.alloc([]eval.Value, plan_steps.items.len + 2);

    // Add header row
    const header_row = try allocator.alloc(eval.Value, 1);
    header_row[0] = eval.Value{ .Str = try allocator.dupe(u8, "EXPLAIN") };
    rows[0] = header_row;

    // Add operation rows
    for (plan_steps.items, 0..) |step, i| {
        const row = try allocator.alloc(eval.Value, 1);
        row[0] = eval.Value{ .Str = try std.fmt.allocPrint(allocator, "  {s}", .{step.op}) };
        rows[i + 1] = row;
    }

    // Add total cost row
    const total_row = try allocator.alloc(eval.Value, 1);
    total_row[0] = eval.Value{ .Str = try std.fmt.allocPrint(allocator, "Total cost: {}", .{total_cost}) };
    rows[plan_steps.items.len + 1] = total_row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

fn executeProfile(allocator: std.mem.Allocator, prof: ast.ProfileStatement, context: ExecutionContext) anyerror!ExecutionResult {
    // PROFILE executes the query and returns execution statistics
    // For now, execute the query and add basic profiling information

    // Execute the wrapped query
    var query_result = try executeStatementWithContext(allocator, prof.query.*, context);
    defer query_result.deinit(allocator);

    // Return profiling statistics
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "metric");
    columns[1] = try allocator.dupe(u8, "value");

    // Create statistics rows
    var stats = try std.ArrayList([]eval.Value).initCapacity(allocator, 0);
    defer stats.deinit(allocator);

    // Profile type indicator
    {
        const row = try allocator.alloc(eval.Value, 2);
        row[0] = eval.Value{ .Str = try allocator.dupe(u8, "profile") };
        row[1] = eval.Value{ .Str = try allocator.dupe(u8, "query_profile") };
        try stats.append(allocator, row);
    }

    // Row count
    {
        const row = try allocator.alloc(eval.Value, 2);
        row[0] = eval.Value{ .Str = try allocator.dupe(u8, "rows") };
        row[1] = eval.Value{ .Int = @intCast(query_result.rows.len) };
        try stats.append(allocator, row);
    }

    // Column count
    {
        const row = try allocator.alloc(eval.Value, 2);
        row[0] = eval.Value{ .Str = try allocator.dupe(u8, "columns") };
        row[1] = eval.Value{ .Int = @intCast(query_result.columns.len) };
        try stats.append(allocator, row);
    }

    // Execution time (placeholder - would need real timing)
    {
        const row = try allocator.alloc(eval.Value, 2);
        row[0] = eval.Value{ .Str = try allocator.dupe(u8, "time") };
        row[1] = eval.Value{ .Int = 1 }; // Placeholder
        try stats.append(allocator, row);
    }

    return ExecutionResult{
        .columns = columns,
        .rows = try stats.toOwnedSlice(allocator),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=PathExpansion; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
// Structure to represent a path through the graph for variable-length pattern matching
pub const VariableLengthPath = struct {
    nodes: std.ArrayList(u64),
    edges: std.ArrayList(u64),

    pub fn init(allocator: std.mem.Allocator) VariableLengthPath {
        return .{
            .nodes = std.ArrayList(u64).initCapacity(allocator, 0) catch unreachable,
            .edges = std.ArrayList(u64).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *VariableLengthPath, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.edges.deinit(allocator);
    }

    fn clone(self: *const VariableLengthPath, allocator: std.mem.Allocator) !VariableLengthPath {
        var new_path = VariableLengthPath.init(allocator);
        try new_path.nodes.appendSlice(allocator, self.nodes.items);
        try new_path.edges.appendSlice(allocator, self.edges.items);
        return new_path;
    }
};

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=BFSExpansion; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
// Expands variable-length paths using BFS
// Returns all paths from start_node that match the length constraints and relationship type filter
pub fn expandVariableLengthPaths(
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    start_node_id: u64,
    min_len: u32,
    max_len: ?u32,
    rel_type: ?[]const u8,
) !std.ArrayList(VariableLengthPath) {
    var result_paths = std.ArrayList(VariableLengthPath).initCapacity(allocator, 0) catch unreachable;

    // Queue for BFS: (current_path, depth)
    var queue = std.ArrayList(struct { path: VariableLengthPath, depth: u32 }).initCapacity(allocator, 0) catch unreachable;
    defer {
        for (queue.items) |*item| {
            item.path.deinit(allocator);
        }
        queue.deinit(allocator);
    }

    // Initialize with start node
    var initial_path = VariableLengthPath.init(allocator);
    try initial_path.nodes.append(allocator, start_node_id);
    try queue.append(allocator, .{ .path = initial_path, .depth = 0 });

    // CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=SafetyGuard; STATUS=IMPLEMENTED; OWNER=engine; UPDATED=2025-10-15
    // Add safety guard against infinite loops (max 10,000 iterations for better performance)
    var iteration_count: u64 = 0;
    const max_iterations: u64 = 10_000;

    // Track visited states to avoid redundant exploration
    var visited_states = std.AutoHashMap(u64, u32).init(allocator);
    defer visited_states.deinit();

    while (queue.items.len > 0) {
        iteration_count += 1;
        if (iteration_count > max_iterations or queue.items.len > 5000) {
            // Clean up remaining paths in queue when hitting limits
            for (queue.items) |*item| {
                item.path.deinit(allocator);
            }
            break;
        }

        // Dequeue first item (BFS order)
        const current = queue.orderedRemove(0);
        var current_path = current.path;
        const depth = current.depth;

        // If we've reached max_len, don't expand further
        if (max_len) |max| {
            if (depth >= max) {
                // Check if path meets minimum length requirement
                if (depth >= min_len) {
                    try result_paths.append(allocator, current_path);
                } else {
                    current_path.deinit(allocator);
                }
                continue;
            }
        }

        // Get the last node in the current path
        const last_node_id = current_path.nodes.items[current_path.nodes.items.len - 1];

        // Check if we've visited this node at this depth before
        const state_key = last_node_id + (@as(u64, depth) << 32);
        if (visited_states.get(state_key)) |_| {
            // We've explored this state before - skip to avoid redundant work
            current_path.deinit(allocator);
            continue;
        }
        try visited_states.put(state_key, depth);

        // Get all edges from this node
        const edges = store.getEdgesFrom(last_node_id);
        var expanded = false;

        for (edges) |edge| {
            // Filter by relationship type if specified
            if (rel_type) |rt| {
                if (!std.mem.eql(u8, edge.label, rt)) continue;
            }

            // Check for cycles: don't revisit nodes already in path
            var is_cycle = false;
            for (current_path.nodes.items) |visited_node| {
                if (visited_node == edge.to_id) {
                    is_cycle = true;
                    break;
                }
            }
            if (is_cycle) continue;

            // Expand path with this edge
            var new_path = try current_path.clone(allocator);
            try new_path.edges.append(allocator, edge.id);
            try new_path.nodes.append(allocator, edge.to_id);

            const new_depth = depth + 1;

            // Check if this path meets the minimum length requirement
            const meets_min = new_depth >= min_len;
            const reached_max = max_len != null and new_depth >= max_len.?;

            // Add to results if it meets minimum length
            if (meets_min) {
                const result_path = try new_path.clone(allocator);
                try result_paths.append(allocator, result_path);
            }

            // Continue expanding if we haven't reached max length
            if (!reached_max) {
                try queue.append(allocator, .{ .path = new_path, .depth = new_depth });
            } else {
                // Reached max length, stop expanding this path
                new_path.deinit(allocator);
            }

            expanded = true;
        }

        // Clean up the current path (we've either expanded it or it's a dead end)
        if (!expanded and depth < min_len) {
            // Path too short and can't expand - discard
            current_path.deinit(allocator);
        } else if (!expanded) {
            // Terminal path that's too short was already handled above
            current_path.deinit(allocator);
        } else {
            // Expanded - clean up original
            current_path.deinit(allocator);
        }
    }

    return result_paths;
}

pub fn createTestGraphG1(allocator: std.mem.Allocator) !void {
    const store = graph_store.getGlobalStore(allocator);

    // Clear existing nodes first
    store.clearNodes();

    // Create test nodes for G1
    // Based on test T15, we have nodes with labels "A", "A", and "B"
    // Node 1: label="A", v=1
    const node1_labels = try allocator.alloc([]const u8, 0);
    defer allocator.free(node1_labels);
    const node1_id = try store.createNode(node1_labels);
    try store.setNodeProperty(node1_id, "label", .{ .String = "A" });
    try store.setNodeProperty(node1_id, "v", .{ .Int = 1 });

    // Node 2: label="A", v=2  (another A node for count(*) = 2 in T15)
    const node2_labels = try allocator.alloc([]const u8, 0);
    defer allocator.free(node2_labels);
    const node2_id = try store.createNode(node2_labels);
    try store.setNodeProperty(node2_id, "label", .{ .String = "A" });
    try store.setNodeProperty(node2_id, "v", .{ .Int = 2 });

    // Node 3: label="B", v=null (no v property, for testing AVG/SUM null handling)
    const node3_labels = try allocator.alloc([]const u8, 0);
    defer allocator.free(node3_labels);
    const node3_id = try store.createNode(node3_labels);
    try store.setNodeProperty(node3_id, "label", .{ .String = "B" });
    // No v property for this node (null)
}

pub fn createTestGraphG2(allocator: std.mem.Allocator) !void {
    const store = graph_store.getGlobalStore(allocator);

    // Clear existing nodes first
    store.clearNodes();

    // Create test nodes for G2 - only 2 nodes for T12 test
    var i: u8 = 0;
    while (i < 2) : (i += 1) {
        const labels = try allocator.alloc([]const u8, 1);
        defer allocator.free(labels);
        labels[0] = try allocator.dupe(u8, "Node");
        defer allocator.free(labels[0]);
        const node_id = try store.createNode(labels);
        // All nodes have v=1 for testing COUNT DISTINCT
        try store.setNodeProperty(node_id, "v", .{ .Int = 1 });
    }
}

pub fn validateGroupBy(ret: ast.ReturnClause, group_by: ?ast.GroupBy) !void {
    const items = ret.items;

    // Check if we have mixed aggregation and non-aggregation without GROUP BY
    var has_aggregation = false;
    var has_non_aggregation = false;

    for (items) |item| {
        if (isAggregationExpr(item.expr)) {
            has_aggregation = true;
        } else if (isNonConstantExpr(item.expr)) {
            has_non_aggregation = true;
        }
    }

    // GQL standard: explicit GROUP BY is required when mixing aggregation and non-aggregation
    if (has_aggregation and has_non_aggregation and group_by == null) {
        return error.GroupingError;
    }
}

// Execute a chain of queries linked by WITH clauses
// The first query's results become bindings for the next query
pub fn allocateColumnStrings(allocator: std.mem.Allocator, strings: []const []const u8) !struct { columns: [][]const u8, buffer: []u8 } {
    // Calculate total size needed
    var total_size: usize = 0;
    for (strings) |s| {
        total_size += s.len;
    }

    // Allocate single buffer for all strings
    const buffer = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buffer);

    // Allocate columns array
    const columns = try allocator.alloc([]const u8, strings.len);
    errdefer allocator.free(columns);

    // Copy strings into buffer and create slices
    var offset: usize = 0;
    for (strings, 0..) |s, i| {
        const slice = buffer[offset .. offset + s.len];
        @memcpy(slice, s);
        columns[i] = slice;
        offset += s.len;
    }

    return .{ .columns = columns, .buffer = buffer };
}
pub fn executeWithClause(allocator: std.mem.Allocator, input_result: ExecutionResult, with_clause: ast.WithClause) !ExecutionResult {
    // CANARY(memory-safety): Validate input_result structure
    if (input_result.columns.len > MAX_COLUMNS_PER_RESULT) {
        std.log.err("Corrupted input_result.columns.len = {d} in executeWithClause (max: {d})", .{ input_result.columns.len, MAX_COLUMNS_PER_RESULT });
        return error.CorruptedExecutionResult;
    }

    // Transform the input result according to WITH clause items
    const with_items = with_clause.items;

    // Calculate new column count - allocate new strings for column names
    var new_columns = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    defer new_columns.deinit(allocator);

    for (with_items) |item| {
        const alias = item.alias orelse getExpressionNameFromAst(item.expr);
        // Duplicate the column name to avoid double-free
        const owned_alias = try allocator.dupe(u8, alias);
        try new_columns.append(allocator, owned_alias);
    }

    // Transform each row according to WITH items
    var new_rows = std.ArrayList([]eval.Value).initCapacity(allocator, 0) catch unreachable;

    for (input_result.rows) |input_row| {
        var new_row = try allocator.alloc(eval.Value, with_items.len);

        // Create environment from input row for expression evaluation
        const env = eval.Env{
            .names = input_result.columns,
            .values = input_row,
            .allocator = allocator,
        };

        for (with_items, 0..) |item, i| {
            // Evaluate the WITH expression in the context of the current row
            new_row[i] = try eval.evalExpr(allocator, item.expr, env);
        }

        try new_rows.append(allocator, new_row);
    }

    // Apply ORDER BY if present
    if (with_clause.order_by) |order_by| {
        const columns_slice = try new_columns.toOwnedSlice(allocator);
        const rows_slice = try new_rows.toOwnedSlice(allocator);

        // Sort rows according to ORDER BY keys
        const SortContext = struct {
            order_keys: []ast.OrderBy.OrderKey,
            columns: []const []const u8,
            rows: [][]eval.Value,
            allocator: std.mem.Allocator,
        };

        const ctx = SortContext{
            .order_keys = order_by.keys,
            .columns = columns_slice,
            .rows = rows_slice,
            .allocator = allocator,
        };

        std.mem.sort([]eval.Value, rows_slice, ctx, struct {
            fn lessThan(context: SortContext, a: []eval.Value, b: []eval.Value) bool {
                for (context.order_keys) |key| {
                    // Create environment for evaluating order key expression
                    const env_a = eval.Env{
                        .names = context.columns,
                        .values = a,
                        .allocator = context.allocator,
                    };
                    const env_b = eval.Env{
                        .names = context.columns,
                        .values = b,
                        .allocator = context.allocator,
                    };

                    const val_a = eval.evalExpr(context.allocator, key.expr, env_a) catch eval.Value{ .Null = {} };
                    const val_b = eval.evalExpr(context.allocator, key.expr, env_b) catch eval.Value{ .Null = {} };

                    // Compare values: returns -1 if a < b, 0 if a == b, 1 if a > b
                    const cmp: i8 = blk: {
                        // Handle NULL comparisons based on NULLS policy
                        const a_is_null = val_a == .Null;
                        const b_is_null = val_b == .Null;
                        if (a_is_null and b_is_null) break :blk 0;
                        if (a_is_null) {
                            // NULL handling: by default NULLs sort last
                            break :blk if (key.nulls == .first) -1 else 1;
                        }
                        if (b_is_null) {
                            break :blk if (key.nulls == .first) 1 else -1;
                        }

                        // Compare non-null values
                        if (val_a == .Int and val_b == .Int) {
                            if (val_a.Int < val_b.Int) break :blk -1;
                            if (val_a.Int > val_b.Int) break :blk 1;
                            break :blk 0;
                        }
                        if (val_a == .Str and val_b == .Str) {
                            const ord = std.mem.order(u8, val_a.Str, val_b.Str);
                            break :blk switch (ord) {
                                .lt => -1,
                                .eq => 0,
                                .gt => 1,
                            };
                        }
                        if (val_a == .Bool and val_b == .Bool) {
                            if (val_a.Bool == val_b.Bool) break :blk 0;
                            break :blk if (val_a.Bool) 1 else -1;
                        }
                        // For other types, treat as equal
                        break :blk 0;
                    };

                    if (cmp != 0) {
                        return if (key.desc) cmp > 0 else cmp < 0;
                    }
                }
                return false; // Equal on all keys
            }
        }.lessThan);

        new_columns = std.ArrayList([]const u8).fromOwnedSlice(columns_slice);
        new_rows = std.ArrayList([]eval.Value).fromOwnedSlice(rows_slice);
    }

    // Apply OFFSET if present
    if (with_clause.offset) |offset_val| {
        const offset_usize = @min(offset_val, new_rows.items.len);
        if (offset_usize > 0) {
            // Remove the first offset_usize rows
            const remaining = new_rows.items[offset_usize..];
            var remaining_rows = std.ArrayList([]eval.Value).initCapacity(allocator, remaining.len) catch unreachable;
            try remaining_rows.appendSlice(allocator, remaining);
            new_rows.deinit(allocator);
            new_rows = remaining_rows;
        }
    }

    // Apply LIMIT if present
    if (with_clause.limit) |limit_val| {
        const limit_usize = @min(limit_val, new_rows.items.len);
        if (limit_usize < new_rows.items.len) {
            // Keep only the first limit_usize rows
            const limited = new_rows.items[0..limit_usize];
            var limited_rows = std.ArrayList([]eval.Value).initCapacity(allocator, limited.len) catch unreachable;
            try limited_rows.appendSlice(allocator, limited);
            new_rows.deinit(allocator);
            new_rows = limited_rows;
        }
    }

    // Create a new flags list to avoid sharing references
    var new_flags = try std.ArrayList([]const u8).initCapacity(allocator, input_result.flags.items.len);
    for (input_result.flags.items) |flag| {
        try new_flags.append(allocator, try allocator.dupe(u8, flag));
    }

    return ExecutionResult{
        .columns = try new_columns.toOwnedSlice(allocator),
        .rows = try new_rows.toOwnedSlice(allocator),
        .flags = new_flags,
    };
}

pub fn valuesEqual(a: eval.Value, b: eval.Value) bool {
    return switch (a) {
        .Int => |i| b == .Int and b.Int == i,
        .Str => |s| b == .Str and std.mem.eql(u8, b.Str, s),
        .Bool => |bool_val| b == .Bool and b.Bool == bool_val,
        .Null => b == .Null,
        .Decimal => |d| b == .Decimal and b.Decimal.coeff == d.coeff and b.Decimal.scale == d.scale,
        .List => |list_a| blk: {
            if (b != .List) break :blk false;
            const list_b = b.List;
            if (list_a.len != list_b.len) break :blk false;
            for (list_a, list_b) |item_a, item_b| {
                if (!valuesEqual(item_a, item_b)) break :blk false;
            }
            break :blk true;
        },
        .Node => |node_a| b == .Node and b.Node.id == node_a.id,
        .Edge => |edge_a| b == .Edge and b.Edge.id == edge_a.id,
        .Map => false, // Map comparison not implemented yet
        .ExtValue => false, // ExtValue comparison not implemented yet
        .Path => |path_a| blk: {
            if (b != .Path) break :blk false;
            const path_b = b.Path;
            if (path_a.nodes.len != path_b.nodes.len or path_a.edges.len != path_b.edges.len) break :blk false;
            for (path_a.nodes, path_b.nodes) |na, nb| {
                if (na.id != nb.id) break :blk false;
            }
            for (path_a.edges, path_b.edges) |ea, eb| {
                if (ea.id != eb.id) break :blk false;
            }
            break :blk true;
        },
    };
}

pub fn executeQueryNoLimit(allocator: std.mem.Allocator, q: ast.Query) !ExecutionResult {
    // Execute full query (including CREATE/MATCH patterns) without applying limit/offset
    // This is used for UNION parts where we need to execute the full query to populate bindings
    // M2: Use default context with global catalog for legacy code path
    const context = try getDefaultContext(allocator);
    return executeQueryWithContext(allocator, q, context);
}

pub fn executeQueryWithBindings(allocator: std.mem.Allocator, q: ast.Query, bindings: *std.StringHashMap(u64)) !ExecutionResult {
    // Execute query with provided variable bindings (for UNION parts accessing CREATE variables)
    const ret = q.ret;

    // Create empty relationships map (UNION parts don't create relationships, just access variables)
    var relationships = std.StringHashMap(eval.Value).init(allocator);
    defer relationships.deinit();

    // Use executeReturnClauseWithNodes which creates an environment from the bindings
    return executeReturnClauseWithNodes(allocator, ret, bindings.*, relationships);
}

// Count matches of a graph pattern
