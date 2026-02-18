const std = @import("std");

/// Maximum allowed nesting depth for JSONB documents.
/// Protects against stack-overflow DoS from deeply nested input (GAP-0436).
// CANARY: REQ=GAP-0436; FEATURE="JsonbDepthGuard"; ASPECT=SECURITY; STATUS=TESTED; OWNER=security; UPDATED=2026-02-18
pub const MAX_JSONB_DEPTH: u32 = 64;

fn checkDepth(value: std.json.Value, depth: u32) error{TooDeep}!void {
    if (depth > MAX_JSONB_DEPTH) return error.TooDeep;
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                try checkDepth(entry.value_ptr.*, depth + 1);
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                try checkDepth(item, depth + 1);
            }
        },
        else => {},
    }
}

pub const JsonbValue = union(enum) {
    null: void,
    bool: bool,
    number: f64,
    string: []const u8,
    array: []JsonbValue,
    object: []JsonbKeyValue,

    pub const JsonbKeyValue = struct {
        key: []const u8,
        value: JsonbValue,
    };
};

pub const JsonbDocument = struct {
    data: []const u8,
    allocator: std.mem.Allocator,

    pub const Error = error{
        InvalidJson,
        OutOfMemory,
    };

    pub fn fromString(allocator: std.mem.Allocator, json_str: []const u8) Error!JsonbDocument {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return Error.InvalidJson;
        defer parsed.deinit();

        // GAP-0436: Reject deeply nested documents to prevent stack-overflow DoS
        checkDepth(parsed.value, 0) catch return Error.InvalidJson;

        const canonical = try canonicalize(allocator, parsed.value);
        return JsonbDocument{ .data = canonical, .allocator = allocator };
    }

    pub fn get(self: JsonbDocument, path: []const u8) ?JsonbValue {
        if (!std.mem.startsWith(u8, path, "$.")) return null;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, self.data, .{}) catch return null;
        defer parsed.deinit();

        var current = &parsed.value;
        var path_parts = std.mem.splitScalar(u8, path[2..], '.');

        while (path_parts.next()) |part| {
            switch (current.*) {
                .object => |*obj| {
                    current = obj.getPtr(part) orelse return null;
                },
                .array => |*arr| {
                    const index = std.fmt.parseInt(usize, part, 10) catch return null;
                    if (index >= arr.items.len) return null;
                    current = &arr.items[index];
                },
                else => return null,
            }
        }

        // P2-3: Pass allocator to jsonValueToJsonb
        return jsonValueToJsonb(self.allocator, current.*);
    }

    pub fn exists(self: JsonbDocument, key: []const u8) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, self.data, .{}) catch return false;
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |obj| return obj.get(key) != null,
            else => return false,
        }
    }

    pub fn set(self: JsonbDocument, allocator: std.mem.Allocator, path: []const u8, value: JsonbValue) Error!JsonbDocument {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, self.data, .{}) catch return Error.InvalidJson;
        defer parsed.deinit();

        try setAtPath(&parsed.value, path, value);
        const new_canonical = try canonicalize(allocator, parsed.value);
        return JsonbDocument{ .data = new_canonical, .allocator = allocator };
    }

    fn setAtPath(json_val: *std.json.Value, path: []const u8, value: JsonbValue) Error!void {
        _ = json_val;
        _ = path;
        _ = value;
        return Error.InvalidJson;
    }

    fn canonicalize(allocator: std.mem.Allocator, value: std.json.Value) Error![]u8 {
        var result = std.ArrayList(u8).initCapacity(allocator, 256) catch return Error.OutOfMemory;
        errdefer result.deinit(allocator);

        const writer = result.writer(allocator);
        // P2-3: Pass allocator to canonicalizeValue for temporary allocations
        try canonicalizeValue(allocator, writer, value);
        return result.toOwnedSlice(allocator);
    }

    /// P2-3: Now accepts allocator parameter for temporary allocations
    fn canonicalizeValue(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value) Error!void {
        switch (value) {
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try std.fmt.format(writer, "{d}", .{i}),
            .float => |f| try std.fmt.format(writer, "{d}", .{f}),
            .number_string => |ns| try writer.writeAll(ns),
            .string => |s| {
                try writer.writeByte('"');
                for (s) |c| {
                    switch (c) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeByte('"');
            },
            .array => |arr| {
                try writer.writeByte('[');
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(',');
                    try canonicalizeValue(allocator, writer, item);
                }
                try writer.writeByte(']');
            },
            .object => |obj| {
                try writer.writeByte('{');
                // P2-3: Use provided allocator instead of page_allocator
                var keys = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return Error.OutOfMemory;
                defer keys.deinit(allocator);

                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    try keys.append(allocator, entry.key_ptr.*);
                }

                std.sort.insertion([]const u8, keys.items, {}, struct {
                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.lessThan);

                for (keys.items, 0..) |key, i| {
                    if (i > 0) try writer.writeByte(',');
                    try std.fmt.format(writer, "\"{s}\":", .{key});
                    try canonicalizeValue(allocator, writer, obj.get(key).?);
                }
                try writer.writeByte('}');
            },
        }
    }

    /// P2-3: Now accepts allocator parameter for owned slice allocations
    fn jsonValueToJsonb(allocator: std.mem.Allocator, value: std.json.Value) JsonbValue {
        return switch (value) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .integer => |i| .{ .number = @floatFromInt(i) },
            .float => |f| .{ .number = f },
            .number_string => |ns| .{ .number = std.fmt.parseFloat(f64, ns) catch 0.0 },
            .string => |s| .{ .string = s },
            .array => |arr| {
                // P2-3: Use provided allocator instead of page_allocator
                var jsonb_arr = std.ArrayList(JsonbValue).initCapacity(allocator, 0) catch return .{ .array = &.{} };
                for (arr.items) |item| {
                    jsonb_arr.append(allocator, jsonValueToJsonb(allocator, item)) catch {};
                }
                return .{ .array = jsonb_arr.toOwnedSlice(allocator) catch &.{} };
            },
            .object => |obj| {
                // P2-3: Use provided allocator instead of page_allocator
                var jsonb_obj = std.ArrayList(JsonbValue.JsonbKeyValue).initCapacity(allocator, 0) catch return .{ .object = &.{} };
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    jsonb_obj.append(allocator, .{
                        .key = entry.key_ptr.*,
                        .value = jsonValueToJsonb(allocator, entry.value_ptr.*),
                    }) catch {};
                }
                return .{ .object = jsonb_obj.toOwnedSlice(allocator) catch &.{} };
            },
        };
    }

    pub fn deinit(self: JsonbDocument) void {
        self.allocator.free(self.data);
    }
};

test "jsonb canonicalization" {
    const allocator = std.testing.allocator;
    const doc1 = try JsonbDocument.fromString(allocator, "{\"b\":[2,3],\"a\":1}");
    defer doc1.deinit();
    const doc2 = try JsonbDocument.fromString(allocator, "{\"a\":1,\"b\":[2,3]}");
    defer doc2.deinit();

    std.testing.expectEqualSlices(u8, doc1.data, doc2.data) catch unreachable;
}
