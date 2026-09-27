const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const value_types = @import("../value_types.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;

// Local type aliases
const Value = value_types.Value;

// CANARY: REQ=REQ-EXEC-REFACTOR-006; FEATURE="ExecutionRefactoring"; ASPECT=EXECUTION_HELPERS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-12
// Extracted helper/utility functions from path_and_call_operations.zig for better modularity (M2.3 Phase 2)

/// Extract u32 value from map properties by key
/// Returns default value if key not found or value is not an integer
pub fn extractU32FromMap(map_props: []ast.Property, key: []const u8, default: u32) u32 {
    for (map_props) |prop| {
        if (std.mem.eql(u8, prop.key, key)) {
            if (prop.value.* == .Int) {
                // SONNY-2769: past u32 the cast aborted the server; a negative
                // value is the default, a larger one u32's maximum.
                const v = prop.value.Int;
                return std.math.cast(u32, v) orelse if (v < 0) default else std.math.maxInt(u32);
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
        // SONNY-2769: a negative id is no node (the cast aborted the server).
        return std.math.cast(u64, arg.Int);
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

/// SONNY-2755: the result column a YIELD item names: its alias, or else the
/// identifier or property it projects.
fn yieldColumnName(item: ast.ReturnItem) []const u8 {
    return item.alias orelse switch (item.expr) {
        .Ident => |ident| ident.orig,
        .Member => |member| member.field,
        else => "column",
    };
}

// CANARY: REQ=REQ-SONNY-2755-YIELD-COLUMNS; FEATURE="ProcedureYield"; ASPECT=DistinctYieldNames; STATUS=TESTED; TEST=tests/test_sonny2755_yield_duplicate_columns.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2755: refuse a YIELD that names one column twice (`YIELD path,
/// path`, or `YIELD a, b AS a`) with `error.DuplicateYieldColumn` (42702).
/// `procedure_registry.executeCallProcedure` checks this before a procedure
/// runs, so a procedure that changes something is not run by a statement
/// that then fails.
pub fn requireDistinctYieldNames(yield_items: []const ast.ReturnItem) error{DuplicateYieldColumn}!void {
    for (yield_items, 0..) |item, i| {
        const name = yieldColumnName(item);
        for (yield_items[0..i]) |earlier| {
            if (std.mem.eql(u8, yieldColumnName(earlier), name)) return error.DuplicateYieldColumn;
        }
    }
}

// CANARY: REQ=REQ-SONNY-2755-YIELD-COLUMNS; FEATURE="ProcedureYield"; ASPECT=FilterYieldColumns; STATUS=TESTED; TEST=tests/test_sonny2755_yield_duplicate_columns.zig; OWNER=security; UPDATED=2026-09-25
/// Keep the result columns a YIELD names, in the YIELD's order. A name that
/// is not a result column is dropped. Takes ownership of `result`: the
/// returned result holds what is kept, what is not is freed, and on an error
/// `result` is freed.
///
/// SONNY-2755:
/// - A YIELD that names a column twice is refused (`requireDistinctYieldNames`).
///   It used to put that column's name, and each of its values, in two
///   columns, and `ExecutionResult.deinit` freed both copies. That double
///   free aborts the server (release builds use the C allocator), and any
///   user who may call a procedure could reach it.
/// - The result keeps `result`'s ownership: `owns_value_memory`,
///   `free_value`, `column_buffer`, the flags, the bindings and the owned
///   entities. It used to own no values, so every allocated value it kept
///   leaked (a BFS path per row).
/// - The dropped columns' names are freed, and so are their values when
///   `result` owns them. The names used to leak.
pub fn filterYieldColumns(allocator: std.mem.Allocator, result: ExecutionResult, yield_items: []ast.ReturnItem) !ExecutionResult {
    var source = result;
    errdefer source.deinit(allocator);
    try requireDistinctYieldNames(yield_items);

    // kept.items[k]: the source column of output column k.
    var kept = try std.ArrayList(usize).initCapacity(allocator, yield_items.len);
    defer kept.deinit(allocator);
    for (yield_items) |item| {
        const name = yieldColumnName(item);
        for (source.columns, 0..) |column, idx| {
            if (!std.mem.eql(u8, name, column)) continue;
            // Distinct names pick distinct columns; a column in the result
            // twice would be freed twice all the same.
            if (std.mem.indexOfScalar(usize, kept.items, idx) == null) kept.appendAssumeCapacity(idx);
            break;
        }
    }

    const new_columns = try allocator.alloc([]const u8, kept.items.len);
    errdefer allocator.free(new_columns);
    const new_rows = try allocator.alloc([]Value, source.rows.len);
    errdefer allocator.free(new_rows);
    var built: usize = 0;
    errdefer for (new_rows[0..built]) |row| allocator.free(row);
    for (source.rows) |row| {
        const new_row = try allocator.alloc(Value, kept.items.len);
        for (kept.items, 0..) |src, k| new_row[k] = if (src < row.len) row[src] else .{ .Null = {} };
        new_rows[built] = new_row;
        built += 1;
    }

    // Nothing below fails: move what is kept, free what is not.
    for (kept.items, 0..) |src, k| new_columns[k] = source.columns[src];
    const free_value = source.free_value orelse &execution.freeValue;
    for (source.columns, 0..) |column, idx| {
        if (std.mem.indexOfScalar(usize, kept.items, idx) != null) continue;
        if (source.column_buffer == null) allocator.free(column);
        if (!source.owns_value_memory) continue;
        for (source.rows) |row| {
            if (idx < row.len) free_value(allocator, row[idx]);
        }
    }
    allocator.free(source.columns);
    for (source.rows) |row| allocator.free(row);
    allocator.free(source.rows);

    var filtered = source;
    filtered.columns = new_columns;
    filtered.rows = new_rows;
    return filtered;
}
