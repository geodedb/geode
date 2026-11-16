//! `geode query --param <name> <json>`: the JSON value as geode's wire
//! value (lists and maps included). Moved out of src/cli/main.zig.

const std = @import("std");
const schema = @import("schema");

pub const PARAM_MAX_SIZE: usize = 1 * 1024 * 1024; // 1 MB max param payload
pub const PARAM_MAX_DEPTH: usize = 64;

pub fn parseParamValue(allocator: std.mem.Allocator, input: []const u8) !schema.Value {
    if (input.len > PARAM_MAX_SIZE) return error.ParamsTooLarge;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    return jsonToProtoValue(allocator, parsed.value, 0);
}

pub fn jsonToProtoValue(allocator: std.mem.Allocator, value: std.json.Value, depth: usize) !schema.Value {
    if (depth > PARAM_MAX_DEPTH) return error.ParamsTooDeep;
    return switch (value) {
        .null => .{ .kind = .{ .null_val = .{} } },
        .bool => |b| .{ .kind = .{ .bool_val = b } },
        .integer => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .INT } } },
        .float => |f| .{ .kind = .{ .double_val = .{ .value = f, .kind = .DOUBLE } } },
        .number_string => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .string => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .array => |arr| blk: {
            var values = std.ArrayList(schema.Value).initCapacity(allocator, arr.items.len) catch return error.OutOfMemory;
            for (arr.items) |item| {
                try values.append(allocator, try jsonToProtoValue(allocator, item, depth + 1));
            }
            break :blk .{ .kind = .{ .list_val = .{ .values = values } } };
        },
        .object => |obj| blk: {
            var entries = std.ArrayList(schema.MapEntry).initCapacity(allocator, obj.count()) catch return error.OutOfMemory;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try jsonToProtoValue(allocator, entry.value_ptr.*, depth + 1);
                try entries.append(allocator, .{ .key = key, .value = val });
            }
            break :blk .{ .kind = .{ .map_val = .{ .entries = entries } } };
        },
    };
}
