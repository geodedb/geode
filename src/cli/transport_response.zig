const std = @import("std");

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
                    var obj = std.json.ObjectMap.init(alloc);
                    try obj.put("name", .{ .string = try alloc.dupe(u8, col.name) });
                    try obj.put("type", .{ .string = try alloc.dupe(u8, col.type) });
                    try arr.append(.{ .object = obj });
                }
                return arr;
            }
        }.apply;

        var root = std.json.ObjectMap.init(jalloc);
        if (view.has_error) {
            try root.put("status_class", .{ .string = try jalloc.dupe(u8, view.error_status) });
            if (view.error_status.len > 0) {
                try root.put("error_code", .{ .string = try jalloc.dupe(u8, view.error_status) });
            }
            try root.put("error", .{ .string = try jalloc.dupe(u8, view.error_message) });
        } else if (view.result_kind != .rows) {
            try root.put("status_class", .{ .string = try jalloc.dupe(u8, view.status_class) });
            if (view.status_subclass.len > 0) {
                try root.put("status_subclass", .{ .string = try jalloc.dupe(u8, view.status_subclass) });
            }
            if (view.result_payload) |payload| {
                if (std.json.parseFromSlice(std.json.Value, jalloc, payload, .{})) |parsed| {
                    if (view.result_kind == .explain) {
                        try root.put("explain", parsed.value);
                    } else {
                        try root.put("profile", parsed.value);
                    }
                } else |_| {
                    if (view.result_kind == .explain) {
                        try root.put("explain", .{ .string = try jalloc.dupe(u8, payload) });
                    } else {
                        try root.put("profile", .{ .string = try jalloc.dupe(u8, payload) });
                    }
                }
            }
        } else {
            try root.put("status_class", .{ .string = try jalloc.dupe(u8, view.status_class) });
            if (view.status_subclass.len > 0) {
                try root.put("status_subclass", .{ .string = try jalloc.dupe(u8, view.status_subclass) });
            }
            try root.put("ordered", .{ .bool = view.ordered });
            try root.put("order_keys", .{ .array = try buildStringArray(jalloc, view.order_keys) });
            try root.put("columns", .{ .array = try buildColumnsArray(jalloc, view.columns) });

            var rows_arr = std.json.Array.init(jalloc);
            if (rows_json) |rows| {
                for (rows.items) |row| {
                    var row_obj = std.json.ObjectMap.init(jalloc);
                    for (row.items, 0..) |val, col_idx| {
                        const col_name = if (col_idx < view.columns.len) view.columns[col_idx].name else "?";
                        try row_obj.put(try jalloc.dupe(u8, col_name), val);
                    }
                    try rows_arr.append(.{ .object = row_obj });
                }
            }
            try root.put("rows", .{ .array = rows_arr });
        }

        try root.put("additional_statuses", .{ .array = try buildStringArray(jalloc, view.additional_statuses) });
        try root.put("flagger_findings", .{ .array = try buildStringArray(jalloc, view.flagger_findings) });

        const root_value = std.json.Value{ .object = root };
        const json_out = try std.json.Stringify.valueAlloc(jalloc, root_value, .{});
        try stdout.writeAll(json_out);
        try stdout.writeAll("\n");
        return view.has_error or (view.status_class.len >= 2 and !std.mem.startsWith(u8, view.status_class, "00"));
    }

    if (view.has_error) {
        if (view.error_message.len > 0) {
            try stderr.writeAll("Error: ");
            try stderr.writeAll(view.error_message);
            try stderr.writeAll("\n");
        } else if (view.error_status.len > 0) {
            try stderr.writeAll("Error (");
            try stderr.writeAll(view.error_status);
            try stderr.writeAll(")\n");
        }
        return true;
    }

    if (view.status_class.len >= 2 and !std.mem.startsWith(u8, view.status_class, "00")) {
        try stderr.writeAll("Error (");
        try stderr.writeAll(view.status_class);
        try stderr.writeAll(")\n");
        return true;
    }

    if (view.result_kind != .rows) {
        if (view.result_payload) |payload| {
            try stdout.writeAll(payload);
            if (payload.len == 0 or payload[payload.len - 1] != '\n') {
                try stdout.writeAll("\n");
            }
        }
        return false;
    }

    if (std.mem.eql(u8, format, "csv")) {
        if (rows_text) |rows| {
            // CSV header
            for (view.columns, 0..) |col, i| {
                if (i > 0) _ = stdout.writeAll(",") catch {};
                _ = stdout.writeAll(col.name) catch {};
            }
            _ = stdout.writeAll("\n") catch {};
            // CSV rows
            for (rows.items) |row| {
                for (row.items, 0..) |cell, i| {
                    if (i > 0) _ = stdout.writeAll(",") catch {};
                    // Quote fields containing comma, newline, or quote
                    if (std.mem.indexOf(u8, cell, ",") != null or std.mem.indexOf(u8, cell, "\n") != null or std.mem.indexOf(u8, cell, "\"") != null) {
                        _ = stdout.writeAll("\"") catch {};
                        for (cell) |c| {
                            if (c == '"') {
                                _ = stdout.writeAll("\"\"") catch {};
                            } else {
                                _ = stdout.write(&[_]u8{c}) catch {};
                            }
                        }
                        _ = stdout.writeAll("\"") catch {};
                    } else {
                        _ = stdout.writeAll(cell) catch {};
                    }
                }
                _ = stdout.writeAll("\n") catch {};
            }
        }
        return false;
    }

    if (std.mem.eql(u8, format, "table")) {
        // PostgreSQL-style table format with borders
        if (rows_text) |rows| {
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
                fn f(out: anytype, widths: []const usize) void {
                    _ = out.writeAll("+") catch {};
                    for (widths) |w| {
                        for (0..w + 2) |_| _ = out.writeAll("-") catch {};
                        _ = out.writeAll("+") catch {};
                    }
                    _ = out.writeAll("\n") catch {};
                }
            }.f;

            printSeparator(stdout, col_widths.items);

            _ = stdout.writeAll("|") catch {};
            for (view.columns, 0..) |col, i| {
                _ = stdout.writeAll(" ") catch {};
                _ = stdout.writeAll(col.name) catch {};
                const width = if (i < col_widths.items.len) col_widths.items[i] else col.name.len;
                for (col.name.len..width) |_| _ = stdout.writeAll(" ") catch {};
                _ = stdout.writeAll(" |") catch {};
            }
            _ = stdout.writeAll("\n") catch {};

            printSeparator(stdout, col_widths.items);

            for (rows.items) |row| {
                _ = stdout.writeAll("|") catch {};
                for (row.items, 0..) |cell, i| {
                    _ = stdout.writeAll(" ") catch {};
                    _ = stdout.writeAll(cell) catch {};
                    const width = if (i < col_widths.items.len) col_widths.items[i] else cell.len;
                    for (cell.len..width) |_| _ = stdout.writeAll(" ") catch {};
                    _ = stdout.writeAll(" |") catch {};
                }
                _ = stdout.writeAll("\n") catch {};
            }

            printSeparator(stdout, col_widths.items);

            const row_count = rows.items.len;
            if (row_count == 1) {
                _ = stdout.writeAll("(1 row)\n") catch {};
            } else {
                const count_str = std.fmt.allocPrint(allocator, "({d} rows)\n", .{row_count}) catch "(? rows)\n";
                defer if (count_str.len > 0 and count_str[0] == '(') allocator.free(count_str);
                _ = stdout.writeAll(count_str) catch {};
            }
        }
    }
    return false;
}
