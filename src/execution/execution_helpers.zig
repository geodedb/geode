const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

// CANARY: REQ=REQ-EXEC-REFACTOR-006; FEATURE="ExecutionRefactoring"; ASPECT=EXECUTION_HELPERS; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-12
// Extracted helper/utility functions from path_and_call_operations.zig for better modularity (M2.3 Phase 2)

/// Extract u32 value from map properties by key
/// Returns default value if key not found or value is not an integer
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

/// Extract f64 value from map properties by key
/// Returns default value if key not found or value is not numeric
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

/// Extract map parameter from argument list at specified index
/// Returns null if index out of bounds or argument is not a map
pub fn extractMapParameter(args: []const *ast.Expr, arg_idx: usize) ?[]ast.Property {
    if (arg_idx >= args.len) return null;
    const arg = args[arg_idx];
    if (arg.* == .Map) {
        return arg.Map;
    }
    return null;
}

/// Extract node ID from argument list at specified index
/// Handles both integer literals and identifier lookups in context
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

/// Filter result columns based on YIELD items
/// Creates a new ExecutionResult with only the requested columns
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
    const new_rows = try allocator.alloc([]Value, result.rows.len);
    for (result.rows, 0..) |row, row_idx| {
        const new_row = try allocator.alloc(Value, col_indices.items.len);
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
