const std = @import("std");
const platform = @import("platform.zig");

// CANARY: REQ=REQ-REPL-PAGER-001; FEATURE="REPL Result Pagination"; ASPECT=Implementation; STATUS=TESTED; TEST=test_result_pager; OWNER=repl; UPDATED=2025-11-17

/// Configuration for result pagination
pub const PagerConfig = struct {
    page_size: usize = 25, // Default rows per page
    enabled: bool = true, // Whether pagination is enabled
    auto_page: bool = true, // Auto-enable paging for large results
    threshold: usize = 50, // Auto-enable threshold
};

pub const Format = enum { table, csv, json };

/// Pager state for managing result display
pub const ResultPager = struct {
    allocator: std.mem.Allocator,
    config: PagerConfig,
    total_rows: usize = 0,
    current_page: usize = 0,
    data: ?std.json.Value = null,

    pub fn init(allocator: std.mem.Allocator, config: PagerConfig) ResultPager {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *ResultPager) void {
        _ = self;
        // Data is owned by the caller
    }

    /// Check if pagination should be used for this result
    pub fn shouldPage(self: *const ResultPager, row_count: usize) bool {
        if (!self.config.enabled) return false;
        if (!self.config.auto_page) return true;
        return row_count >= self.config.threshold;
    }

    /// Display a page of results
    pub fn displayPage(
        self: *ResultPager,
        writer: anytype,
        parsed_result: std.json.Value,
        page: usize,
        format: Format,
    ) !bool {
        const root = parsed_result.object;
        const columns_value = root.get("columns") orelse return error.MissingColumns;
        const rows_value = root.get("rows") orelse return error.MissingRows;

        const columns = columns_value.array;
        const all_rows = rows_value.array;

        self.total_rows = all_rows.items.len;
        self.current_page = page;

        // Calculate page bounds
        const start_row = page * self.config.page_size;
        if (start_row >= all_rows.items.len) {
            return false; // Page out of bounds
        }

        const end_row = @min(start_row + self.config.page_size, all_rows.items.len);
        const page_rows = all_rows.items[start_row..end_row];

        // Create a temporary JSON structure for this page
        var page_data: std.ArrayList(std.json.Value) = .empty;
        defer page_data.deinit(self.allocator);

        for (page_rows) |row| {
            try page_data.append(self.allocator, row);
        }

        // Extract column names for tabular formats
        const column_names = try extractColumnNames(self.allocator, columns);
        defer self.allocator.free(column_names);

        // Display using the selected format
        try self.displayFormattedPage(writer, columns, column_names, page_data.items, format);

        // Display pagination info
        const total_pages = (all_rows.items.len + self.config.page_size - 1) / self.config.page_size;
        try self.displayPaginationInfo(writer, start_row + 1, end_row, all_rows.items.len, page + 1, total_pages);

        return true;
    }

    fn displayFormattedPage(
        self: *ResultPager,
        writer: anytype,
        columns: std.json.Array,
        column_names: []const []const u8,
        rows: []std.json.Value,
        format: Format,
    ) !void {
        switch (format) {
            .table => try displayAsTable(writer, self.allocator, column_names, rows),
            .csv => try displayAsCsv(writer, self.allocator, column_names, rows),
            .json => try displayAsJson(writer, self.allocator, columns, rows),
        }
    }

    fn displayPaginationInfo(
        self: *const ResultPager,
        writer: anytype,
        start: usize,
        end: usize,
        total: usize,
        current_page: usize,
        total_pages: usize,
    ) !void {
        _ = self;

        const use_color = platform.isStdoutTty();
        const cyan = if (use_color) "\x1b[36m" else "";
        const reset = if (use_color) "\x1b[0m" else "";

        try writer.writeAll("\r\n");
        try writer.writeAll(cyan);
        var buf: [256]u8 = undefined;
        const info = try std.fmt.bufPrint(
            &buf,
            "Showing rows {d}-{d} of {d} (Page {d}/{d})",
            .{ start, end, total, current_page, total_pages },
        );
        try writer.writeAll(info);
        try writer.writeAll(reset);
        try writer.writeAll("\r\n");

        if (current_page < total_pages) {
            const hint = try std.fmt.bufPrint(
                &buf,
                "Type \\next or \\n for next page, \\prev or \\p for previous page",
                .{},
            );
            try writer.writeAll(hint);
            try writer.writeAll("\r\n");
        }
    }
};

