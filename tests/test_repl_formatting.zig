const std = @import("std");
const testing = std.testing;

// Mock types to match the REPL structure
const Format = enum { table, csv, json };

// Include the formatting functions from repl_dispatch.zig
fn formatQueryResult(writer: anytype, allocator: std.mem.Allocator, response: []const u8, format: Format) !void {
    switch (format) {
        .json => {
            // JSON format - output as-is
            try writer.writeAll(response);
        },
        .csv => {
            // CSV format - simple implementation
            try formatResultAsCsv(writer, allocator, response);
        },
        .table => {
            // Table format - simple implementation
            try formatResultAsTable(writer, allocator, response);
        },
    }
}

fn formatResultAsCsv(writer: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    // Parse JSON and convert to simple CSV
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try writer.writeAll(response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("data")) |data_value| {
            const columns = columns_value.array;
            const rows = data_value.array;

            // Header
            for (columns.items, 0..) |col, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.writeAll("\"");
                try writer.writeAll(col.string);
                try writer.writeAll("\"");
            }
            try writer.writeAll("\n");

            // Data rows
            for (rows.items) |row| {
                const row_array = row.array;
                for (row_array.items, 0..) |cell, i| {
                    if (i > 0) try writer.writeAll(",");
                    switch (cell) {
                        .string => |s| {
                            try writer.writeAll("\"");
                            try writer.writeAll(s);
                            try writer.writeAll("\"");
                        },
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                            try writer.writeAll(str);
                        },
                        .float => |f| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
                            try writer.writeAll(str);
                        },
                        .bool => |b| {
                            try writer.writeAll(if (b) "true" else "false");
                        },
                        .null => {
                            try writer.writeAll("NULL");
                        },
                        else => {},
                    }
                }
                try writer.writeAll("\n");
            }
            return;
        }
    }

    // Fallback: output as-is
    try writer.writeAll(response);
}

fn formatResultAsTable(writer: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    // Parse JSON and convert to simple table
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try writer.writeAll(response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("data")) |data_value| {
            const columns = columns_value.array;
            const rows = data_value.array;

            // Calculate column widths
            var col_widths = try allocator.alloc(usize, columns.items.len);
            defer allocator.free(col_widths);

            for (columns.items, 0..) |col, i| {
                col_widths[i] = col.string.len;
            }

            for (rows.items) |row| {
                const row_array = row.array;
                for (row_array.items, 0..) |cell, i| {
                    if (i >= col_widths.len) continue;
                    const width: usize = switch (cell) {
                        .string => |s| s.len,
                        .integer => 10, // rough estimate
                        .float => 10, // rough estimate
                        .bool => 5,
                        .null => 4,
                        else => 0,
                    };
                    col_widths[i] = @max(col_widths[i], width);
                }
            }

            // Print header
            try writer.writeAll("| ");
            for (columns.items, 0..) |col, i| {
                try writer.writeAll(col.string);
                const padding = col_widths[i] - col.string.len;
                for (0..padding) |_| try writer.writeAll(" ");
                try writer.writeAll(" | ");
            }
            try writer.writeAll("\n");

            // Print separator
            try writer.writeAll("|");
            for (col_widths) |width| {
                try writer.writeAll("-");
                for (0..width) |_| try writer.writeAll("-");
                try writer.writeAll("-|");
            }
            try writer.writeAll("\n");

            // Print data rows
            for (rows.items) |row| {
                try writer.writeAll("| ");
                const row_array = row.array;
                for (row_array.items, 0..) |cell, i| {
                    if (i >= col_widths.len) continue;
                    var printed_len: usize = 0;
                    switch (cell) {
                        .string => |s| {
                            try writer.writeAll(s);
                            printed_len = s.len;
                        },
                        .integer => |n| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                            try writer.writeAll(str);
                            printed_len = str.len;
                        },
                        .float => |f| {
                            var buf: [32]u8 = undefined;
                            const str = try std.fmt.bufPrint(&buf, "{d}", .{f});
                            try writer.writeAll(str);
                            printed_len = str.len;
                        },
                        .bool => |b| {
                            const str = if (b) "true" else "false";
                            try writer.writeAll(str);
                            printed_len = str.len;
                        },
                        .null => {
                            try writer.writeAll("NULL");
                            printed_len = 4;
                        },
                        else => {},
                    }
                    const padding = col_widths[i] - printed_len;
                    for (0..padding) |_| try writer.writeAll(" ");
                    try writer.writeAll(" | ");
                }
                try writer.writeAll("\n");
            }
            return;
        }
    }

    // Fallback: output as-is
    try writer.writeAll(response);
}

