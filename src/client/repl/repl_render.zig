const std = @import("std");

pub const Format = enum { table, csv, json };

pub fn RenderSink(comptime Writer: type) type {
    return struct {
        writer: Writer,
        format: Format,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn write(self: *Self, data: []const u8) !void {
            switch (self.format) {
                .json => try renderJson(self.writer, data),
                .csv => try renderCsv(self.writer, self.allocator, data),
                .table => try renderTable(self.writer, self.allocator, data),
            }
        }
    };
}

fn renderJson(writer: anytype, data: []const u8) !void {
    // Simply output JSON as-is
    try writer.print("{s}", .{data});
}

fn renderCsv(writer: anytype, allocator: std.mem.Allocator, data: []const u8) !void {
    // Parse JSON and convert to CSV
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const columns = root.get("columns").?.array;
    const rows = root.get("rows").?.array;
    const column_names = try extractColumnNames(allocator, columns);
    defer allocator.free(column_names);

    // Header
    for (column_names, 0..) |col, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("\"{s}\"", .{col});
    }
    try writer.print("\n", .{});

    // Data rows
    for (rows.items) |row| {
        for (column_names, 0..) |col_name, i| {
            if (i > 0) try writer.print(",", .{});
            const cell = getRowValue(row, col_name);
            const rendered = try renderCell(allocator, cell);
            defer allocator.free(rendered);
            if (cell == .string) {
                try writer.print("\"{s}\"", .{escapeString(rendered)});
            } else {
                try writer.print("{s}", .{rendered});
            }
        }
        try writer.print("\n", .{});
    }
}

fn renderTable(writer: anytype, allocator: std.mem.Allocator, data: []const u8) !void {
    // Parse JSON and render as ASCII table
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const columns = root.get("columns").?.array;
    const rows = root.get("rows").?.array;
    const column_names = try extractColumnNames(allocator, columns);
    defer allocator.free(column_names);

    // Calculate column widths
    var col_widths = try allocator.alloc(usize, column_names.len);
    defer allocator.free(col_widths);

    for (column_names, 0..) |col, i| {
        col_widths[i] = col.len;
    }

    for (rows.items) |row| {
        for (column_names, 0..) |col_name, i| {
            const cell = getRowValue(row, col_name);
            const rendered = try renderCell(allocator, cell);
            defer allocator.free(rendered);
            col_widths[i] = @max(col_widths[i], rendered.len);
        }
    }

    // Print separator
    try writer.print("+", .{});
    for (col_widths) |width| {
        for (0..width + 2) |_| {
            try writer.print("-", .{});
        }
        try writer.print("+", .{});
    }
    try writer.print("\r\n", .{});

    // Print header
    try writer.print("|", .{});
    for (column_names, 0..) |col, i| {
        try writer.print(" {s}", .{col});
        const padding = col_widths[i] -| col.len;
        for (0..padding) |_| try writer.print(" ", .{});
        try writer.print(" |", .{});
    }
    try writer.print("\r\n", .{});

    // Print separator
    try writer.print("+", .{});
    for (col_widths) |width| {
        for (0..width + 2) |_| {
            try writer.print("-", .{});
        }
        try writer.print("+", .{});
    }
    try writer.print("\r\n", .{});

    // Print rows
    for (rows.items) |row| {
        try writer.print("|", .{});
        for (column_names, 0..) |col_name, i| {
            try writer.print(" ", .{});
            const cell = getRowValue(row, col_name);
            const rendered = try renderCell(allocator, cell);
            defer allocator.free(rendered);
            try writer.print("{s}", .{rendered});
            const printed_len: usize = rendered.len;
            const padding = col_widths[i] -| printed_len;
            for (0..padding) |_| try writer.print(" ", .{});
            try writer.print(" |", .{});
        }
        try writer.print("\r\n", .{});
    }

    // Print bottom separator
    try writer.print("+", .{});
    for (col_widths) |width| {
        for (0..width + 2) |_| {
            try writer.print("-", .{});
        }
        try writer.print("+", .{});
    }
    try writer.print("\r\n", .{});
}

fn escapeString(s: []const u8) []const u8 {
    // Simple escape - in production would need proper escaping
    return s;
}

fn extractColumnNames(allocator: std.mem.Allocator, columns: std.json.Array) ![]const []const u8 {
    var names = try allocator.alloc([]const u8, columns.items.len);
    for (columns.items, 0..) |col, i| {
        switch (col) {
            .object => |obj| {
                const name_val = obj.get("name") orelse return error.MissingColumnName;
                if (name_val != .string) return error.InvalidColumnName;
                names[i] = name_val.string;
            },
            .string => |s| names[i] = s,
            else => return error.InvalidColumnName,
        }
    }
    return names;
}

fn getRowValue(row: std.json.Value, column_name: []const u8) std.json.Value {
    if (row == .object) {
        if (row.object.get(column_name)) |val| return val;
    }
    return std.json.Value{ .null = {} };
}

fn renderCell(allocator: std.mem.Allocator, cell: std.json.Value) ![]u8 {
    return switch (cell) {
        .string => |s| allocator.dupe(u8, s),
        .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .null => allocator.dupe(u8, "NULL"),
        else => std.json.Stringify.valueAlloc(allocator, cell, .{}),
    };
}

fn stripAnsi(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var in_escape = false;
    for (text) |c| {
        if (c == 0x1b) {
            in_escape = true;
        } else if (in_escape) {
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                in_escape = false;
            }
        } else {
            try result.append(allocator, c);
        }
    }

    return result.toOwnedSlice();
}

test "renderer JSON mode" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var sink = RenderSink{
        .writer = output.writer(),
        .format = .json,
        .allocator = allocator,
    };

    const data = "{\"columns\":[\"a\"],\"data\":[[1]]}";
    try sink.write(data);

    try std.testing.expectEqualStrings(data, output.items);
}
