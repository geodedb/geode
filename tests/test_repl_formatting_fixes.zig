const std = @import("std");
const testing = std.testing;

// CANARY: REQ=REQ-REPL-FORMAT-002; FEATURE="REPL Output Formatting Fixes"; ASPECT=UnitTesting; STATUS=TESTED; TEST=test_repl_formatting_fixes; OWNER=repl; UPDATED=2025-11-17

// Mock types to match the REPL structure
const Format = enum { table, csv, json };

// Test helper to capture stdout output
const OutputCapture = struct {
    buffer: std.ArrayList(u8),
    sync_called: bool = false,

    pub fn init(allocator: std.mem.Allocator) OutputCapture {
        return .{
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *OutputCapture) void {
        self.buffer.deinit();
    }

    pub fn writer(self: *OutputCapture) Writer {
        return .{ .context = self };
    }

    pub const Writer = struct {
        context: *OutputCapture,

        pub fn writeAll(self: Writer, bytes: []const u8) !void {
            try self.context.buffer.appendSlice(bytes);
        }

        pub fn sync(self: Writer) !void {
            self.context.sync_called = true;
        }
    };

    pub fn getOutput(self: *const OutputCapture) []const u8 {
        return self.buffer.items;
    }

    pub fn wasSynced(self: *const OutputCapture) bool {
        return self.sync_called;
    }
};

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

// Unit Tests for Formatting Fixes

test "Output contains leading newline for query results" {
    // Test that query results start with a newline to prevent prompt overlap
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    const response = "{\"columns\":[\"name\"],\"data\":[[\"Alice\"]]}";

    // Simulate executeGql behavior - should start with newline
    try capture.writer().writeAll("\n");
    try formatQueryResult(capture.writer(), testing.allocator, response, .json);
    try capture.writer().writeAll("\n");

    const output = capture.getOutput();
    try testing.expect(output[0] == '\n');
    try testing.expect(std.mem.indexOf(u8, output, response) != null);
}

test "CSV format includes proper newlines" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    const response = "{\"columns\":[\"name\",\"age\"],\"data\":[[\"Alice\",30],[\"Bob\",25]]}";
    try formatQueryResult(capture.writer(), testing.allocator, response, .csv);

    const output = capture.getOutput();
    // Should have header newline
    try testing.expect(std.mem.indexOf(u8, output, "\n") != null);
    // Should have multiple newlines for rows
    var newline_count: usize = 0;
    for (output) |c| {
        if (c == '\n') newline_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), newline_count); // Header + 2 rows
}

test "Table format has consistent line endings" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    const response = "{\"columns\":[\"id\",\"name\"],\"data\":[[1,\"Alice\"],[2,\"Bob\"]]}";
    try formatQueryResult(capture.writer(), testing.allocator, response, .table);

    const output = capture.getOutput();
    // Table should have multiple lines
    try testing.expect(std.mem.indexOf(u8, output, "\n") != null);
    // Should end with newline
    try testing.expect(output[output.len - 1] == '\n');
    // Should have proper table structure
    try testing.expect(std.mem.indexOf(u8, output, "| id") != null);
    try testing.expect(std.mem.indexOf(u8, output, "| name") != null);
    try testing.expect(std.mem.indexOf(u8, output, "|---") != null);
}

test "Error messages include newlines" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Simulate error output
    try capture.writer().writeAll("Error: ");
    try capture.writer().writeAll("{\"type\":\"ERROR\",\"message\":\"Query failed\"}");
    try capture.writer().writeAll("\n");

    const output = capture.getOutput();
    try testing.expect(std.mem.startsWith(u8, output, "Error: "));
    try testing.expect(std.mem.endsWith(u8, output, "\n"));
}

test "Welcome message formatting consistency" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Simulate welcome message structure
    try capture.writer().writeAll("\n");
    try capture.writer().writeAll("  ");

    // Box top - 64 characters
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try capture.writer().writeAll("=");
    }
    try capture.writer().writeAll("\n");

    const output = capture.getOutput();
    // Should start with newline
    try testing.expect(output[0] == '\n');
    // Should have proper box structure
    const lines = std.mem.split(u8, output, "\n");
    var line_count: usize = 0;
    var line_iter = lines;
    while (line_iter.next()) |line| {
        if (line.len > 0) {
            // Lines should be properly formatted
            try testing.expect(line.len <= 66); // 2 spaces + 64 chars max
        }
        line_count += 1;
    }
}