// Unit Tests

test "JSON format output - single column" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"columns\":[\"name\"],\"data\":[[\"Alice\"]]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .json);

    try testing.expectEqualStrings(response, output.items);
}

test "CSV format output - single column" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"columns\":[\"name\"],\"data\":[[\"Alice\"]]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .csv);

    const expected = "\"name\"\n\"Alice\"\n";
    try testing.expectEqualStrings(expected, output.items);
}

test "CSV format output - multiple columns and rows" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"columns\":[\"name\",\"age\"],\"data\":[[\"Alice\",30],[\"Bob\",25]]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .csv);

    const expected = "\"name\",\"age\"\n\"Alice\",30\n\"Bob\",25\n";
    try testing.expectEqualStrings(expected, output.items);
}

test "CSV format output - mixed data types" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"columns\":[\"name\",\"age\",\"active\",\"score\"],\"data\":[[\"Alice\",30,true,95.5],[\"Bob\",null,false,87.2]]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .csv);

    const expected = "\"name\",\"age\",\"active\",\"score\"\n\"Alice\",30,true,95.5\n\"Bob\",NULL,false,87.2\n";
    try testing.expectEqualStrings(expected, output.items);
}

test "Table format output - single column" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"columns\":[\"name\"],\"data\":[[\"Alice\"]]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .table);

    // Check for key table components rather than exact formatting
    try testing.expect(std.mem.indexOf(u8, output.items, "| name") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "| Alice") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "|---") != null);
}

test "Table format output - multiple columns" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"columns\":[\"name\",\"age\"],\"data\":[[\"Alice\",30],[\"Bob\",25]]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .table);

    // Note: Table output has dynamic column sizing, so we check for key components
    try testing.expect(std.mem.indexOf(u8, output.items, "| name") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "| age") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "| Alice") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "| Bob") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "|---") != null);
}

test "Malformed JSON fallback" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{invalid json";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .csv);

    // Should fallback to raw output
    try testing.expectEqualStrings(response, output.items);
}

test "Missing columns field fallback" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"data\":[[\"Alice\"]]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .csv);

    // Should fallback to raw output
    try testing.expectEqualStrings(response, output.items);
}

test "Missing data field fallback" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"columns\":[\"name\"]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .csv);

    // Should fallback to raw output
    try testing.expectEqualStrings(response, output.items);
}

test "Status message format detection" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"status\":\"success\",\"message\":\"Transaction committed\"}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .csv);

    // Should output as-is for status messages
    try testing.expectEqualStrings(response, output.items);
}

test "Empty data array" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"columns\":[\"name\"],\"data\":[]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .csv);

    const expected = "\"name\"\n";
    try testing.expectEqualStrings(expected, output.items);
}

test "Multiple columns with varying widths" {
    var output = std.ArrayList(u8).initCapacity(testing.allocator, 0) catch unreachable;
    defer output.deinit(testing.allocator);

    const response = "{\"columns\":[\"id\",\"name\",\"description\"],\"data\":[[1,\"Alice\",\"Short\"],[2,\"Bob\",\"A much longer description\"]]}";
    try formatQueryResult(output.writer(testing.allocator), testing.allocator, response, .table);

    // Check that all content is present and properly formatted
    try testing.expect(std.mem.indexOf(u8, output.items, "Alice") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "A much longer description") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "| id") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "| name") != null);
    try testing.expect(std.mem.indexOf(u8, output.items, "| description") != null);
}
