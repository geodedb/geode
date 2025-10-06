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
        
        try writer.writeAll("{\"columns\":[");
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
        try writer.writeAll("]}");
        
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
            // For now, try to execute the return clause of a query
            const ret = q.ret;
            return executeReturnClause(allocator, ret);
        },
        else => return error.NotImplemented,
    }
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