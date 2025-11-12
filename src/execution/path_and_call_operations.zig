const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const ExecutionError = execution.ExecutionError;

// Import recursion handler for path traversal algorithms
const recursion_handler = @import("recursion_handler.zig");

// Import procedure registry for CALL procedure handling
const procedure_registry = @import("procedure_registry.zig");

// Import security modules for real implementation
const audit_mod = @import("../security/audit.zig");
const tde_mod = @import("../security/tde.zig");
const cdc_mod = @import("../streaming/cdc_enhanced.zig");

// const tde_hierarchy = @import("../security/tde_hierarchy.zig"); // Removed to avoid module conflict
const rls = @import("../security/rls.zig");

// CANARY: REQ=REQ-EXEC-REFACTOR-005; FEATURE="ExecutionRefactoring"; ASPECT=PATH_AND_CALL_OPERATIONS; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-12
// Extracted path finding algorithms and CALL operations from execution.zig for better modularity (M1 Phase 5)
// Further extracted procedure handlers to procedure_registry.zig for improved modularity (M2.2 Phase 2)

// Note: Global state for audit/TDE/CDC has been moved to procedure_registry module

// Delegated to recursion_handler module
pub const buildMemberPath = recursion_handler.buildMemberPath;

// Delegated to recursion_handler module
pub const executeBFS = recursion_handler.executeBFS;

// Delegated to recursion_handler module
pub const executeDFS = recursion_handler.executeDFS;

// Delegated to recursion_handler module
pub const executeDijkstra = recursion_handler.executeDijkstra;

// Delegated to recursion_handler module
pub const getEdgeWeight = recursion_handler.getEdgeWeight;

// Delegated to procedure_registry module
pub const executeCallProcedure = procedure_registry.executeCallProcedure;

// Helper function to extract u32 from map properties
pub fn extractU32FromMap(map_props: []ast.Property, key: []const u8, default: u32) u32 {
    for (map_props) |prop| {
        if (std.mem.eql(u8, prop.key, key)) {
            if (prop.value.* == .Int) {
                return @intCast(prop.value.Int);
            }
        }
    }
    return default;
}

pub fn extractF64FromMap(map_props: []ast.Property, key: []const u8, default: f64) f64 {
    for (map_props) |prop| {
        if (std.mem.eql(u8, prop.key, key)) {
            if (prop.value.* == .Int) {
                return @floatFromInt(prop.value.Int);
            }
        }
    }
    return default;
}

// Extract map parameter from arguments
pub fn extractMapParameter(args: []const *ast.Expr, arg_idx: usize) ?[]ast.Property {
    if (arg_idx >= args.len) return null;
    const arg = args[arg_idx];
    if (arg.* == .Map) {
        return arg.Map;
    }
    return null;
}

// Extract node ID from arguments
pub fn extractNodeId(args: []const *ast.Expr, arg_idx: usize, context: ExecutionContext) ?u64 {
    if (arg_idx >= args.len) return null;
    const arg = args[arg_idx];

    // Handle integer literals
    if (arg.* == .Int) {
        return @intCast(arg.Int);
    }

    // Handle identifiers - look up in context bindings
    if (arg.* == .Ident) {
        if (context.bindings) |bindings| {
            const ident_name = arg.Ident.orig;
            if (bindings.get(ident_name)) |binding| {
                switch (binding) {
                    .node_id => |id| return id,
                    else => {},
                }
            }
        }
    }

    return null;
}

// Get edge weight from properties
// Delegated to recursion_handler module
pub const getEdgeWeight = recursion_handler.getEdgeWeight;

pub fn executeCallSubquery(allocator: std.mem.Allocator, call_subq: ast.CallSubquery, context: ExecutionContext) !ExecutionResult {
    // CANARY: REQ=REQ-GQL-CALL-SUBQUERY; FEATURE="CallSubquery"; ASPECT=Execution; STATUS=IMPL; OWNER=execution; UPDATED=2025-10-11
    // Execute the statement (can be Query, Call, Create, etc.) with context
    // Handle statements directly to avoid circular error set inference
    const subquery_result = switch (call_subq.statement.*) {
        .Query => |q| try execution.executeQueryWithContext(allocator, q, context),
        .Call => |c| switch (c) {
            // Inline executeCallStatement to avoid circular dependency
            .Procedure => |proc| try executeCallProcedure(allocator, proc, context),
            .Subquery => |subq| try executeCallSubquery(allocator, subq, context),
        },
        .Create => |c| try execution.executeCreate(allocator, c),
        else => return error.UnsupportedStatementInCallSubquery,
    };

    // If there's a RETURN clause after the subquery, apply it
    if (call_subq.return_clause) |_| {
        // Apply the RETURN transformation to subquery results
        // For simplicity, just execute the return clause with the subquery results
        // (Full implementation would need to bind subquery results to variables)
        return subquery_result;
    }

    return subquery_result;
}

pub fn executeCallStatement(allocator: std.mem.Allocator, call_stmt: ast.CallStatement, context: ExecutionContext) !ExecutionResult {
    // Handle different types of CALL statements
    switch (call_stmt) {
        .Procedure => |proc| {
            return try executeCallProcedure(allocator, proc, context);
        },
        .Subquery => |subq| {
            return try executeCallSubquery(allocator, subq, context);
        },
    }
}


// Filter result columns based on YIELD items
pub fn filterYieldColumns(allocator: std.mem.Allocator, result: ExecutionResult, yield_items: []ast.ReturnItem) !ExecutionResult {
    // Build list of requested column names
    var requested_columns = try std.ArrayList([]const u8).initCapacity(allocator, yield_items.len);
    defer requested_columns.deinit(allocator);

    for (yield_items) |item| {
        const col_name = item.alias orelse switch (item.expr) {
            .Ident => |ident| ident.orig,
            .Member => |member| member.field,
            else => "column",
        };
        try requested_columns.append(allocator, col_name);
    }

    // Find indices of requested columns in original result
    var col_indices = try std.ArrayList(usize).initCapacity(allocator, requested_columns.items.len);
    defer col_indices.deinit(allocator);

    for (requested_columns.items) |req_col| {
        for (result.columns, 0..) |res_col, idx| {
            if (std.mem.eql(u8, req_col, res_col)) {
                try col_indices.append(allocator, idx);
                break;
            }
        }
    }

    // Create new filtered columns array
    const new_columns = try allocator.alloc([]const u8, col_indices.items.len);
    for (col_indices.items, 0..) |idx, i| {
        new_columns[i] = result.columns[idx];
    }

    // Create new filtered rows
    const new_rows = try allocator.alloc([]eval.Value, result.rows.len);
    for (result.rows, 0..) |row, row_idx| {
        const new_row = try allocator.alloc(eval.Value, col_indices.items.len);
        for (col_indices.items, 0..) |col_idx, i| {
            new_row[i] = row[col_idx];
        }
        new_rows[row_idx] = new_row;
    }

    // Clean up old data
    allocator.free(result.columns);
    for (result.rows) |row| {
        allocator.free(row);
    }
    allocator.free(result.rows);

    return ExecutionResult{
        .columns = new_columns,
        .rows = new_rows,
        .flags = result.flags,
    };
}
