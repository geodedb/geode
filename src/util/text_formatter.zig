const std = @import("std");

// Local SchemaCol definition for testing
const SchemaCol = struct { name: []const u8, type: []const u8 };

/// Text formatter for consistent multi-format outputs
pub const TextFormatter = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TextFormatter {
        return .{ .allocator = allocator };
    }
    
    pub fn formatSchema(self: *TextFormatter, cols: []const SchemaCol) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);
        
        const writer = buf.writer(self.allocator);
        
        // Header
        try writer.writeAll("Schema:\n");
        try writer.writeAll("--------\n");
        
        for (cols, 0..) |col, i| {
            try writer.print("{d}. {s} ({s})\n", .{ i + 1, col.name, col.type });
        }
        
        if (cols.len == 0) {
            try writer.writeAll("(no columns)\n");
        }
        
        return buf.toOwnedSlice(self.allocator);
    }
    
    pub fn formatBindings(self: *TextFormatter, rows_json: []const u8, ordered: bool, order_keys: []const []const u8) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);
        
        const writer = buf.writer(self.allocator);
        
        // Parse JSON rows for text formatting
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, rows_json, .{}) catch {
            try writer.writeAll("Error parsing JSON data\n");
            return buf.toOwnedSlice(self.allocator);
        };
        defer parsed.deinit();
        
        if (parsed.value != .array) {
            try writer.writeAll("Invalid data format\n");
            return buf.toOwnedSlice(self.allocator);
        }
        
        const rows = parsed.value.array.items;
        
        // Header info
        if (ordered) {
            try writer.writeAll("Ordered result");
            if (order_keys.len > 0) {
                try writer.writeAll(" (ordered by: ");
                for (order_keys, 0..) |key, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(key);
                }
                try writer.writeAll(")");
            }
            try writer.writeAll("\n");
        } else {
            try writer.writeAll("Unordered result\n");
        }
        
        try writer.print("Rows: {d}\n", .{rows.len});
        try writer.writeAll("--------\n");
        
        if (rows.len == 0) {
            try writer.writeAll("(no rows)\n");
            return buf.toOwnedSlice(self.allocator);
        }
        
        // Extract column names from first row
        var column_names = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer column_names.deinit(self.allocator);
        
        if (rows[0] == .object) {
            var iter = rows[0].object.iterator();
            while (iter.next()) |entry| {
                try column_names.append(self.allocator, entry.key_ptr.*);
            }
        }
        
        // Calculate column widths
        var col_widths = try self.allocator.alloc(usize, column_names.items.len);
        defer self.allocator.free(col_widths);
        
        // Initialize with header widths
        for (column_names.items, 0..) |name, i| {
            col_widths[i] = name.len;
        }
        
        // Check data widths
        for (rows) |row| {
            if (row == .object) {
                for (column_names.items, 0..) |col_name, i| {
                    if (row.object.get(col_name)) |value| {
                        const value_str = try self.jsonValueToString(value);
                        defer self.allocator.free(value_str);
                        col_widths[i] = @max(col_widths[i], value_str.len);
                    }
                }
            }
        }
        
        // Print header
        for (column_names.items, 0..) |name, i| {
            if (i > 0) try writer.writeAll(" | ");
            try writer.print("{s}", .{name});
            
            // Pad to width
            const padding = col_widths[i] - name.len;
            var p: usize = 0;
            while (p < padding) : (p += 1) {
                try writer.writeAll(" ");
            }
        }
        try writer.writeAll("\n");
        
        // Print separator
        for (column_names.items, 0..) |_, i| {
            if (i > 0) try writer.writeAll("-+-");
            var w: usize = 0;
            while (w < col_widths[i]) : (w += 1) {
                try writer.writeAll("-");
            }
        }
        try writer.writeAll("\n");
        
        // Print data rows
        for (rows) |row| {
            if (row == .object) {
                for (column_names.items, 0..) |col_name, i| {
                    if (i > 0) try writer.writeAll(" | ");
                    
                    if (row.object.get(col_name)) |value| {
                        const value_str = try self.jsonValueToString(value);
                        defer self.allocator.free(value_str);
                        try writer.print("{s}", .{value_str});
                        
                        // Pad to width
                        const padding = col_widths[i] - value_str.len;
                        var p: usize = 0;
                        while (p < padding) : (p += 1) {
                            try writer.writeAll(" ");
                        }
                    } else {
                        try writer.writeAll("NULL");
                        const padding = col_widths[i] - 4;
                        var p: usize = 0;
                        while (p < padding) : (p += 1) {
                            try writer.writeAll(" ");
                        }
                    }
                }
                try writer.writeAll("\n");
            }
        }
        
        return buf.toOwnedSlice(self.allocator);
    }
    
    pub fn formatError(self: *TextFormatter, code: []const u8, message: []const u8, anchor: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);
        
        const writer = buf.writer(self.allocator);
        
        try writer.writeAll("ERROR: ");
        try writer.writeAll(message);
        try writer.writeAll("\n");
        try writer.print("Code: {s}\n", .{code});
        
        if (anchor.len > 0) {
            try writer.print("Reference: ISO/IEC 39075 §{s}\n", .{anchor});
        }
        
        return buf.toOwnedSlice(self.allocator);
    }
    
    pub fn formatExplain(self: *TextFormatter, json_payload: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);
        
        const writer = buf.writer(self.allocator);
        
        try writer.writeAll("Query Plan:\n");
        try writer.writeAll("-----------\n");
        
        // Parse and format the explain JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_payload, .{}) catch {
            try writer.writeAll("Error parsing explain data\n");
            return buf.toOwnedSlice(self.allocator);
        };
        defer parsed.deinit();
        
        if (parsed.value == .object) {
            if (parsed.value.object.get("logical")) |logical| {
                if (logical == .array) {
                    for (logical.array.items, 0..) |op, i| {
                        try writer.print("{d}. ", .{i + 1});
                        if (op == .object and op.object.get("op")) |op_name| {
                            if (op_name == .string) {
                                try writer.print("{s}", .{op_name.string});
                                
                                // Add additional details if available
                                if (op.object.get("mode")) |mode| {
                                    if (mode == .string) {
                                        try writer.print(" ({s})", .{mode.string});
                                    }
                                }
                            }
                        }
                        try writer.writeAll("\n");
                    }
                }
            }
            
            // Add properties section
            if (parsed.value.object.get("properties")) |props| {
                try writer.writeAll("\nProperties:\n");
                if (props == .object) {
                    var iter = props.object.iterator();
                    while (iter.next()) |entry| {
                        try writer.print("  {s}: ", .{entry.key_ptr.*});
                        const prop_str = try self.jsonValueToString(entry.value_ptr.*);
                        defer self.allocator.free(prop_str);
                        try writer.print("{s}\n", .{prop_str});
                    }
                }
            }
        }
        
        return buf.toOwnedSlice(self.allocator);
    }
    
    fn jsonValueToString(self: *TextFormatter, value: std.json.Value) ![]u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer buf.deinit(self.allocator);
        
        const writer = buf.writer(self.allocator);
        
        switch (value) {
            .null => try writer.writeAll("NULL"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d:.2}", .{f}),
            .number_string => |s| try writer.writeAll(s),
            .string => |s| try writer.writeAll(s),
            .array => try writer.writeAll("[array]"),
            .object => try writer.writeAll("[object]"),
        }
        
        return buf.toOwnedSlice(self.allocator);
    }
};

test "text formatter schema" {
    var formatter = TextFormatter.init(std.testing.allocator);
    
    const cols = [_]SchemaCol{
        .{ .name = "id", .type = "INT" },
        .{ .name = "name", .type = "STRING" },
    };
    
    const result = try formatter.formatSchema(&cols);
    defer std.testing.allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "Schema:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "id (INT)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "name (STRING)") != null);
}

test "text formatter bindings" {
    var formatter = TextFormatter.init(std.testing.allocator);
    
    const rows_json = "[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}]";
    const order_keys = [_][]const u8{"id"};
    
    const result = try formatter.formatBindings(rows_json, true, &order_keys);
    defer std.testing.allocator.free(result);
    
    try std.testing.expect(std.mem.indexOf(u8, result, "Ordered result") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Bob") != null);
}