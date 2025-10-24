const std = @import("std");

pub const UUID = struct {
    bytes: [16]u8,

    pub const Error = error{
        InvalidFormat,
        InvalidLength,
    };

    pub fn fromString(str: []const u8) Error!UUID {
        if (str.len != 36) return Error.InvalidLength;
        if (str[8] != '-' or str[13] != '-' or str[18] != '-' or str[23] != '-') {
            return Error.InvalidFormat;
        }

        var bytes: [16]u8 = undefined;
        var byte_idx: usize = 0;
        var i: usize = 0;

        while (i < str.len and byte_idx < 16) {
            if (str[i] == '-') {
                i += 1;
                continue;
            }

            const hex_pair = str[i .. i + 2];
            bytes[byte_idx] = std.fmt.parseInt(u8, hex_pair, 16) catch return Error.InvalidFormat;
            byte_idx += 1;
            i += 2;
        }

        return UUID{ .bytes = bytes };
    }

    pub fn toString(self: UUID, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3], self.bytes[4], self.bytes[5], self.bytes[6], self.bytes[7], self.bytes[8], self.bytes[9], self.bytes[10], self.bytes[11], self.bytes[12], self.bytes[13], self.bytes[14], self.bytes[15] });
    }

    pub fn v4() UUID {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);

        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;

        return UUID{ .bytes = bytes };
    }

    pub fn v7() UUID {
        var bytes: [16]u8 = undefined;
        const timestamp = std.time.milliTimestamp();

        std.mem.writeInt(u48, bytes[0..6], @intCast(@as(u64, @intCast(timestamp))), .big);

        std.crypto.random.bytes(bytes[6..]);

        bytes[6] = (bytes[6] & 0x0f) | 0x70;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;

        return UUID{ .bytes = bytes };
    }

    pub fn equal(self: UUID, other: UUID) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

test "uuid parsing" {
    const uuid = try UUID.fromString("550e8400-e29b-41d4-a716-446655440000");
    std.testing.expect(uuid.bytes.len == 16) catch unreachable;
}

test "uuid generation" {
    const uuid4 = UUID.v4();
    const uuid7 = UUID.v7();
    std.testing.expect(!UUID.equal(uuid4, uuid7)) catch unreachable;
}
