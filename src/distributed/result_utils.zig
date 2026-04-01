const std = @import("std");
const protocol = @import("../protocol.zig");
const value_utilities = @import("../execution/value_utilities.zig");

/// Deep-clone a binding row, duplicating each column value.
pub fn cloneBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) !protocol.BindingRow {
    var cols = try allocator.alloc(protocol.BindingValue, row.cols.len);
    errdefer {
        for (cols) |val| value_utilities.freeValue(allocator, val);
        allocator.free(cols);
    }
    for (row.cols, 0..) |val, i| {
        cols[i] = try value_utilities.duplicateValue(allocator, val);
    }
    return .{ .cols = cols };
}

/// Free all column values in a binding row and release the column slice.
pub fn freeBindingRow(allocator: std.mem.Allocator, row: protocol.BindingRow) void {
    for (row.cols) |val| {
        value_utilities.freeValue(allocator, val);
    }
    if (row.cols.len > 0) allocator.free(row.cols);
}

/// Deep-clone a schema definition slice, duplicating name and data_type strings.
pub fn cloneSchema(allocator: std.mem.Allocator, schema_defs: []const protocol.ColumnDef) ![]const protocol.ColumnDef {
    var cols = try allocator.alloc(protocol.ColumnDef, schema_defs.len);
    errdefer {
        for (cols) |col| {
            allocator.free(col.name);
            allocator.free(col.data_type);
        }
        allocator.free(cols);
    }
    for (schema_defs, 0..) |col, i| {
        cols[i] = .{
            .name = try allocator.dupe(u8, col.name),
            .data_type = try allocator.dupe(u8, col.data_type),
        };
    }
    return cols;
}

/// Free all name/data_type strings in a schema definition slice and release the slice.
pub fn freeSchema(allocator: std.mem.Allocator, schema_defs: []const protocol.ColumnDef) void {
    for (schema_defs) |col| {
        allocator.free(col.name);
        allocator.free(col.data_type);
    }
    allocator.free(schema_defs);
}
