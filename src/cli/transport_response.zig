const std = @import("std");

// NOTE: This file uses `catch {}` for stdout/stderr I/O operations.
// Output write failures are non-critical — the query result is correct
// even if display fails.  See docs/FULL_AUDIT_2026_04_07.md.

pub const ColumnInfo = struct {
    name: []const u8,
    type: []const u8,
};

pub const QueryResultKind = enum { rows, explain, profile };

pub const TransportResponseView = struct {
    columns: []const ColumnInfo,
    ordered: bool,
    order_keys: []const []const u8,
    status_class: []const u8,
    status_subclass: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
    has_error: bool,
    error_message: []const u8,
    error_status: []const u8,
    result_kind: QueryResultKind,
    result_payload: ?[]const u8,
};

pub fn renderTransportResponse(
    allocator: std.mem.Allocator,
    stdout: anytype,
    format: []const u8,
    rows_text: ?*std.ArrayList(std.ArrayList([]const u8)),
    rows_json: ?*std.ArrayList(std.ArrayList(std.json.Value)),
    view: TransportResponseView,
) !void {
    _ = try renderTransportResponseWithStreams(allocator, stdout, stdout, format, rows_text, rows_json, view);
}

pub fn renderTransportResponseWithStreams(
    allocator: std.mem.Allocator,
    stdout: anytype,
    stderr: anytype,
    format: []const u8,
    rows_text: ?*std.ArrayList(std.ArrayList([]const u8)),
    rows_json: ?*std.ArrayList(std.ArrayList(std.json.Value)),
    view: TransportResponseView,
) !bool {
    var out = stdout;
    var err_out = stderr;

    if (std.mem.eql(u8, format, "json")) {
        // Use an arena allocator for the JSON tree structure (ObjectMaps, Arrays,
        // duped string keys/values). Row json.Values from protoValueToJson are
        // allocated with the main allocator and freed by the rows_json owner.
        var json_arena = std.heap.ArenaAllocator.init(allocator);
        defer json_arena.deinit();
        const jalloc = json_arena.allocator();

        const buildStringArray = struct {
            fn apply(alloc: std.mem.Allocator, items: []const []const u8) !std.json.Array {
                var arr = std.json.Array.init(alloc);
                for (items) |item| {
                    try arr.append(.{ .string = try alloc.dupe(u8, item) });
                }
                return arr;
            }
        }.apply;

        const buildColumnsArray = struct {
            fn apply(alloc: std.mem.Allocator, cols: []const ColumnInfo) !std.json.Array {
                var arr = std.json.Array.init(alloc);
                for (cols) |col| {
                    var obj = @as(std.json.ObjectMap, .empty);
                    try obj.put(alloc, "name", .{ .string = try alloc.dupe(u8, col.name) });
                    try obj.put(alloc, "type", .{ .string = try alloc.dupe(u8, col.type) });
                    try arr.append(.{ .object = obj });
                }
                return arr;
            }
        }.apply;

        var root = @as(std.json.ObjectMap, .empty);
        if (view.has_error) {
            try root.put(jalloc, "status_class", .{ .string = try jalloc.dupe(u8, view.error_status) });
            if (view.error_status.len > 0) {
                try root.put(jalloc, "error_code", .{ .string = try jalloc.dupe(u8, view.error_status) });
            }
            try root.put(jalloc, "error", .{ .string = try jalloc.dupe(u8, view.error_message) });
        } else if (view.result_kind != .rows) {
            try root.put(jalloc, "status_class", .{ .string = try jalloc.dupe(u8, view.status_class) });
            if (view.status_subclass.len > 0) {
                try root.put(jalloc, "status_subclass", .{ .string = try jalloc.dupe(u8, view.status_subclass) });
            }
            if (view.result_payload) |payload| {
                if (std.json.parseFromSlice(std.json.Value, jalloc, payload, .{})) |parsed| {
                    if (view.result_kind == .explain) {
                        try root.put(jalloc, "explain", parsed.value);
                    } else {
                        try root.put(jalloc, "profile", parsed.value);
                    }
                } else |_| {
                    if (view.result_kind == .explain) {
                        try root.put(jalloc, "explain", .{ .string = try jalloc.dupe(u8, payload) });
                    } else {
                        try root.put(jalloc, "profile", .{ .string = try jalloc.dupe(u8, payload) });
                    }
                }
            }
        } else {
            try root.put(jalloc, "status_class", .{ .string = try jalloc.dupe(u8, view.status_class) });
            if (view.status_subclass.len > 0) {
                try root.put(jalloc, "status_subclass", .{ .string = try jalloc.dupe(u8, view.status_subclass) });
            }
            try root.put(jalloc, "ordered", .{ .bool = view.ordered });
            try root.put(jalloc, "order_keys", .{ .array = try buildStringArray(jalloc, view.order_keys) });
            try root.put(jalloc, "columns", .{ .array = try buildColumnsArray(jalloc, view.columns) });

            // Check for duplicate column names (e.g. RETURN a.name, b.name both produce "name")
            var has_dupes = false;
            for (view.columns, 0..) |col, i| {
                if (has_dupes) break;
                for (view.columns[0..i]) |prev| {
                    if (std.mem.eql(u8, col.name, prev.name)) {
                        has_dupes = true;
                        break;
                    }
                }
            }

            // Build unique row-object keys only when duplicates exist.
            // The `columns` array in the output is NOT changed — only row keys are disambiguated.
            var unique_col_keys: ?[][]const u8 = null;
            if (has_dupes) {
                const keys = try jalloc.alloc([]const u8, view.columns.len);
                for (view.columns, 0..) |col, idx| {
                    var occurrence: usize = 0;
                    for (view.columns[0..idx]) |prev| {
                        if (std.mem.eql(u8, prev.name, col.name)) occurrence += 1;
                    }
                    keys[idx] = if (occurrence == 0)
                        try jalloc.dupe(u8, col.name)
                    else
                        try std.fmt.allocPrint(jalloc, "{s}_{d}", .{ col.name, occurrence + 1 });
                }
                unique_col_keys = keys;
            }

            var rows_arr = std.json.Array.init(jalloc);
            if (rows_json) |rows| {
                for (rows.items) |row| {
                    var row_obj = @as(std.json.ObjectMap, .empty);
                    for (row.items, 0..) |val, col_idx| {
                        const col_key = if (unique_col_keys) |keys|
                            (if (col_idx < keys.len) keys[col_idx] else "?")
                        else
                            (if (col_idx < view.columns.len) view.columns[col_idx].name else "?");
                        try row_obj.put(jalloc, try jalloc.dupe(u8, col_key), val);
                    }
                    try rows_arr.append(.{ .object = row_obj });
                }
            }
            try root.put(jalloc, "rows", .{ .array = rows_arr });
        }

        try root.put(jalloc, "additional_statuses", .{ .array = try buildStringArray(jalloc, view.additional_statuses) });
        try root.put(jalloc, "flagger_findings", .{ .array = try buildStringArray(jalloc, view.flagger_findings) });

        const root_value = std.json.Value{ .object = root };
        const json_out = try std.json.Stringify.valueAlloc(jalloc, root_value, .{});
        try out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), json_out);
        try out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n");
        return view.has_error or (view.status_class.len >= 2 and !std.mem.startsWith(u8, view.status_class, "00"));
    }

    if (view.has_error) {
        if (view.error_message.len > 0) {
            try err_out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error: ");
            try err_out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), view.error_message);
            try err_out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\r\n");
        } else if (view.error_status.len > 0) {
            try err_out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error (");
            try err_out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), view.error_status);
            try err_out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), ")\r\n");
        }
        return true;
    }

    if (view.status_class.len >= 2 and !std.mem.startsWith(u8, view.status_class, "00")) {
        try err_out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "Error (");
        try err_out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), view.status_class);
        try err_out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), ")\r\n");
        return true;
    }

    if (view.result_kind != .rows) {
        if (view.result_payload) |payload| {
            try out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), payload);
            if (payload.len == 0 or payload[payload.len - 1] != '\n') {
                try out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\r\n");
            }
        }
        return false;
    }

    if (std.mem.eql(u8, format, "csv")) {
        if (rows_text) |rows| {
            // CSV header
            for (view.columns, 0..) |col, i| {
                if (i > 0) _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), ",") catch {};
                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), col.name) catch {};
            }
            _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n") catch {};
            // CSV rows
            for (rows.items) |row| {
                for (row.items, 0..) |cell, i| {
                    if (i > 0) _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), ",") catch {};
                    // Quote fields containing comma, newline, or quote
                    if (std.mem.indexOf(u8, cell, ",") != null or std.mem.indexOf(u8, cell, "\n") != null or std.mem.indexOf(u8, cell, "\"") != null) {
                        _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\"") catch {};
                        for (cell) |c| {
                            if (c == '"') {
                                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\"\"") catch {};
                            } else {
                                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), &[_]u8{c}) catch {};
                            }
                        }
                        _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\"") catch {};
                    } else {
                        _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), cell) catch {};
                    }
                }
                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\n") catch {};
            }
        }
        return false;
    }

    if (std.mem.eql(u8, format, "table")) {
        // PostgreSQL-style table format with borders
        if (rows_text) |rows| {
            // Skip degenerate table when there are no columns (e.g. USE GRAPH result)
            if (view.columns.len == 0 and rows.items.len == 0) return false;

            var col_widths = try std.ArrayList(usize).initCapacity(allocator, view.columns.len);
            defer col_widths.deinit(allocator);

            for (view.columns) |col| {
                try col_widths.append(allocator, col.name.len);
            }

            // Expand widths based on row data
            for (rows.items) |row| {
                for (row.items, 0..) |cell, i| {
                    if (i < col_widths.items.len) {
                        if (cell.len > col_widths.items[i]) {
                            col_widths.items[i] = cell.len;
                        }
                    }
                }
            }

            const printSeparator = struct {
                fn f(writer: anytype, widths: []const usize) void {
                    var out_writer = writer;
                    const io_ps = std.Io.Threaded.global_single_threaded.io();
                    _ = out_writer.writeStreamingAll(io_ps, "+") catch {};
                    for (widths) |w| {
                        for (0..w + 2) |_| _ = out_writer.writeStreamingAll(io_ps, "-") catch {};
                        _ = out_writer.writeStreamingAll(io_ps, "+") catch {};
                    }
                    _ = out_writer.writeStreamingAll(io_ps, "\r\n") catch {};
                }
            }.f;

            printSeparator(out, col_widths.items);

            _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "|") catch {};
            for (view.columns, 0..) |col, i| {
                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), " ") catch {};
                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), col.name) catch {};
                const width = if (i < col_widths.items.len) col_widths.items[i] else col.name.len;
                for (col.name.len..width) |_| _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), " ") catch {};
                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), " |") catch {};
            }
            _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\r\n") catch {};

            printSeparator(out, col_widths.items);

            for (rows.items) |row| {
                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "|") catch {};
                for (row.items, 0..) |cell, i| {
                    _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), " ") catch {};
                    _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), cell) catch {};
                    const width = if (i < col_widths.items.len) col_widths.items[i] else cell.len;
                    for (cell.len..width) |_| _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), " ") catch {};
                    _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), " |") catch {};
                }
                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\r\n") catch {};
            }

            printSeparator(out, col_widths.items);

            const row_count = rows.items.len;
            if (row_count == 1) {
                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "(1 row)\r\n") catch {};
            } else {
                const count_str = std.fmt.allocPrint(allocator, "({d} rows)\r\n", .{row_count}) catch "(? rows)\r\n";
                defer if (count_str.len > 0 and count_str[0] == '(') allocator.free(count_str);
                _ = out.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), count_str) catch {};
            }
        }
    }
    return false;
}
