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
        // CANARY: REQ=REQ-SONNY-6586-PARAM-JSON-NO-LEAK; FEATURE="CliOptions"; ASPECT=ParamConversionFreesOnFailure; STATUS=TESTED; TEST=tests/test_sonny6586_param_json_alloc.zig; OWNER=cli; UPDATED=2026-11-15
        // SONNY-6586: a list or map that fails part-way (an allocation, or
        // an element nested past PARAM_MAX_DEPTH) frees what it built.
        .array => |arr| blk: {
            var list: schema.ListValue = .{ .values = .empty };
            errdefer list.deinit(allocator);
            try list.values.ensureTotalCapacityPrecise(allocator, arr.items.len);
            for (arr.items) |item| list.values.appendAssumeCapacity(try jsonToProtoValue(allocator, item, depth + 1));
            break :blk .{ .kind = .{ .list_val = list } };
        },
        .object => |obj| blk: {
            var map: schema.MapValue = .{ .entries = .empty };
            errdefer map.deinit(allocator);
            try map.entries.ensureTotalCapacityPrecise(allocator, obj.count());
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const val = try jsonToProtoValue(allocator, entry.value_ptr.*, depth + 1);
                map.entries.appendAssumeCapacity(.{ .key = key, .value = val });
            }
            break :blk .{ .kind = .{ .map_val = map } };
        },
    };
}
