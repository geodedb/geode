const std = @import("std");

pub const Value = union(enum) {
    Null: void,
    Bool: bool,
    Int: i64,
    Str: []const u8,
};

pub fn encodeValue(ally: std.mem.Allocator, v: Value) ![]u8 {
    var buf = std.ArrayList(u8).init(ally);
    switch (v) {
        .Null => {
            try buf.append(0x00);
        },
        .Bool => |b| {
            try buf.append(0x01);
            try buf.append(if (b) 1 else 0);
        },
        .Int => |i| {
            try buf.append(0x02);
            var tmp: [8]u8 = undefined;
            std.mem.writeInt(i64, &tmp, i, .little);
            try buf.appendSlice(&tmp);
        },
        .Str => |s| {
            try buf.append(0x03);
            var tmp: [4]u8 = undefined;
            std.mem.writeInt(u32, &tmp, @intCast(s.len), .little);
            try buf.appendSlice(&tmp);
            try buf.appendSlice(s);
        },
    }
    return buf.toOwnedSlice();
}

pub fn decodeValue(ally: std.mem.Allocator, bytes: []const u8) !Value {
    if (bytes.len == 0) return error.Underflow;
    const tag = bytes[0];
    switch (tag) {
        0x00 => return .{ .Null = {} },
        0x01 => {
            if (bytes.len < 2) return error.Underflow;
            return .{ .Bool = (bytes[1] != 0) };
        },
        0x02 => {
            if (bytes.len < 1 + 8) return error.Underflow;
            const i = std.mem.readInt(i64, bytes[1 .. 1 + 8], .little);
            return .{ .Int = i };
        },
        0x03 => {
            if (bytes.len < 1 + 4) return error.Underflow;
            const n = std.mem.readInt(u32, bytes[1..5], .little);
            const nn: usize = @intCast(n);
            if (bytes.len < 5 + nn) return error.Underflow;
            const s = try ally.dupe(u8, bytes[5 .. 5 + nn]);
            return .{ .Str = s };
        },
        else => return error.BadTag,
    }
}
