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

// ---- Unit tests ----

test "cloneBindingRow: roundtrip with Int and Str columns" {
    const allocator = std.testing.allocator;

    // Build a source row with a heap-allocated Str so freeValue works correctly.
    const str_val = try allocator.dupe(u8, "hello");
    const orig_cols = [_]protocol.BindingValue{
        .{ .Int = 42 },
        .{ .Str = str_val },
    };
    const orig = protocol.BindingRow{ .cols = &orig_cols };

    const cloned = try cloneBindingRow(allocator, orig);
    defer freeBindingRow(allocator, cloned);

    // Values must match.
    try std.testing.expectEqual(@as(usize, 2), cloned.cols.len);
    try std.testing.expectEqual(protocol.BindingValue{ .Int = 42 }, cloned.cols[0]);
    switch (cloned.cols[1]) {
        .Str => |s| try std.testing.expectEqualStrings("hello", s),
        else => return error.UnexpectedType,
    }

    // Pointer independence: cloned Str must not alias original.
    switch (cloned.cols[1]) {
        .Str => |s| try std.testing.expect(s.ptr != str_val.ptr),
        else => {},
    }

    // Free the original Str (not owned by cloneBindingRow).
    allocator.free(str_val);
}

test "cloneBindingRow: empty row does not crash" {
    const allocator = std.testing.allocator;
    const orig = protocol.BindingRow{ .cols = &.{} };
    const cloned = try cloneBindingRow(allocator, orig);
    defer freeBindingRow(allocator, cloned);
    try std.testing.expectEqual(@as(usize, 0), cloned.cols.len);
}

test "cloneSchema: roundtrip with one ColumnDef" {
    const allocator = std.testing.allocator;

    const orig_defs = [_]protocol.ColumnDef{
        .{ .name = "age", .data_type = "INTEGER" },
    };

    const cloned = try cloneSchema(allocator, &orig_defs);
    defer freeSchema(allocator, cloned);

    try std.testing.expectEqual(@as(usize, 1), cloned.len);
    try std.testing.expectEqualStrings("age", cloned[0].name);
    try std.testing.expectEqualStrings("INTEGER", cloned[0].data_type);

    // Pointer independence.
    try std.testing.expect(cloned[0].name.ptr != orig_defs[0].name.ptr);
    try std.testing.expect(cloned[0].data_type.ptr != orig_defs[0].data_type.ptr);
}

test "freeBindingRow: empty cols does not crash" {
    const allocator = std.testing.allocator;
    // freeBindingRow skips allocator.free when cols.len == 0; verify no crash.
    const row = protocol.BindingRow{ .cols = &.{} };
    freeBindingRow(allocator, row);
}
