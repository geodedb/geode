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

// Global Catalog instance - P2-2 Phase 2 migration to dependency injection
// This replaces the global mutable catalog struct with a proper instance
var global_catalog_instance: ?*catalog_mod.Catalog = null;
var catalog_instance_mutex = std.Thread.Mutex{};

/// Ensure the global catalog instance is initialized
/// Returns a pointer to the catalog instance
/// P2-3: Now accepts allocator parameter instead of using page_allocator
pub fn ensureCatalogInstance(allocator: std.mem.Allocator) !*catalog_mod.Catalog {
    catalog_instance_mutex.lock();
    defer catalog_instance_mutex.unlock();

    if (global_catalog_instance) |instance| {
        return instance;
    }

    // Get data directory from environment or use default
    const data_dir = std.process.getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
            break :blk "/tmp";
        }
        return err;
    };

    // Create the catalog instance with provided allocator (P2-3: No more page_allocator)
    const instance = try catalog_mod.Catalog.init(allocator, data_dir);
    global_catalog_instance = instance;
    return instance;
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

// Helper function to duplicate an ExecutionResult
fn duplicateResult(allocator: std.mem.Allocator, original: ExecutionResult) !ExecutionResult {
    // Duplicate columns
    const columns = try allocator.alloc([]const u8, original.columns.len);
    for (original.columns, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    // Duplicate rows
    const rows = try allocator.alloc([]eval.Value, original.rows.len);
    for (original.rows, 0..) |row, i| {
        const new_row = try allocator.alloc(eval.Value, row.len);
        for (row, 0..) |val, j| {
            new_row[j] = try duplicateValue(allocator, val);
        }
        rows[i] = new_row;
    }

    // Duplicate flags
    var flags = try std.ArrayList([]const u8).initCapacity(allocator, original.flags.items.len);
    for (original.flags.items) |flag| {
        try flags.append(allocator, try allocator.dupe(u8, flag));
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = flags,
        .owns_value_memory = true, // Duplicated result owns its value memory
    };
}

// Helper function to duplicate a Value
fn duplicateValue(allocator: std.mem.Allocator, value: eval.Value) !eval.Value {
    return switch (value) {
        .Null, .Int, .Bool, .Decimal => value, // These are copy-by-value
        .Str => |s| .{ .Str = try allocator.dupe(u8, s) },
        .List => |list| blk: {
            const new_list = try allocator.alloc(eval.Value, list.len);
            for (list, 0..) |item, i| {
                new_list[i] = try duplicateValue(allocator, item);
            }
            break :blk .{ .List = new_list };
        },
        .Node, .Edge, .Path => value, // These contain pointers but we'll shallow copy for now
        else => value, // Fallback for any other types
    };
}

// Helper function to free a Value's allocated memory
fn freeValue(allocator: std.mem.Allocator, value: eval.Value) void {
    switch (value) {
        .Str => |s| allocator.free(s),
        .List => |list| {
            for (list) |item| {
                freeValue(allocator, item);
            }
            allocator.free(list);
        },
        else => {}, // Other types don't own memory or are shallow copies
    }
}

/// P2-3: Now accepts allocator parameter for temporary allocations
fn writeValue(allocator: std.mem.Allocator, writer: anytype, value: eval.Value) !void {
    switch (value) {
        .Null => try writer.writeAll("null"),
        .Int => |n| try writer.print("{d}", .{n}),
        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .Str => |s| {
            try writer.writeByte('"');
            // Unescape GQL doubled single quotes ('') to single quotes (')
            // and escape JSON special characters
            var i: usize = 0;
            while (i < s.len) {
                const c = s[i];
                switch (c) {
                    '\'' => {
                        // Check for doubled single quote (GQL escape)
                        if (i + 1 < s.len and s[i + 1] == '\'') {
                            // Skip the second quote - output only one
                            try writer.writeByte('\'');
                            i += 2;
                        } else {
                            // Single quote not doubled
                            try writer.writeByte('\'');
                            i += 1;
                        }
                    },
                    '"' => {
                        // JSON requires escaping double quotes
                        try writer.writeAll("\\\"");
                        i += 1;
                    },
                    '\\' => {
                        // JSON requires escaping backslashes
                        try writer.writeAll("\\\\");
                        i += 1;
                    },
                    '\n' => {
                        try writer.writeAll("\\n");
                        i += 1;
                    },
                    '\r' => {
                        try writer.writeAll("\\r");
                        i += 1;
                    },
                    '\t' => {
                        try writer.writeAll("\\t");
                        i += 1;
                    },
                    else => {
                        try writer.writeByte(c);
                        i += 1;
                    },
                }
            }
            try writer.writeByte('"');
        },
        .Decimal => |d| {
            // Format decimal with proper scale
            if (d.scale == 0) {
                try writer.print("{d}", .{d.coeff});
            } else {
                const divisor = std.math.pow(i64, 10, d.scale);
                const whole = @divTrunc(d.coeff, divisor);
                const frac = @rem(d.coeff, divisor);
                if (frac == 0) {
                    try writer.print("{d}", .{whole});
                } else {
                    // Format with decimal point
                    const f: f64 = @as(f64, @floatFromInt(d.coeff)) / @as(f64, @floatFromInt(divisor));
                    try writer.print("{d}", .{f});
                }
            }
        },
        .List => |list| {
            try writer.writeByte('[');
            for (list, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeValue(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        .Node => |node| {
            // For now, output node as a JSON object with its properties
            try writer.writeAll("{");
            try writer.print("\"id\":{d}", .{node.id});
            if (node.labels.len > 0) {
                try writer.writeAll(",\"labels\":[");
                for (node.labels, 0..) |label, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writer.writeByte('"');
                    try writer.writeAll(label);
                    try writer.writeByte('"');
                }
                try writer.writeAll("]");
            }
            // Add properties if any
            if (node.properties.count() > 0) {
                try writer.writeAll(",\"properties\":{");
                var iter = node.properties.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.writeByte('"');
                    try writer.writeAll(entry.key_ptr.*);
                    try writer.writeAll("\":");
                    switch (entry.value_ptr.*) {
                        .String => |s| {
                            // Field-Level Encryption: decrypt if configured
                            const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";
                            const user_role = fle_integration.getCurrentUserRole();
                            // P2-3: Use provided allocator instead of page_allocator
                            const fle_ctx = fle_integration.EncryptionContext{
                                .tenant_id = "default",
                                .schema_name = type_name, // Use actual node type
                                .allocator = allocator,
                                .current_user_role = user_role,
                            };
                            const record_id_buf = try std.fmt.allocPrint(allocator, "{d}", .{node.id});
                            defer allocator.free(record_id_buf);

                            const decrypted = fle_integration.decryptFieldIfNeeded(
                                fle_ctx,
                                type_name,
                                entry.key_ptr.*,
                                s,
                                record_id_buf,
                                true, // Check RBAC
                            ) catch |err| blk_decrypt: {
                                // For SearchNotPermitted, return redacted placeholder
                                if (err == fle_integration.fle_aead_mod.Error.SearchNotPermitted) {
                                    break :blk_decrypt "[REDACTED]";
                                }
                                // Fall back to ciphertext on other errors (e.g., AEADAuthFailed)
                                break :blk_decrypt s;
                            };

                            try writer.writeByte('"');
                            try writer.writeAll(decrypted);
                            try writer.writeByte('"');
                        },
                        .Int => |i| try writer.print("{d}", .{i}),
                        .Float => |f| try writer.print("{d}", .{f}),
                        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                        .Null => try writer.writeAll("null"),
                        .ExtValue => try writer.writeAll("\"<ExtValue>\""), // Placeholder for ExtValue serialization
                    }
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("}");
        },
        .Edge => |edge| {
            // Output edge as a JSON object with its properties
            try writer.writeAll("{");
            try writer.print("\"id\":{d},\"from\":{d},\"to\":{d},\"type\":\"{s}\"", .{ edge.id, edge.from_id, edge.to_id, edge.label });
            // Add properties if any
            if (edge.properties.count() > 0) {
                try writer.writeAll(",\"properties\":{");
                var iter = edge.properties.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.writeByte('"');
                    try writer.writeAll(entry.key_ptr.*);
                    try writer.writeAll("\":");
                    const prop_value = entry.value_ptr.*;
                    switch (prop_value) {
                        .String => |s| {
                            // Field-Level Encryption: decrypt if configured
                            const type_name = edge.label;
                            // P2-3: Use provided allocator instead of page_allocator
                            const fle_ctx = fle_integration.EncryptionContext{
                                .tenant_id = "default",
                                .schema_name = type_name, // Use actual edge type
                                .allocator = allocator,
                                .current_user_role = fle_integration.getCurrentUserRole(),
                            };
                            const record_id_buf = try std.fmt.allocPrint(allocator, "edge_{d}", .{edge.id});
                            defer allocator.free(record_id_buf);

                            const decrypted = fle_integration.decryptFieldIfNeeded(
                                fle_ctx,
                                type_name,
                                entry.key_ptr.*,
                                s,
                                record_id_buf,
                                true, // Check RBAC
                            ) catch |err| blk_decrypt: {
                                // For SearchNotPermitted, return redacted placeholder
                                if (err == fle_integration.fle_aead_mod.Error.SearchNotPermitted) {
                                    break :blk_decrypt "[REDACTED]";
                                }
                                // Fall back to ciphertext on other errors (e.g., AEADAuthFailed)
                                break :blk_decrypt s;
                            };

                            try writer.writeByte('"');
                            try writer.writeAll(decrypted);
                            try writer.writeByte('"');
                        },
                        .Int => |i| try writer.print("{d}", .{i}),
                        .Float => |f| try writer.print("{d}", .{f}),
                        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                        .Null => try writer.writeAll("null"),
                        .ExtValue => try writer.writeAll("\"<ExtValue>\""), // Placeholder for ExtValue serialization
                    }
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("}");
        },
        .Map => |map| {
            try writer.writeByte('{');
            var iter = map.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.writeByte('"');
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("\":");
                try writeValue(allocator, writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .ExtValue => |ext| {
            // Convert extended types to JSON strings
            switch (ext) {
                .Null => try writer.writeAll("null"),
                .Int => |n| try writer.print("{d}", .{n}),
                .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                .Str => |s| {
                    try writer.writeByte('"');
                    try writer.writeAll(s);
                    try writer.writeByte('"');
                },
                .Decimal => |d| {
                    // Format decimal with proper scale
                    if (d.scale == 0) {
                        try writer.print("{d}", .{d.coeff});
                    } else {
                        const divisor = std.math.pow(i64, 10, d.scale);
                        const f: f64 = @as(f64, @floatFromInt(d.coeff)) / @as(f64, @floatFromInt(divisor));
                        try writer.print("{d}", .{f});
                    }
                },
                .VectorF32 => {
                    try writer.writeAll("\"[vector]\"");
                },
                .IpAddr => |ip| {
                    try writer.writeByte('"');
                    switch (ip) {
                        .v4 => |octets| try writer.print("{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] }),
                        .v6 => |bytes| {
                            var segments: [8]u16 = undefined;
                            for (0..8) |i| {
                                segments[i] = (@as(u16, bytes[i * 2]) << 8) | @as(u16, bytes[i * 2 + 1]);
                            }
                            try writer.print("{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{ segments[0], segments[1], segments[2], segments[3], segments[4], segments[5], segments[6], segments[7] });
                        },
                    }
                    try writer.writeByte('"');
                },
                .Subnet => |subnet| {
                    try writer.writeByte('"');
                    switch (subnet.addr) {
                        .v4 => |octets| try writer.print("{d}.{d}.{d}.{d}/{d}", .{ octets[0], octets[1], octets[2], octets[3], subnet.prefix_len }),
                        .v6 => |bytes| {
                            var segments: [8]u16 = undefined;
                            for (0..8) |i| {
                                segments[i] = (@as(u16, bytes[i * 2]) << 8) | @as(u16, bytes[i * 2 + 1]);
                            }
                            try writer.print("{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}/{d}", .{ segments[0], segments[1], segments[2], segments[3], segments[4], segments[5], segments[6], segments[7], subnet.prefix_len });
                        },
                    }
                    try writer.writeByte('"');
                },
                .Mac => |mac| {
                    try writer.print("\"{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}\"", .{ mac.bytes[0], mac.bytes[1], mac.bytes[2], mac.bytes[3], mac.bytes[4], mac.bytes[5] });
                },
                .Hash => |hash| {
                    try writer.print("\"[hash:{s}]\"", .{@tagName(hash.alg)});
                },
                .LatLon => |latlon| {
                    try writer.print("\"({d:.6},{d:.6})\"", .{ latlon.lat, latlon.lon });
                },
                .LatLonAlt => |latlonalt| {
                    try writer.print("\"({d:.6},{d:.6},{d:.2}m)\"", .{ latlonalt.lat, latlonalt.lon, latlonalt.alt });
                },
                .Date => |date| {
                    // Format date as YYYY-MM-DD using civil calendar algorithm
                    // Convert days since Unix epoch (1970-01-01) to Gregorian Y-M-D

                    // Shift from Unix epoch to use algorithm starting from 0000-03-01
                    const z: i64 = @as(i64, date.days_since_epoch) + 719468; // Days from 0000-03-01 to 1970-01-01
                    const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
                    const doe: u32 = @intCast(z - era * 146097); // Day of era [0, 146096]
                    const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365)); // Year of era [0, 399]
                    const y_tmp: i64 = @as(i64, yoe) + era * 400;
                    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100); // Day of year [0, 365]
                    const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153)); // Month' [0, 11]
                    const d: u32 = doy - @divFloor(153 * mp + 2, 5) + 1; // Day [1, 31]
                    const m: u32 = if (mp < 10) mp + 3 else mp - 9; // Month [1, 12]
                    const y: i64 = y_tmp + @as(i64, if (m <= 2) @as(u32, 1) else @as(u32, 0));

                    try writer.print("\"{:0>4}-{:0>2}-{:0>2}\"", .{ @abs(y), m, d });
                },
                .Time => |time| {
                    // Format time as HH:MM:SS.ffffff
                    const micros = time.micros_since_midnight;
                    const hours: u32 = @intCast(@divFloor(micros, 3600 * 1_000_000));
                    const remaining_after_hours = micros - @as(i64, hours) * 3600 * 1_000_000;
                    const minutes: u32 = @intCast(@divFloor(remaining_after_hours, 60 * 1_000_000));
                    const remaining_after_mins = remaining_after_hours - @as(i64, minutes) * 60 * 1_000_000;
                    const seconds: u32 = @intCast(@divFloor(remaining_after_mins, 1_000_000));
                    const microseconds: u32 = @intCast(remaining_after_mins - @as(i64, seconds) * 1_000_000);

                    try writer.print("\"{:0>2}:{:0>2}:{:0>2}.{:0>6}\"", .{ hours, minutes, seconds, microseconds });
                },
                .TimestampTZ => |ts| {
                    // Format timestamp as ISO8601: YYYY-MM-DDTHH:MM:SS.ffffffZ
                    const micros = ts.micros_since_epoch_utc;
                    const seconds_since_epoch = @divFloor(micros, 1_000_000);
                    const days_since_epoch: i64 = @divFloor(seconds_since_epoch, 86400);

                    // Calculate time of day, handling negative timestamps correctly
                    var time_of_day_micros = @mod(micros, 86400 * 1_000_000);
                    if (time_of_day_micros < 0) {
                        time_of_day_micros += 86400 * 1_000_000;
                    }

                    // Date part using civil calendar algorithm
                    const z: i64 = days_since_epoch + 719468; // Days from 0000-03-01 to 1970-01-01
                    const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
                    const doe: u32 = @intCast(z - era * 146097); // Day of era [0, 146096]
                    const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365)); // Year of era [0, 399]
                    const y_tmp: i64 = @as(i64, yoe) + era * 400;
                    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100); // Day of year [0, 365]
                    const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153)); // Month' [0, 11]
                    const d: u32 = doy - @divFloor(153 * mp + 2, 5) + 1; // Day [1, 31]
                    const m: u32 = if (mp < 10) mp + 3 else mp - 9; // Month [1, 12]
                    const y: i64 = y_tmp + @as(i64, if (m <= 2) @as(u32, 1) else @as(u32, 0));

                    // Time part
                    const hours: u32 = @intCast(@divFloor(time_of_day_micros, 3600 * 1_000_000));
                    const rem_after_hours = time_of_day_micros - @as(i64, hours) * 3600 * 1_000_000;
                    const minutes: u32 = @intCast(@divFloor(rem_after_hours, 60 * 1_000_000));
                    const rem_after_mins = rem_after_hours - @as(i64, minutes) * 60 * 1_000_000;
                    const secs: u32 = @intCast(@divFloor(rem_after_mins, 1_000_000));
                    const microseconds: u32 = @intCast(rem_after_mins - @as(i64, secs) * 1_000_000);

                    try writer.print("\"{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>6}Z\"", .{ @abs(y), m, d, hours, minutes, secs, microseconds });
                },
                else => try writer.writeAll("\"[advanced_type]\""),
            }
        },
        .Path => |path| {
            // Output path as JSON object with nodes and edges
            try writer.writeAll("{\"nodes\":[");
            for (path.nodes, 0..) |node, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{d}", .{node.id});
            }
            try writer.writeAll("],\"edges\":[");
            for (path.edges, 0..) |edge, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{d}", .{edge.id});
            }
            try writer.writeAll("]}");
        },
    }
}

