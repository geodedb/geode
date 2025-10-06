const std = @import("std");
const ast = @import("gql/ast.zig");
const eval = @import("eval.zig");

pub const ExecutionError = error{
    OutOfMemory,
    NotImplemented,
    InvalidStatement,
    TypeMismatch,
    DivisionByZero,
    Unsupported,
};

pub const ExecutionResult = struct {
    columns: [][]const u8,
    rows: [][]eval.Value,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExecutionResult) void {
        for (self.columns) |col| {
            self.allocator.free(col);
        }
        self.allocator.free(self.columns);
        
        for (self.rows) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
    }

    pub fn toJson(self: ExecutionResult, allocator: std.mem.Allocator) ![]u8 {
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
                try writeValue(writer, val);
            }
            try writer.writeByte(']');
        }
        // Add empty flagger_findings array for now
        try writer.writeAll("],\"flagger_findings\":[]}");
        
        return result.toOwnedSlice(allocator);
    }
};

fn writeValue(writer: anytype, value: eval.Value) !void {
    switch (value) {
        .Null => try writer.writeAll("null"),
        .Int => |n| try writer.print("{d}", .{n}),
        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .Str => |s| {
            try writer.writeByte('"');
            // TODO: Proper JSON escaping
            try writer.writeAll(s);
            try writer.writeByte('"');
        },
        .Decimal => |d| {
            // TODO: Proper decimal formatting
            try writer.print("{d}", .{d.coeff});
        },
        .List => |list| {
            try writer.writeByte('[');
            for (list, 0..) |item, i| {
                if (i > 0) try writer.writeAll(",");
                try writeValue(writer, item);
            }
            try writer.writeByte(']');
        },
    }
}

pub fn executeProgram(allocator: std.mem.Allocator, program: *const ast.Program) !ExecutionResult {
    if (program.statements.len == 0) {
        return ExecutionResult{
            .columns = try allocator.alloc([]const u8, 0),
            .rows = try allocator.alloc([]eval.Value, 0),
            .allocator = allocator,
        };
    }

    const stmt = program.statements[0];
    
    switch (stmt) {
        .Query => |q| {
            // Check if query has SKIP or LIMIT
            var result = try executeQuery(allocator, q);
            
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
            return executeUnion(allocator, u);
        },
        .Create => |_| {
            // CREATE support not yet implemented
            return error.NotImplemented;
        },
        .Delete => |_| {
            // DELETE support not yet implemented
            return error.NotImplemented;
        },
        .Merge => |_| {
            // MERGE support not yet implemented
            return error.NotImplemented;
        },
        .StartTransaction, .Commit, .Rollback => {
            // Transaction support not yet implemented
            return error.NotImplemented;
        },
        .SessionSet => |_| {
            // Session management not yet implemented
            return error.NotImplemented;
        },
        else => return error.NotImplemented,
    }
}

fn executeQuery(allocator: std.mem.Allocator, q: ast.Query) !ExecutionResult {
    // Execute the return clause
    var result = try executeReturnClause(allocator, q.ret);
    
    // Apply ORDER BY if present
    if (q.order_by) |order| {
        try sortRows(allocator, &result, order);
    }
    
    return result;
}

fn executeUnion(allocator: std.mem.Allocator, union_query: ast.UnionQuery) !ExecutionResult {
    // Execute first query (but don't apply its limit/offset yet)
    var result = try executeQueryNoLimit(allocator, union_query.first);
    
    // Keep track of the last query for limit/offset
    var last_query = union_query.first;
    
    // Execute and append results from tail queries
    for (union_query.tails) |part| {
        last_query = part.query;
        
        if (part.all) {
            // UNION ALL - append all rows
            const part_result = try executeQueryNoLimit(allocator, part.query);
            defer {
                // Free part result structure but keep the row data
                allocator.free(part_result.columns);
                allocator.free(part_result.rows);
            }
            
            // Append rows to result
            const old_rows = result.rows;
            result.rows = try allocator.alloc([]eval.Value, old_rows.len + part_result.rows.len);
            
            // Copy old rows
            for (old_rows, 0..) |row, i| {
                result.rows[i] = row;
            }
            
            // Copy new rows
            for (part_result.rows, 0..) |row, i| {
                // Need to duplicate the row data
                const new_row = try allocator.alloc(eval.Value, row.len);
                for (row, 0..) |val, j| {
                    new_row[j] = val;
                }
                result.rows[old_rows.len + i] = new_row;
            }
            
            allocator.free(old_rows);
        } else {
            // UNION DISTINCT - would need deduplication
            return error.NotImplemented;
        }
    }
    
    // Apply ORDER BY from the last query to the entire result
    if (last_query.order_by) |order| {
        try sortRows(allocator, &result, order);
    }
    
    // Apply SKIP and LIMIT from the LAST query in the union (applies to entire result)
    if (last_query.offset) |skip_count| {
        if (skip_count < result.rows.len) {
            const new_rows = try allocator.alloc([]eval.Value, result.rows.len - skip_count);
            for (result.rows[skip_count..], 0..) |row, i| {
                new_rows[i] = row;
            }
            allocator.free(result.rows);
            result.rows = new_rows;
        } else {
            allocator.free(result.rows);
            result.rows = try allocator.alloc([]eval.Value, 0);
        }
    }
    
    if (last_query.limit) |limit_count| {
        if (limit_count < result.rows.len) {
            const new_rows = try allocator.alloc([]eval.Value, limit_count);
            for (result.rows[0..limit_count], 0..) |row, i| {
                new_rows[i] = row;
            }
            allocator.free(result.rows);
            result.rows = new_rows;
        }
    }
    
    return result;
}

fn executeQueryNoLimit(allocator: std.mem.Allocator, q: ast.Query) !ExecutionResult {
    // Execute query without applying limit/offset
    const ret = q.ret;
    return executeReturnClause(allocator, ret);
}

fn sortRows(allocator: std.mem.Allocator, result: *ExecutionResult, order: ast.OrderBy) !void {
    _ = allocator; // TODO: Will be used for ORDER BY expression evaluation
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
                // For now, just compare based on the first column value
                // TODO: Properly evaluate ORDER BY expressions
                const val1 = result.rows[i][0];
                const val2 = result.rows[i + 1][0];
                
                const cmp = compareValues(val1, val2);
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
    // Compare values for sorting
    // Returns: -1 if a < b, 0 if a == b, 1 if a > b
    
    // Handle nulls first
    if (a == .Null and b == .Null) return 0;
    if (a == .Null) return -1;
    if (b == .Null) return 1;
    
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
    };
}

fn executeReturnClause(allocator: std.mem.Allocator, ret: ast.ReturnClause) !ExecutionResult {
    const items = ret.items;
    
    // Collect column names
    var columns = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, i| {
        const name = item.alias orelse "column";
        columns[i] = try allocator.dupe(u8, name);
    }
    
    // Evaluate expressions
    var row = try allocator.alloc(eval.Value, items.len);
    const env = eval.Env{
        .names = &.{},
        .values = &.{},
    };
    
    for (items, 0..) |item, i| {
        row[i] = try eval.evalExpr(allocator, item.expr, env);
    }
    
    var rows = try allocator.alloc([]eval.Value, 1);
    rows[0] = row;
    
    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .allocator = allocator,
    };
}