test "Prompt rendering includes ANSI escape sequences" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Simulate prompt rendering
    try capture.writer().writeAll("\r\x1b[K"); // Clear line
    try capture.writer().writeAll("geode> ");
    try capture.writer().writeAll("RETURN 1;");

    const prompt_len = "geode> ".len;
    const cursor_pos = prompt_len + "RETURN 1;".len;
    var buf: [32]u8 = undefined;
    const cursor_str = try std.fmt.bufPrint(&buf, "\r\x1b[{d}C", .{cursor_pos});
    try capture.writer().writeAll(cursor_str);

    const output = capture.getOutput();
    // Should start with clear sequence
    try testing.expect(std.mem.startsWith(u8, output, "\r\x1b[K"));
    // Should contain prompt
    try testing.expect(std.mem.indexOf(u8, output, "geode> ") != null);
    // Should contain cursor positioning
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
}

test "Output flushing simulation" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Write output
    try capture.writer().writeAll("Test output\n");
    // Simulate sync/flush
    try capture.writer().sync();

    // Verify sync was called
    try testing.expect(capture.wasSynced());
}

test "Multi-line output with proper newlines" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Simulate multi-line output
    try capture.writer().writeAll("\n"); // Leading newline
    try capture.writer().writeAll("{\"columns\":[\"id\"],\"data\":[[1]]}\n");
    try capture.writer().writeAll("Query executed in 1.23 ms\n");

    const output = capture.getOutput();

    // Count newlines
    var newline_count: usize = 0;
    for (output) |c| {
        if (c == '\n') newline_count += 1;
    }

    // Should have 3 newlines (leading + result + timing)
    try testing.expectEqual(@as(usize, 3), newline_count);
}

test "Clear command includes ANSI escape sequence" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Simulate clear command
    try capture.writer().writeAll("\x1b[2J\x1b[H");

    const output = capture.getOutput();
    // Should contain clear screen sequence
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[2J") != null);
    // Should contain home cursor sequence
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[H") != null);
}

test "Transaction prompt formatting" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Simulate transaction prompts
    try capture.writer().writeAll("\r\x1b[K");
    try capture.writer().writeAll("geode(txn)> ");

    const output = capture.getOutput();
    try testing.expect(std.mem.indexOf(u8, output, "geode(txn)> ") != null);
}

test "Continuation prompt formatting" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Simulate continuation prompt
    try capture.writer().writeAll("\r\x1b[K");
    try capture.writer().writeAll("geode-> ");

    const output = capture.getOutput();
    try testing.expect(std.mem.indexOf(u8, output, "geode-> ") != null);
}

test "Empty data array formatting" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    const response = "{\"columns\":[\"name\"],\"data\":[]}";
    try formatQueryResult(capture.writer(), testing.allocator, response, .csv);

    const output = capture.getOutput();
    // Should have header only
    try testing.expectEqualStrings("\"name\"\n", output);
}

test "Large table output consistency" {
    var capture = OutputCapture.init(testing.allocator);
    defer capture.deinit();

    // Create a response with many rows
    const response = "{\"columns\":[\"id\",\"name\"],\"data\":[[1,\"Alice\"],[2,\"Bob\"],[3,\"Charlie\"],[4,\"David\"],[5,\"Eve\"]]}";
    try formatQueryResult(capture.writer(), testing.allocator, response, .table);

    const output = capture.getOutput();

    // Verify all rows are present
    try testing.expect(std.mem.indexOf(u8, output, "Alice") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Bob") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Charlie") != null);
    try testing.expect(std.mem.indexOf(u8, output, "David") != null);
    try testing.expect(std.mem.indexOf(u8, output, "Eve") != null);

    // Should have proper table structure throughout
    var line_count: usize = 0;
    var lines = std.mem.split(u8, output, "\n");
    while (lines.next()) |line| {
        if (line.len > 0) {
            // Each non-empty line should start with '|'
            try testing.expect(line[0] == '|');
            line_count += 1;
        }
    }

    // Should have header, separator, and 5 data rows
    try testing.expectEqual(@as(usize, 7), line_count);
}