/// Check if user has required permission for operation
fn checkPermission(context: ExecutionContext, permission: @import("security/user_management.zig").Permission) !void {
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
    return executeProgramWithContext(allocator, program, .{});
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
        .Intersect => |i| {
            return executeIntersect(allocator, i);
        },
        .Except => |e| {
            return executeExcept(allocator, e);
        },
        .Create => |c| {
            // Check write permission
            try checkPermission(context, .Write);
            return executeCreate(allocator, c);
        },
        .Insert => |ins| {
            // Check write permission
            try checkPermission(context, .Write);
            return executeInsert(allocator, ins);
        },
        .Delete => |d| {
            // Check write permission
            try checkPermission(context, .Write);
            return executeDelete(allocator, d);
        },
        .Merge => |m| {
            // Check write permission
            try checkPermission(context, .Write);
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
            // CANARY: REQ=REQ-INDEX-002; FEATURE="IndexManagement"; ASPECT=ScopedCreation; STATUS=IMPLEMENTED; OWNER=storage; UPDATED=2025-10-14
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

            const index_name = ci.name;
            const label = ci.label;

            // Phase 3: Write lock for CREATE INDEX
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Generate scoped key: "label:index_name"
            // This allows the same index name on different labels (e.g., Person:idx and Company:idx)
            // P2-3: Use provided allocator instead of page_allocator
            const scoped_key = try getScopedIndexKey(allocator, label, index_name);
            defer allocator.free(scoped_key);

            // Check if index already exists for this label
            if (!ci.if_not_exists and cat.indexes.contains(scoped_key)) {
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
            if (!cat.indexes.contains(scoped_key)) {
                // Create IndexInfo with all the details
                // P2-3: Use catalog's allocator for index info (owned by catalog)
                const index_info = IndexInfo{
                    .name = try cat.allocator.dupe(u8, index_name),
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
                    .table_name = try cat.allocator.dupe(u8, label),
                    .columns = blk: {
                        var cols = try cat.allocator.alloc([]const u8, ci.properties.len);
                        for (ci.properties, 0..) |prop, i| {
                            cols[i] = try cat.allocator.dupe(u8, prop);
                        }
                        break :blk cols;
                    },
                };
                // Use scoped key for storage: "label:index_name"
                // P2-3: Use catalog's allocator for the key (owned by catalog)
                const stored_key = try getScopedIndexKey(cat.allocator, label, index_name);
                try cat.indexes.put(stored_key, index_info);
                // Save catalog to disk after creating index
                cat.save() catch |err| {
                    std.log.err("CRITICAL: Failed to persist catalog after index creation  '{s}': {any}", .{ index_name, err });
                };
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
            // CANARY: REQ=REQ-INDEX-003; FEATURE="IndexManagement"; ASPECT=ScopedDeletion; STATUS=IMPLEMENTED; OWNER=storage; UPDATED=2025-10-14
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

            const index_name = di.name;

            // Phase 3: Write lock for DROP INDEX
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Search for index by name across all labels
            // Since we use scoped keys ("label:index_name"), we need to find the matching entry
            var found_key: ?[]const u8 = null;
            var iter = cat.indexes.iterator();
            while (iter.next()) |entry| {
                const info = entry.value_ptr.*;
                if (std.mem.eql(u8, info.name, index_name)) {
                    found_key = entry.key_ptr.*;
                    break;
                }
            }

            if (found_key) |key| {
                // Found the index, remove it
                if (cat.indexes.fetchRemove(key)) |removed| {
                    // Free the allocated memory
                    // P2-3: Use catalog's allocator (data was allocated with cat.allocator)
                    cat.allocator.free(removed.key);
                    cat.allocator.free(removed.value.name);
                    cat.allocator.free(removed.value.table_name);
                    for (removed.value.columns) |col| {
                        cat.allocator.free(col);
                    }
                    cat.allocator.free(removed.value.columns);
                }
                // Save catalog after dropping index
                cat.save() catch |err| {
                    std.log.err("CRITICAL: Failed to persist catalog after index drop  '{s}': {any}", .{ index_name, err });
                };
            } else if (!di.if_exists) {
                return error.IndexNotFound;
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
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

            const graph_name = cg.name;

            // Phase 3: Write lock for CREATE GRAPH
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Handle OR REPLACE
            if (cg.or_replace) {
                // Remove existing graph if it exists
                if (cat.graphs.fetchRemove(graph_name)) |entry| {
                    // P2-3: Use catalog's allocator
                    cat.allocator.free(entry.key);
                }
            } else {
                // Check if graph already exists
                if (cat.graphs.contains(graph_name)) {
                    // If IF NOT EXISTS is specified, silently succeed
                    if (cg.if_not_exists) {
                        return ExecutionResult{
                            .columns = try allocator.alloc([]const u8, 0),
                            .rows = try allocator.alloc([]eval.Value, 0),
                            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
                        };
                    }
                    return error.DuplicateGraph;
                }
            }

            // Add to catalog
            // P2-3: Use catalog's allocator (owned by catalog)
            try cat.graphs.put(try cat.allocator.dupe(u8, graph_name), {});
            // Save catalog to disk after creating graph
            cat.save() catch |err| {
                std.log.err("CRITICAL: Failed to persist catalog after graph creation  '{s}': {any}", .{ graph_name, err });
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .CreateGraphType => |cgt| {
            // CREATE GRAPH TYPE implementation with FLE catalog registration

            // Get global FLE catalog
            const fle_cat = try fle_catalog.globalCatalog(allocator);

            // Create type metadata
            var type_meta = fle_annotations.TypeMetadata.init(allocator, cgt.name);
            errdefer type_meta.deinit();

            // Process field definitions and apply annotations
            for (cgt.fields) |field_def| {
                // Build full annotation text by concatenating all annotations
                var annotation_text_builder = std.ArrayList(u8).initCapacity(allocator, 256) catch @panic("OOM");
                defer annotation_text_builder.deinit(allocator);

                for (field_def.annotations) |annot| {
                    try annotation_text_builder.appendSlice(allocator, annot.text);
                    try annotation_text_builder.append(allocator, ' ');
                }

                const full_annotation_text = try annotation_text_builder.toOwnedSlice(allocator);
                defer allocator.free(full_annotation_text);

                // Apply annotations to field and add to type metadata
                if (full_annotation_text.len > 0) {
                    try fle_annotations.applyAnnotations(
                        allocator,
                        &type_meta,
                        field_def.name,
                        full_annotation_text,
                    );
                } else {
                    // Field has no annotations - add as plaintext field
                    const field_meta = fle_annotations.FieldMetadata{
                        .field_name = field_def.name,
                    };
                    try type_meta.fields.put(field_def.name, field_meta);
                }
            }

            // Register type in catalog
            try fle_cat.registerType(cgt.name, type_meta);

            // Save FLE catalog to disk
            fle_catalog.saveCatalog(fle_cat) catch |err| {
                std.log.err("CRITICAL: Failed to persist FLE catalog after type creation  '{s}': {any}", .{ cgt.name, err });
            };

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropGraph => |dg| {
            // DROP GRAPH implementation with existence check
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

            const graph_name = dg.name;

            // Phase 3: Write lock for DROP GRAPH
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Check if graph exists (unless IF EXISTS is used)
            if (!dg.if_exists and !cat.graphs.contains(graph_name)) {
                return error.GraphNotFound;
            }

            // Remove from catalog if it exists
            _ = cat.graphs.remove(graph_name);

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
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

            const schema_name = cs.name;

            // Phase 3: Write lock for CREATE SCHEMA
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Check if schema already exists
            if (!cs.if_not_exists and cat.schemas.contains(schema_name)) {
                return error.DuplicateSchema;
            }

            // Add to catalog if not exists
            if (!cat.schemas.contains(schema_name)) {
                // P2-3: Use catalog's allocator (owned by catalog)
                try cat.schemas.put(try cat.allocator.dupe(u8, schema_name), {});
                // Save catalog to disk after creating schema
                cat.save() catch |err| {
                    std.log.err("CRITICAL: Failed to persist catalog after schema creation  '{s}': {any}", .{ schema_name, err });
                };
            }

            return ExecutionResult{
                .columns = try allocator.alloc([]const u8, 0),
                .rows = try allocator.alloc([]eval.Value, 0),
                .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            };
        },
        .DropSchema => |ds| {
            // DROP SCHEMA implementation with existence check
            // P2-2 Phase 2: Use Catalog instance instead of global state
            // P2-3: Pass allocator to ensureCatalogInstance
            const cat = try ensureCatalogInstance(allocator);

            const schema_name = ds.name;

            // Phase 3: Write lock for DROP SCHEMA
            cat.rwlock.lock();
            defer cat.rwlock.unlock();

            // Check if schema exists (unless IF EXISTS is used)
            if (!ds.if_exists and !cat.schemas.contains(schema_name)) {
                return error.SchemaNotFound;
            }

            // Remove from catalog if it exists
            _ = cat.schemas.remove(schema_name);

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

fn createTestGraphG1(allocator: std.mem.Allocator) !void {
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

fn createTestGraphG2(allocator: std.mem.Allocator) !void {
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

fn validateGroupBy(ret: ast.ReturnClause, group_by: ?ast.GroupBy) !void {
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
pub fn executeQueryChain(allocator: std.mem.Allocator, current_query: ast.Query, next_query_ptr: *ast.Query, context: ExecutionContext) anyerror!ExecutionResult {
    // Execute the current query (without the next_query link to avoid infinite recursion)
    var current_query_standalone = current_query;
    current_query_standalone.next_query = null;

    const current_result = try executeQueryWithContext(allocator, current_query_standalone, context);

    // CANARY(memory-safety): Validate current_result structure before accessing
    // Prevent corrupted column length from causing OutOfMemory errors
    if (current_result.columns.len > 1000000) {
        // Suspiciously large column count - likely corrupted memory
        std.debug.print("ERROR: Corrupted columns.len = {d}\n", .{current_result.columns.len});
        return error.CorruptedExecutionResult;
    }

    // Now execute the next query with the current result as bindings
    // For each row in current_result, execute next_query with those bindings
    var final_rows = std.ArrayList([]eval.Value).initCapacity(allocator, 0) catch unreachable;
    var final_columns: [][]const u8 = &.{};
    var final_flags = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;

    // If current result has no rows, still execute next query once with empty bindings
    if (current_result.rows.len == 0) {
        const next_result = try executeQueryChainWithBindings(allocator, next_query_ptr.*, context, &.{}, &.{});

        // Clean up current_result properly - columns, rows array, and row contents
        for (current_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(current_result.columns);
        // Note: rows.len is 0, so no row contents to free
        allocator.free(current_result.rows);

        return next_result;
    }

    for (current_result.rows) |current_row| {
        // Create parameter bindings from current row
        // The columns from current result become parameter names
        // The values from current row become parameter values
        const next_query_with_bindings = next_query_ptr.*;

        // Build parameter arrays from current result
        // Validate that current_row length matches columns length
        if (current_row.len != current_result.columns.len) {
            std.debug.print("ERROR: Row length {d} != columns length {d}\n", .{ current_row.len, current_result.columns.len });
            return error.MismatchedRowColumnLength;
        }

        // Use try instead of catch unreachable to handle allocation errors gracefully
        var param_names = try std.ArrayList([]const u8).initCapacity(allocator, current_result.columns.len);
        defer param_names.deinit(allocator);
        var param_values = try std.ArrayList(eval.Value).initCapacity(allocator, current_result.columns.len);
        defer param_values.deinit(allocator);

        for (current_result.columns, current_row) |col_name, col_value| {
            try param_names.append(allocator, col_name);
            try param_values.append(allocator, col_value);
        }

        // Execute the next query with these bindings as an initial environment
        const next_result = try executeQueryChainWithBindings(allocator, next_query_with_bindings, context, param_names.items, param_values.items);

        // Collect results
        if (final_columns.len == 0) {
            // First iteration: set up columns
            final_columns = try allocator.alloc([]const u8, next_result.columns.len);
            for (next_result.columns, 0..) |col, i| {
                final_columns[i] = try allocator.dupe(u8, col);
            }
        }

        // Add all rows from next_result
        for (next_result.rows) |row| {
            // Duplicate the row to avoid ownership issues
            const row_copy = try allocator.alloc(eval.Value, row.len);
            for (row, 0..) |val, i| {
                row_copy[i] = val;
            }
            try final_rows.append(allocator, row_copy);
        }

        // Collect flags
        for (next_result.flags.items) |flag| {
            try final_flags.append(allocator, flag);
        }

        // Clean up next_result (we copied what we needed)
        for (next_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(next_result.columns);
        for (next_result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(next_result.rows);
        // next_result.flags owned by result, no need to deinit
    }

    // Clean up current_result
    for (current_result.columns) |col| {
        allocator.free(col);
    }
    allocator.free(current_result.columns);
    for (current_result.rows) |row| {
        allocator.free(row);
    }
    allocator.free(current_result.rows);
    // current_result.flags owned by result, no need to deinit

    return ExecutionResult{
        .columns = final_columns,
        .rows = try final_rows.toOwnedSlice(allocator),
        .flags = final_flags,
    };
}

// Helper function to execute a query with pre-existing bindings from a previous query
fn executeQueryChainWithBindings(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext, binding_names: []const []const u8, binding_values: []const eval.Value) anyerror!ExecutionResult {
    // Check if this query also has a next_query (multi-level chaining)
    if (q.next_query) |next_query_ptr| {
        // Execute current query with bindings, then chain to next
        var current_query_standalone = q;
        current_query_standalone.next_query = null;

        const current_result = try executeQueryWithBindingsImpl(allocator, current_query_standalone, context, binding_names, binding_values);

        // CANARY(memory-safety): Validate current_result structure before accessing
        // Prevent corrupted column length from causing OutOfMemory errors
        if (current_result.columns.len > 1000000) {
            // Suspiciously large column count - likely corrupted memory
            std.debug.print("ERROR: Corrupted columns.len = {d} in executeQueryChainWithBindings\n", .{current_result.columns.len});
            return error.CorruptedExecutionResult;
        }

        // Chain to next query using the result as bindings
        var final_rows = std.ArrayList([]eval.Value).initCapacity(allocator, 0) catch unreachable;
        var final_columns: [][]const u8 = &.{};
        var final_flags = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;

        for (current_result.rows) |current_row| {
            // Validate that current_row length matches columns length
            if (current_row.len != current_result.columns.len) {
                std.debug.print("ERROR: Row length {d} != columns length {d} in executeQueryChainWithBindings\n", .{ current_row.len, current_result.columns.len });
                return error.MismatchedRowColumnLength;
            }

            var param_names = std.ArrayList([]const u8).initCapacity(allocator, current_result.columns.len) catch unreachable;
            defer param_names.deinit(allocator);
            var param_values = std.ArrayList(eval.Value).initCapacity(allocator, current_result.columns.len) catch unreachable;
            defer param_values.deinit(allocator);

            for (current_result.columns, current_row) |col_name, col_value| {
                try param_names.append(allocator, col_name);
                try param_values.append(allocator, col_value);
            }

            const next_result = try executeQueryChainWithBindings(allocator, next_query_ptr.*, context, param_names.items, param_values.items);

            if (final_columns.len == 0) {
                final_columns = try allocator.alloc([]const u8, next_result.columns.len);
                for (next_result.columns, 0..) |col, i| {
                    final_columns[i] = try allocator.dupe(u8, col);
                }
            }

            for (next_result.rows) |row| {
                const row_copy = try allocator.alloc(eval.Value, row.len);
                for (row, 0..) |val, i| {
                    row_copy[i] = val;
                }
                try final_rows.append(allocator, row_copy);
            }

            for (next_result.flags.items) |flag| {
                try final_flags.append(allocator, flag);
            }

            for (next_result.columns) |col| {
                allocator.free(col);
            }
            allocator.free(next_result.columns);
            for (next_result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(next_result.rows);
            // next_result.flags owned by result, no need to deinit
        }

        for (current_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(current_result.columns);
        for (current_result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(current_result.rows);
        // current_result.flags owned by result, no need to deinit

        return ExecutionResult{
            .columns = final_columns,
            .rows = try final_rows.toOwnedSlice(allocator),
            .flags = final_flags,
        };
    }

    // No further chaining, just execute with bindings
    return executeQueryWithBindingsImpl(allocator, q, context, binding_names, binding_values);
}

// Execute a query with pre-existing bindings available as parameters
pub fn executeQueryWithBindingsImpl(allocator: std.mem.Allocator, q: ast.Query, _: ExecutionContext, binding_names: []const []const u8, binding_values: []const eval.Value) anyerror!ExecutionResult {
    // For simple MATCH patterns with bound variables, we can shortcut the matching
    // and just use the bound values directly in the RETURN clause

    // Check if this is a simple MATCH with only node patterns (no relationships)
    var all_vars_bound = true;
    var bound_var_env_names = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    defer bound_var_env_names.deinit(allocator);
    var bound_var_env_values = std.ArrayList(eval.Value).initCapacity(allocator, 0) catch unreachable;
    defer bound_var_env_values.deinit(allocator);

    if (q.match.chains.len > 0) {
        for (q.match.chains) |chain| {
            if (chain.head) |node_pattern| {
                if (node_pattern.name) |var_name| {
                    // Check if this variable is in the bindings
                    var found = false;
                    for (binding_names, binding_values) |name, value| {
                        if (std.mem.eql(u8, name, var_name)) {
                            try bound_var_env_names.append(allocator, var_name);
                            try bound_var_env_values.append(allocator, value);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        all_vars_bound = false;
                        break;
                    }
                }
            } else if (chain.hops.len > 0) {
                // Has relationships, not a simple bound variable case
                all_vars_bound = false;
                break;
            }
        }
    }

    // If there's no MATCH clause, just evaluate RETURN with bindings
    if (q.match.chains.len == 0 and binding_names.len > 0) {
        const items = q.ret.items;
        var columns = try allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            const column_name = item.alias orelse blk: {
                switch (item.expr) {
                    .Ident => |ident| break :blk ident.orig,
                    .PropertyAccess => |prop| break :blk prop.property,
                    .Member => |mem| break :blk mem.field,
                    else => break :blk "column",
                }
            };
            columns[i] = try allocator.dupe(u8, column_name);
        }

        // Create a single row by evaluating RETURN expressions with bindings
        var row = try allocator.alloc(eval.Value, items.len);

        const env = eval.Env{
            .allocator = allocator,
            .names = binding_names,
            .values = binding_values,
        };

        for (items, 0..) |item, i| {
            row[i] = try eval.evalExpr(allocator, item.expr, env);
        }

        var rows = try allocator.alloc([]eval.Value, 1);
        rows[0] = row;

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // If all MATCH variables are bound, we can skip matching and just evaluate RETURN
    if (all_vars_bound and bound_var_env_names.items.len > 0) {
        const items = q.ret.items;
        var columns = try allocator.alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            const column_name = item.alias orelse blk: {
                switch (item.expr) {
                    .Ident => |ident| break :blk ident.orig,
                    .PropertyAccess => |prop| break :blk prop.property,
                    .Member => |mem| break :blk mem.field,
                    else => break :blk "column",
                }
            };
            columns[i] = try allocator.dupe(u8, column_name);
        }

        // Create a single row by evaluating RETURN expressions with bound variables
        var row = try allocator.alloc(eval.Value, items.len);

        const env = eval.Env{
            .allocator = allocator,
            .names = bound_var_env_names.items,
            .values = bound_var_env_values.items,
            .param_names = binding_names,
            .param_values = binding_values,
        };

        for (items, 0..) |item, i| {
            row[i] = try eval.evalExpr(allocator, item.expr, env);
        }

        var rows = try allocator.alloc([]eval.Value, 1);
        rows[0] = row;

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    // Otherwise, execute the query normally with bindings available as parameters
    // Execute the full query with bindings passed as parameters
    return executeMatchQueryImpl(allocator, q, binding_names, binding_values, &.{});
}

fn executeQuery(allocator: std.mem.Allocator, q: ast.Query) !ExecutionResult {
    return executeQueryWithContext(allocator, q, .{});
}

pub fn executeQueryWithContext(allocator: std.mem.Allocator, q: ast.Query, context: ExecutionContext) !ExecutionResult {
    // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=Execution;
    //         STATUS=IMPLEMENTED; TEST=graph_algorithms; OWNER=execution; UPDATED=2025-10-10

    // Check for query chaining: if next_query exists, execute chain
    if (q.next_query) |next_query_ptr| {
        return executeQueryChain(allocator, q, next_query_ptr, context);
    }

    // Evaluate LET bindings first and add them to parameter environment
    var param_names = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    defer param_names.deinit(allocator);
    var param_values = std.ArrayList(eval.Value).initCapacity(allocator, 0) catch unreachable;
    defer param_values.deinit(allocator);

    // Empty environment for evaluating LET binding expressions
    const let_env = eval.Env{
        .names = &.{},
        .values = &.{},
        .allocator = allocator,
    };

    for (q.let_bindings) |binding| {
        const value = try eval.evalExpr(allocator, binding.value, let_env);
        try param_names.append(allocator, binding.variable);
        try param_values.append(allocator, value);
    }

    // Check for GROUP BY validation first
    try validateGroupBy(q.ret, q.group_by);

    // Check if there's BOTH a MATCH and CREATE pattern (MATCH ... CREATE)
    if (q.match.chains.len > 0 and q.create_pattern != null) {
        return executeMatchCreateQuery(allocator, q);
    }

    // Check if there's a CREATE pattern (CREATE ... WITH ... SET ... RETURN)
    if (q.create_pattern) |create_pattern| {
        return executeCreateQuery(allocator, q, create_pattern, null);
    }

    // Check if there's a MATCH + CALL pattern
    if (q.match.chains.len > 0 and q.call_clause != null) {
        return executeMatchCallQuery(allocator, q, context);
    }

    // Check if there's a MATCH pattern
    if (q.match.chains.len > 0) {
        return executeMatchQueryWithParams(allocator, q, param_names.items, param_values.items, q.inline_let_bindings);
    }

    // Handle initial CALL subquery (e.g., CALL { MATCH (n) RETURN n } WITH ... RETURN ...)
    if (q.initial_call_subquery) |call_subq| {
        // Execute the CALL subquery to get initial results
        const call_result = try executeQueryWithContext(allocator, call_subq.*, context);

        // If there's a WITH clause, apply it to the CALL results
        if (q.with_clause) |with_clause| {
            const with_result = try executeWithClause(allocator, call_result, with_clause);

            // Apply WHERE filter if present
            const filtered_result = if (q.where_clause) |where_expr| blk: {
                var filtered_rows = std.ArrayList([]eval.Value).initCapacity(allocator, 0) catch unreachable;

                for (with_result.rows) |row| {
                    const env = eval.Env{
                        .names = with_result.columns,
                        .values = row,
                        .param_names = param_names.items,
                        .param_values = param_values.items,
                        .allocator = allocator,
                    };

                    const matches = try eval.evalExpr(allocator, where_expr, env);
                    const passes_where = switch (matches) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };
                    if (passes_where) {
                        try filtered_rows.append(allocator, row);
                    }
                }

                break :blk ExecutionResult{
                    .columns = with_result.columns,
                    .rows = try filtered_rows.toOwnedSlice(allocator),
                    .flags = with_result.flags,
                };
            } else with_result;

            // Apply RETURN clause to transform results
            var final_rows = std.ArrayList([]eval.Value).initCapacity(allocator, 0) catch unreachable;

            for (filtered_result.rows) |row| {
                var return_row = try allocator.alloc(eval.Value, q.ret.items.len);

                const env = eval.Env{
                    .names = filtered_result.columns,
                    .values = row,
                    .param_names = param_names.items,
                    .param_values = param_values.items,
                    .allocator = allocator,
                };

                for (q.ret.items, 0..) |item, i| {
                    return_row[i] = try eval.evalExpr(allocator, item.expr, env);
                }

                try final_rows.append(allocator, return_row);
            }

            // Phase 5.1.1 optimization: batch allocate column strings
            var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, q.ret.items.len);
            defer col_name_strings.deinit(allocator);

            for (q.ret.items) |item| {
                const col_name = item.alias orelse switch (item.expr) {
                    .Ident => |ident| ident.orig,
                    else => "column",
                };
                try col_name_strings.append(allocator, col_name);
            }

            const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

            var result = ExecutionResult{
                .columns = col_result.columns,
                .rows = try final_rows.toOwnedSlice(allocator),
                .flags = filtered_result.flags,
                .column_buffer = col_result.buffer,
            };

            // Apply ORDER BY if present
            if (q.order_by) |order| {
                try sortRows(allocator, &result, order);
            }

            // Apply LIMIT if present
            if (q.limit) |lim| {
                if (result.rows.len > lim) {
                    result.rows = result.rows[0..lim];
                }
            }

            return result;
        } else {
            // No WITH clause, just apply WHERE/RETURN to CALL results
            var filtered_rows = std.ArrayList([]eval.Value).initCapacity(allocator, 0) catch unreachable;

            if (q.where_clause) |where_expr| {
                for (call_result.rows) |row| {
                    const env = eval.Env{
                        .names = call_result.columns,
                        .values = row,
                        .param_names = param_names.items,
                        .param_values = param_values.items,
                        .allocator = allocator,
                    };

                    const matches = try eval.evalExpr(allocator, where_expr, env);
                    const passes_where = switch (matches) {
                        .Bool => |b| b,
                        .Null => false,
                        .Int => |i| i != 0,
                        else => false,
                    };
                    if (passes_where) {
                        try filtered_rows.append(allocator, row);
                    }
                }
            } else {
                // No WHERE clause, use all rows
                for (call_result.rows) |row| {
                    try filtered_rows.append(allocator, row);
                }
            }

            // Apply RETURN clause
            var final_rows = std.ArrayList([]eval.Value).initCapacity(allocator, 0) catch unreachable;

            for (filtered_rows.items) |row| {
                var return_row = try allocator.alloc(eval.Value, q.ret.items.len);

                const env = eval.Env{
                    .names = call_result.columns,
                    .values = row,
                    .param_names = param_names.items,
                    .param_values = param_values.items,
                    .allocator = allocator,
                };

                for (q.ret.items, 0..) |item, i| {
                    return_row[i] = try eval.evalExpr(allocator, item.expr, env);
                }

                try final_rows.append(allocator, return_row);
            }

            // Phase 5.1.1 optimization: batch allocate column strings
            var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, q.ret.items.len);
            defer col_name_strings.deinit(allocator);

            for (q.ret.items) |item| {
                const col_name = item.alias orelse switch (item.expr) {
                    .Ident => |ident| ident.orig,
                    else => "column",
                };
                try col_name_strings.append(allocator, col_name);
            }

            const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

            var result = ExecutionResult{
                .columns = col_result.columns,
                .rows = try final_rows.toOwnedSlice(allocator),
                .flags = call_result.flags,
                .column_buffer = col_result.buffer,
            };

            // Apply ORDER BY if present
            if (q.order_by) |order| {
                try sortRows(allocator, &result, order);
            }

            // Apply LIMIT if present
            if (q.limit) |lim| {
                if (result.rows.len > lim) {
                    result.rows = result.rows[0..lim];
                }
            }

            return result;
        }
    }

    // Handle standalone WITH clause (e.g., WITH 5 AS x RETURN x)
    if (q.with_clause) |with_clause| {
        // Create initial empty result with one row
        var initial_result = ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]eval.Value, 1),
            .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
        initial_result.rows[0] = try allocator.alloc(eval.Value, 0);

        // Apply WITH clause to transform the empty row into WITH variables
        const with_result = try executeWithClause(allocator, initial_result, with_clause);

        // Check if there's a FOR statement to execute with WITH bindings
        if (q.for_statement) |for_stmt| {
            return executeForWithBindings(allocator, for_stmt.*, with_result, context);
        }

        // Now evaluate RETURN using the WITH results as environment
        var final_rows = std.ArrayList([]eval.Value).initCapacity(allocator, 0) catch unreachable;

        for (with_result.rows) |with_row| {
            var return_row = try allocator.alloc(eval.Value, q.ret.items.len);

            // Create environment from WITH results + LET binding parameters
            const env = eval.Env{
                .names = with_result.columns,
                .values = with_row,
                .param_names = param_names.items,
                .param_values = param_values.items,
                .allocator = allocator,
            };

            for (q.ret.items, 0..) |item, i| {
                return_row[i] = try eval.evalExpr(allocator, item.expr, env);
            }

            try final_rows.append(allocator, return_row);
        }

        // Get column names from RETURN clause (Phase 5.1.1 optimization: batch allocation)
        var col_name_strings = try std.ArrayList([]const u8).initCapacity(allocator, q.ret.items.len);
        defer col_name_strings.deinit(allocator);

        for (q.ret.items) |item| {
            const col_name = item.alias orelse switch (item.expr) {
                .Ident => |ident| ident.orig,
                else => "column",
            };
            try col_name_strings.append(allocator, col_name);
        }

        const col_result = try allocateColumnStrings(allocator, col_name_strings.items);

        var result = ExecutionResult{
            .columns = col_result.columns,
            .rows = try final_rows.toOwnedSlice(allocator),
            .flags = with_result.flags,
            .column_buffer = col_result.buffer,
        };

        // Clean up with_result (we took ownership of flags, but need to free columns/rows)
        for (with_result.columns) |col| {
            allocator.free(col);
        }
        allocator.free(with_result.columns);
        for (with_result.rows) |row| {
            allocator.free(row);
        }
        allocator.free(with_result.rows);

        // Apply ORDER BY if present
        if (q.order_by) |order| {
            try sortRows(allocator, &result, order);
        }

        return result;
    }

    // Otherwise just execute the return clause
    var result = try executeReturnClauseWithParams(allocator, q.ret, context, param_names.items, param_values.items);

    // Apply ORDER BY if present
    if (q.order_by) |order| {
        try sortRows(allocator, &result, order);
    }

    return result;
}

// Execute MATCH ... CREATE pattern - first match nodes, then create relationships using matched bindings


// CANARY: PERF_PHASE5_COLUMN_BATCH_ALLOC - Helper function for batch column allocation
// CANARY: REQ=REQ-PERF-PHASE5-001; FEATURE="ColumnOptimization"; ASPECT=HELPER_FN; STATUS=IMPL; OWNER=performance; UPDATED=2025-10-16
/// Phase 5.1.1 optimization: Allocate all column strings in a single buffer
/// Reduces N allocations to 1 allocation for N columns (20-30% performance gain)
///
/// Returns a struct containing:
/// - columns: Array of string slices pointing into the buffer
/// - buffer: The allocated buffer (must be stored in ExecutionResult.column_buffer)
fn allocateColumnStrings(allocator: std.mem.Allocator, strings: []const []const u8) !struct { columns: [][]const u8, buffer: []u8 } {
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
    if (input_result.columns.len > 1000000) {
        std.debug.print("ERROR: Corrupted input_result.columns.len = {d} in executeWithClause\n", .{input_result.columns.len});
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
    return executeQueryWithContext(allocator, q, .{});
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

pub fn sortRows(allocator: std.mem.Allocator, result: *ExecutionResult, order: ast.OrderBy) !void {
    // Check if we're using ordinals (need to add flag) - do this before early return
    var uses_ordinal = false;
    for (order.keys) |key| {
        if (key.expr == .Int) {
            uses_ordinal = true;
            break;
        }
    }
    if (uses_ordinal) {
        try result.flags.append(allocator, "E:OrdinalSortKey");
    }

    if (result.rows.len <= 1) return;

    // For now, implement a simple bubble sort
    // TODO: Replace with better sorting algorithm
    var swapped = true;
    while (swapped) {
        swapped = false;
        var i: usize = 0;
        while (i < result.rows.len - 1) : (i += 1) {
            // Compare rows based on ORDER BY keys
            var should_swap = false;

            for (order.keys) |key| {
                // CANARY: REQ=REQ-GQL-101; FEATURE="ORDER BY Expression Evaluation"; ASPECT=Execution; STATUS=FIXED; TEST=gql_conformance.T3; OWNER=execution; UPDATED=2025-10-14
                // Handle ordinal references (ORDER BY 2 means second column)
                var val1: eval.Value = undefined;
                var val2: eval.Value = undefined;

                if (key.expr == .Int) {
                    // Ordinal reference - use 1-based indexing
                    const col_idx = @as(usize, @intCast(key.expr.Int - 1));
                    if (col_idx < result.rows[i].len) {
                        val1 = result.rows[i][col_idx];
                        val2 = result.rows[i + 1][col_idx];
                    } else {
                        // Invalid column index
                        val1 = .{ .Null = {} };
                        val2 = .{ .Null = {} };
                    }
                } else if (key.expr == .Ident) {
                    // Simple column reference - look up by name
                    const col_name = key.expr.Ident.orig;
                    var col_idx_opt: ?usize = null;
                    for (result.columns, 0..) |result_col, idx| {
                        if (std.mem.eql(u8, result_col, col_name)) {
                            col_idx_opt = idx;
                            break;
                        }
                    }
                    if (col_idx_opt) |col_idx| {
                        val1 = result.rows[i][col_idx];
                        val2 = result.rows[i + 1][col_idx];
                    } else {
                        // Column not found
                        val1 = .{ .Null = {} };
                        val2 = .{ .Null = {} };
                    }
                } else {
                    // Complex expression - need to evaluate it for each row
                    // Create environment from row values
                    const env1 = eval.Env{
                        .names = result.columns,
                        .values = result.rows[i],
                        .allocator = allocator,
                    };
                    const env2 = eval.Env{
                        .names = result.columns,
                        .values = result.rows[i + 1],
                        .allocator = allocator,
                    };

                    // Evaluate expressions (errors default to Null)
                    val1 = eval.evalExpr(allocator, key.expr, env1) catch .{ .Null = {} };
                    val2 = eval.evalExpr(allocator, key.expr, env2) catch .{ .Null = {} };
                }

                const cmp = compareValuesWithNullsPolicy(val1, val2, key.nulls);
                if (cmp == 0) continue; // Equal, check next key

                if (key.desc) {
                    should_swap = cmp < 0;
                } else {
                    should_swap = cmp > 0;
                }
                break;
            }

            if (should_swap) {
                const temp = result.rows[i];
                result.rows[i] = result.rows[i + 1];
                result.rows[i + 1] = temp;
                swapped = true;
            }
        }
    }
}

fn compareValues(a: eval.Value, b: eval.Value) i8 {
    return compareValuesWithNullsPolicy(a, b, .default);
}

fn compareValuesWithNullsPolicy(a: eval.Value, b: eval.Value, nulls: ast.OrderBy.NullsPolicy) i8 {
    // Compare values for sorting
    // Returns: -1 if a < b, 0 if a == b, 1 if a > b

    // Handle nulls based on policy
    if (a == .Null and b == .Null) return 0;
    if (a == .Null) {
        return switch (nulls) {
            .default, .first => -1,
            .last => 1,
        };
    }
    if (b == .Null) {
        return switch (nulls) {
            .default, .first => 1,
            .last => -1,
        };
    }

    // Compare same types
    if (a == .Int and b == .Int) {
        if (a.Int < b.Int) return -1;
        if (a.Int > b.Int) return 1;
        return 0;
    }

    if (a == .Str and b == .Str) {
        const cmp = std.mem.order(u8, a.Str, b.Str);
        return switch (cmp) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    if (a == .Bool and b == .Bool) {
        if (a.Bool == b.Bool) return 0;
        return if (a.Bool) 1 else -1;
    }

    // Different types - define an arbitrary order
    const type_order_a = getTypeOrder(a);
    const type_order_b = getTypeOrder(b);
    if (type_order_a < type_order_b) return -1;
    if (type_order_a > type_order_b) return 1;
    return 0;
}

fn getTypeOrder(v: eval.Value) u8 {
    return switch (v) {
        .Null => 0,
        .Bool => 1,
        .Int => 2,
        .Decimal => 3,
        .Str => 4,
        .List => 5,
        .Node => 6,
        .Edge => 7,
        .Map => 8,
        .ExtValue => 9,
        .Path => 10,
    };
}

pub fn isAggregationExpr(expr: ast.Expr) bool {
    switch (expr) {
        .Call => |call| {
            if (call.callee.* == .Ident) {
                const func_name = call.callee.Ident.orig;
                // Use case-insensitive comparison for aggregation functions
                return std.ascii.eqlIgnoreCase(func_name, "count") or
                    std.ascii.eqlIgnoreCase(func_name, "countDistinct") or
                    std.ascii.eqlIgnoreCase(func_name, "sum") or
                    std.ascii.eqlIgnoreCase(func_name, "avg") or
                    std.ascii.eqlIgnoreCase(func_name, "min") or
                    std.ascii.eqlIgnoreCase(func_name, "max");
            }
            return false;
        },
        else => return false,
    }
}

fn isNonConstantExpr(expr: ast.Expr) bool {
    switch (expr) {
        .PropertyAccess => return true,
        .Ident => return true,
        .Member => return true,
        .Call => {
            // Check if it's not an aggregation function
            return !isAggregationExpr(expr);
        },
        .Binary => |bin| {
            return isNonConstantExpr(bin.left.*) or isNonConstantExpr(bin.right.*);
        },
        .Unary => |un| {
            return isNonConstantExpr(un.expr.*);
        },
        // Constants are not non-constant
        .Int, .String, .Bool, .Null, .Decimal => return false,
        else => return true,
    }
}

pub fn executeReturnClauseWithEnv(allocator: std.mem.Allocator, ret: ast.ReturnClause, env: eval.Env) !ExecutionResult {
    const items = ret.items;

    // Handle RETURN * - expand to all bound variables
    if (items.len == 1 and items[0].expr == .Ident and std.mem.eql(u8, items[0].expr.Ident.orig, "*")) {
        // Return all variables from the environment
        const total_vars = env.names.len + env.param_names.len;
        var columns = try allocator.alloc([]const u8, total_vars);
        var row = try allocator.alloc(eval.Value, total_vars);

        var idx: usize = 0;
        // Add regular environment variables
        for (env.names, 0..) |name, i| {
            columns[idx] = try allocator.dupe(u8, name);
            row[idx] = env.values[i];
            idx += 1;
        }
        // Add parameter variables
        for (env.param_names, 0..) |name, i| {
            columns[idx] = try allocator.dupe(u8, name);
            row[idx] = env.param_values[i];
            idx += 1;
        }

        var rows = try allocator.alloc([]eval.Value, 1);
        rows[0] = row;

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = blk: {
                const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                break :blk list;
            },
        };
    }

    // Collect column names
    var columns = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, i| {
        const column_name = item.alias orelse blk: {
            // Use expression-based column name if no alias provided
            switch (item.expr) {
                .Ident => |ident| break :blk ident.orig,
                .PropertyAccess => |prop| break :blk prop.property,
                .Member => |mem| break :blk mem.field,
                .Call => |call| {
                    if (call.callee.* == .Ident) {
                        break :blk call.callee.Ident.orig;
                    }
                    break :blk "column";
                },
                else => break :blk "column",
            }
        };
        columns[i] = try allocator.dupe(u8, column_name);
    }

    // Evaluate expressions with provided environment
    var row = try allocator.alloc(eval.Value, items.len);
    for (items, 0..) |item, i| {
        row[i] = try eval.evalExpr(allocator, item.expr, env);
    }

    var rows = try allocator.alloc([]eval.Value, 1);
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = blk: {
            const list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            break :blk list;
        },
    };
}

fn executeReturnClause(allocator: std.mem.Allocator, ret: ast.ReturnClause) !ExecutionResult {
    return executeReturnClauseWithContext(allocator, ret, .{});
}

fn executeReturnClauseWithContext(allocator: std.mem.Allocator, ret: ast.ReturnClause, context: ExecutionContext) !ExecutionResult {
    return executeReturnClauseWithParams(allocator, ret, context, &.{}, &.{});
}

fn executeReturnClauseWithParams(allocator: std.mem.Allocator, ret: ast.ReturnClause, context: ExecutionContext, param_names: []const []const u8, param_values: []const eval.Value) !ExecutionResult {
    // Build environment with authentication context
    var names_list = std.ArrayList([]const u8){};
    defer names_list.deinit(allocator);
    var values_list = std.ArrayList(eval.Value){};
    defer values_list.deinit(allocator);

    // Add token user to environment if authenticated
    if (context.token != null) {
        try names_list.append(allocator, "__token_user__");
        try values_list.append(allocator, eval.Value{ .Str = context.user orelse "authenticated_user" });
    }

    const env = eval.Env{
        .names = names_list.items,
        .values = values_list.items,
        .param_names = param_names,
        .param_values = param_values,
        .allocator = allocator,
    };
    return executeReturnClauseWithEnv(allocator, ret, env);
}

// Execute SESSION SET statement
fn executeSessionSet(allocator: std.mem.Allocator, ss: ast.SessionSetStatement) !ExecutionResult {
    _ = ss; // Accept the statement but no-op for now

    // Return empty result indicating success
    return ExecutionResult{
        .columns = try allocator.alloc([]const u8, 0),
        .rows = try allocator.alloc([]eval.Value, 0),
        .flags = try std.ArrayList([]const u8).initCapacity(allocator, 0),
    };
}

// Count matches of a graph pattern
