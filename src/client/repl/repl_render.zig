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
    const rows = root.get("data").?.array;

    // Header
    for (columns.items, 0..) |col, i| {
        if (i > 0) try writer.print(",", .{});
        try writer.print("\"{s}\"", .{col.string});
    }
    try writer.print("\n", .{});

    // Data rows
    for (rows.items) |row| {
        const row_array = row.array;
        for (row_array.items, 0..) |cell, i| {
            if (i > 0) try writer.print(",", .{});
            switch (cell) {
                .string => |s| try writer.print("\"{s}\"", .{escapeString(s)}),
                .integer => |n| try writer.print("{d}", .{n}),
                .float => |f| try writer.print("{d}", .{f}),
                .bool => |b| try writer.print("{}", .{b}),
                .null => try writer.print("NULL", .{}),
                else => try writer.print("", .{}),
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
    const rows = root.get("data").?.array;

    // Calculate column widths
    var col_widths = try allocator.alloc(usize, columns.items.len);
    defer allocator.free(col_widths);

    for (columns.items, 0..) |col, i| {
        col_widths[i] = col.string.len;
    }

    for (rows.items) |row| {
        const row_array = row.array;
        for (row_array.items, 0..) |cell, i| {
            const width: usize = switch (cell) {
                .string => |s| s.len,
                .integer => blk: {
                    var buf: [32]u8 = undefined;
                    const len = (std.fmt.bufPrint(&buf, "{d}", .{cell.integer}) catch "0").len;
                    break :blk len;
                },
                .float => blk: {
                    var buf: [32]u8 = undefined;
                    const len = (std.fmt.bufPrint(&buf, "{d}", .{cell.float}) catch "0").len;
                    break :blk len;
                },
                .bool => if (cell.bool) 4 else 5,
                .null => 4,
                else => 0,
            };
            col_widths[i] = @max(col_widths[i], width);
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
    try writer.print("\n", .{});

    // Print header
    try writer.print("|", .{});
    for (columns.items, 0..) |col, i| {
        try writer.print(" {s}", .{col.string});
        const padding = col_widths[i] -| col.string.len;
        for (0..padding) |_| try writer.print(" ", .{});
        try writer.print(" |", .{});
    }
    try writer.print("\n", .{});

    // Print separator
    try writer.print("+", .{});
    for (col_widths) |width| {
        for (0..width + 2) |_| {
            try writer.print("-", .{});
        }
        try writer.print("+", .{});
    }
    try writer.print("\n", .{});

    // Print rows
    for (rows.items) |row| {
        try writer.print("|", .{});
        const row_array = row.array;
        for (row_array.items, 0..) |cell, i| {
            try writer.print(" ", .{});
            const printed_len: usize = switch (cell) {
                .string => |s| blk: {
                    try writer.print("{s}", .{s});
                    break :blk s.len;
                },
                .integer => |n| blk: {
                    var buf: [32]u8 = undefined;
                    const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                    try writer.print("{s}", .{str});
                    break :blk str.len;
                },
                .float => |f| blk: {
                    var buf: [32]u8 = undefined;
                    const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
                    try writer.print("{s}", .{str});
                    break :blk str.len;
                },
                .bool => |b| blk: {
                    const str = if (b) "true" else "false";
                    try writer.print("{s}", .{str});
                    break :blk str.len;
                },
                .null => blk: {
                    try writer.print("NULL", .{});
                    break :blk 4;
                },
                else => 0,
            };
            const padding = col_widths[i] -| printed_len;
            for (0..padding) |_| try writer.print(" ", .{});
            try writer.print(" |", .{});
        }
        try writer.print("\n", .{});
    }

    // Print bottom separator
    try writer.print("+", .{});
    for (col_widths) |width| {
        for (0..width + 2) |_| {
            try writer.print("-", .{});
        }
        try writer.print("+", .{});
    }
    try writer.print("\n", .{});
}

fn escapeString(s: []const u8) []const u8 {
    // Simple escape - in production would need proper escaping
    return s;
}

fn stripAnsi(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
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
    var output = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
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
