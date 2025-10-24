const std = @import("std");

pub const BitString = struct {
    bit_length: u32,
    bytes: []u8,

    pub const Error = error{
        InvalidFormat,
        OutOfMemory,
    };

    pub fn fromString(allocator: std.mem.Allocator, str: []const u8) Error!BitString {
        if (str.len < 3 or str[0] != 'B' or str[1] != '\'' or str[str.len - 1] != '\'') {
            return Error.InvalidFormat;
        }

        const bit_str = str[2 .. str.len - 1];
        const bit_length: u32 = @intCast(bit_str.len);
        const byte_length = (bit_length + 7) / 8;

        const bytes = try allocator.alloc(u8, byte_length);
        @memset(bytes, 0);

        for (bit_str, 0..) |c, i| {
            if (c != '0' and c != '1') {
                allocator.free(bytes);
                return Error.InvalidFormat;
            }

            if (c == '1') {
                const byte_idx = i / 8;
                const bit_idx = 7 - (i % 8);
                bytes[byte_idx] |= @as(u8, 1) << @intCast(bit_idx);
            }
        }

        return BitString{ .bit_length = bit_length, .bytes = bytes };
    }

    pub fn toString(self: BitString, allocator: std.mem.Allocator) ![]u8 {
        var result = try allocator.alloc(u8, self.bit_length + 3);
        result[0] = 'B';
        result[1] = '\'';
        result[result.len - 1] = '\'';

        for (0..self.bit_length) |i| {
            const byte_idx = i / 8;
            const bit_idx = 7 - (i % 8);
            const bit = (self.bytes[byte_idx] >> @intCast(bit_idx)) & 1;
            result[i + 2] = if (bit == 1) '1' else '0';
        }

        return result;
    }

    pub fn bitwiseAnd(self: BitString, allocator: std.mem.Allocator, other: BitString) Error!BitString {
        const max_len = @max(self.bit_length, other.bit_length);
        const byte_len = (max_len + 7) / 8;
        const result_bytes = try allocator.alloc(u8, byte_len);
        @memset(result_bytes, 0);

        for (0..byte_len) |i| {
            const self_byte = if (i < self.bytes.len) self.bytes[i] else 0;
            const other_byte = if (i < other.bytes.len) other.bytes[i] else 0;
            result_bytes[i] = self_byte & other_byte;
        }

        return BitString{ .bit_length = max_len, .bytes = result_bytes };
    }

    pub fn bitwiseOr(self: BitString, allocator: std.mem.Allocator, other: BitString) Error!BitString {
        const max_len = @max(self.bit_length, other.bit_length);
        const byte_len = (max_len + 7) / 8;
        const result_bytes = try allocator.alloc(u8, byte_len);

        for (0..byte_len) |i| {
            const self_byte = if (i < self.bytes.len) self.bytes[i] else 0;
            const other_byte = if (i < other.bytes.len) other.bytes[i] else 0;
            result_bytes[i] = self_byte | other_byte;
        }

        return BitString{ .bit_length = max_len, .bytes = result_bytes };
    }

    pub fn popCount(self: BitString) u32 {
        var count: u32 = 0;
        for (0..self.bit_length) |i| {
            const byte_idx = i / 8;
            const bit_idx = 7 - (i % 8);
            const bit = (self.bytes[byte_idx] >> @intCast(bit_idx)) & 1;
            count += bit;
        }
        return count;
    }

    pub fn get(self: BitString, index: usize) ?bool {
        if (index >= self.bit_length) return null;
        const byte_idx = index / 8;
        const bit_idx = 7 - (index % 8);
        const bit = (self.bytes[byte_idx] >> @intCast(bit_idx)) & 1;
        return bit == 1;
    }

    pub fn set(self: *BitString, index: usize, value: bool) bool {
        if (index >= self.bit_length) return false;
        const byte_idx = index / 8;
        const bit_idx = 7 - (index % 8);
        const mask = @as(u8, 1) << @intCast(bit_idx);

        if (value) {
            self.bytes[byte_idx] |= mask;
        } else {
            self.bytes[byte_idx] &= ~mask;
        }
        return true;
    }

    pub fn deinit(self: BitString, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

test "bitstring operations" {
    const allocator = std.testing.allocator;
    const bs1 = try BitString.fromString(allocator, "B'1010'");
    defer bs1.deinit(allocator);
    const bs2 = try BitString.fromString(allocator, "B'1100'");
    defer bs2.deinit(allocator);

    const result = try bs1.bitwiseAnd(allocator, bs2);
    defer result.deinit(allocator);

    const result_str = try result.toString(allocator);
    defer allocator.free(result_str);

    std.testing.expectEqualSlices(u8, result_str, "B'1000'") catch unreachable;
}

test "bit count" {
    const allocator = std.testing.allocator;
    const bs = try BitString.fromString(allocator, "B'11110000'");
    defer bs.deinit(allocator);

    std.testing.expect(bs.popCount() == 4) catch unreachable;
}