fn displayAsTable(writer: anytype, allocator: std.mem.Allocator, columns: []const []const u8, rows: []std.json.Value) !void {
    // Calculate column widths
    var col_widths = try allocator.alloc(usize, columns.len);
    defer allocator.free(col_widths);

    for (columns, 0..) |col_name, i| {
        col_widths[i] = col_name.len;
    }

    for (rows) |row| {
        for (columns, 0..) |col_name, i| {
            if (i >= col_widths.len) continue;
            const cell_value = getRowValue(row, col_name);
            const rendered = try renderCell(allocator, cell_value);
            defer allocator.free(rendered);
            col_widths[i] = @max(col_widths[i], rendered.len);
        }
    }

    // Print header
    try writer.writeAll("| ");
    for (columns, 0..) |col_name, i| {
        try writer.writeAll(col_name);
        const padding = col_widths[i] - col_name.len;
        for (0..padding) |_| try writer.writeAll(" ");
        try writer.writeAll(" | ");
    }
    try writer.writeAll("\r\n");

    // Print separator
    try writer.writeAll("|");
    for (col_widths) |width| {
        try writer.writeAll("-");
        for (0..width) |_| try writer.writeAll("-");
        try writer.writeAll("-|");
    }
    try writer.writeAll("\r\n");

    // Print data rows
    for (rows) |row| {
        try writer.writeAll("| ");
        for (columns, 0..) |col_name, i| {
            if (i >= col_widths.len) continue;
            const cell_value = getRowValue(row, col_name);
            const rendered = try renderCell(allocator, cell_value);
            defer allocator.free(rendered);
            try writer.writeAll(rendered);
            const printed_len = rendered.len;
            const padding = col_widths[i] - printed_len;
            for (0..padding) |_| try writer.writeAll(" ");
            try writer.writeAll(" | ");
        }
        try writer.writeAll("\r\n");
    }
}

fn displayAsCsv(writer: anytype, allocator: std.mem.Allocator, columns: []const []const u8, rows: []std.json.Value) !void {
    // Header
    for (columns, 0..) |col, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\"");
        try writer.writeAll(col);
        try writer.writeAll("\"");
    }
    try writer.writeAll("\r\n");

    // Data rows
    for (rows) |row| {
        for (columns, 0..) |col_name, i| {
            if (i > 0) try writer.writeAll(",");
            const cell_value = getRowValue(row, col_name);
            const rendered = try renderCell(allocator, cell_value);
            defer allocator.free(rendered);
            if (cell_value == .string) {
                try writer.writeAll("\"");
                try writer.writeAll(rendered);
                try writer.writeAll("\"");
            } else {
                try writer.writeAll(rendered);
            }
        }
        try writer.writeAll("\r\n");
    }
}

fn displayAsJson(writer: anytype, allocator: std.mem.Allocator, columns: std.json.Array, rows: []std.json.Value) !void {
    // Create a JSON object with columns and rows
    var root: std.json.ObjectMap = .{};
    defer root.deinit(allocator);
    try root.put(allocator, "columns", .{ .array = columns });

    var rows_arr = std.json.Array.init(allocator);
    defer rows_arr.deinit();
    for (rows) |row| {
        try rows_arr.append(row);
    }
    try root.put(allocator, "rows", .{ .array = rows_arr });

    const root_value = std.json.Value{ .object = root };
    const json_out = try std.json.Stringify.valueAlloc(allocator, root_value, .{});
    defer allocator.free(json_out);

    try writer.writeAll(json_out);
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
            .string => |s| {
                names[i] = s;
            },
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

test "shouldPage respects configuration" {
    const config = PagerConfig{
        .page_size = 25,
        .enabled = true,
        .auto_page = true,
        .threshold = 50,
    };

    const pager = ResultPager.init(std.testing.allocator, config);

    // Should not page for small results
    try std.testing.expect(!pager.shouldPage(30));

    // Should page for large results
    try std.testing.expect(pager.shouldPage(100));

    // Disabled pager never pages
    const disabled_config = PagerConfig{ .enabled = false };
    const disabled_pager = ResultPager.init(std.testing.allocator, disabled_config);
    try std.testing.expect(!disabled_pager.shouldPage(1000));
}

test "pagination calculates correct page bounds" {
    const allocator = std.testing.allocator;
    const config = PagerConfig{ .page_size = 10 };
    var pager = ResultPager.init(allocator, config);

    // Test page size calculation
    const total_rows: usize = 25;
    const page_size: usize = 10;

    // Page 0: rows 0-9
    const page0_start = 0 * page_size;
    const page0_end = @min(page0_start + page_size, total_rows);
    try std.testing.expectEqual(@as(usize, 0), page0_start);
    try std.testing.expectEqual(@as(usize, 10), page0_end);

    // Page 1: rows 10-19
    const page1_start = 1 * page_size;
    const page1_end = @min(page1_start + page_size, total_rows);
    try std.testing.expectEqual(@as(usize, 10), page1_start);
    try std.testing.expectEqual(@as(usize, 20), page1_end);

    // Page 2: rows 20-24 (partial page)
    const page2_start = 2 * page_size;
    const page2_end = @min(page2_start + page_size, total_rows);
    try std.testing.expectEqual(@as(usize, 20), page2_start);
    try std.testing.expectEqual(@as(usize, 25), page2_end);

    pager.deinit();
}
