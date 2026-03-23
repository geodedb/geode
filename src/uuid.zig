const std = @import("std");
const uuid_lib = @import("uuid");

/// UuidV7 - compatibility wrapper around the external uuid library.
/// Delegates UUID generation and formatting to gitlab.com/devnw/zig/uuid.
pub const UuidV7 = struct {
    bytes: [16]u8,

    const Self = @This();

    /// Generate a new UUIDv7
    pub fn new() Self {
        return .{ .bytes = (uuid_lib.newV7() catch unreachable).bytes };
    }

    /// Create from existing bytes
    pub fn fromBytes(bytes: [16]u8) Self {
        return .{ .bytes = bytes };
    }

    /// Create from hex string
    pub fn fromString(str: []const u8) !Self {
        const u = uuid_lib.UUID.fromString(str) catch return error.InvalidUuidString;
        return .{ .bytes = u.bytes };
    }

    /// Convert to string representation (with hyphens)
    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]u8 {
        return (uuid_lib.UUID{ .bytes = self.bytes }).toStringAlloc(allocator);
    }

    /// Convert to string without allocator (uses a buffer)
    pub fn toStringBuf(self: Self, buf: []u8) ![]u8 {
        if (buf.len < 36) return error.BufferTooSmall;
        const result = (uuid_lib.UUID{ .bytes = self.bytes }).toString(buf[0..36]);
        return result;
    }

    /// Compare for ordering (lexicographical on bytes)
    pub fn compare(self: Self, other: Self) std.math.Order {
        return (uuid_lib.UUID{ .bytes = self.bytes }).order(uuid_lib.UUID{ .bytes = other.bytes });
    }

    /// Check equality
    pub fn eql(self: Self, other: Self) bool {
        return (uuid_lib.UUID{ .bytes = self.bytes }).eql(uuid_lib.UUID{ .bytes = other.bytes });
    }

    /// Get timestamp portion (first 48 bits) as milliseconds since Unix epoch
    pub fn getTimestamp(self: Self) u64 {
        return (@as(u64, self.bytes[0]) << 40) |
            (@as(u64, self.bytes[1]) << 32) |
            (@as(u64, self.bytes[2]) << 24) |
            (@as(u64, self.bytes[3]) << 16) |
            (@as(u64, self.bytes[4]) << 8) |
            @as(u64, self.bytes[5]);
    }

    /// Hash function for use in hash maps
    pub fn hash(self: Self, hasher: anytype) void {
        hasher.update(&self.bytes);
    }

    /// Context for AutoHashMap
    pub const HashContext = struct {
        pub fn hash(_: @This(), key: UuidV7) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&key.bytes);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: UuidV7, b: UuidV7) bool {
            return a.eql(b);
        }
    };

    /// Format function for std.fmt
    pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        var buf: [36]u8 = undefined;
        _ = (uuid_lib.UUID{ .bytes = self.bytes }).toString(&buf);
        try writer.writeAll(&buf);
    }
};

test "UUIDv7 generation" {
    const uuid1 = UuidV7.new();
    const uuid2 = UuidV7.new();
    try std.testing.expect(!uuid1.eql(uuid2));
    try std.testing.expect((uuid1.bytes[6] & 0xF0) == 0x70);
    try std.testing.expect((uuid1.bytes[8] & 0xC0) == 0x80);
}

test "UUIDv7 string conversion" {
    const allocator = std.testing.allocator;
    const u = UuidV7.new();
    const str = try u.toString(allocator);
    defer allocator.free(str);
    try std.testing.expectEqual(@as(usize, 36), str.len);
    const parsed = try UuidV7.fromString(str);
    try std.testing.expect(u.eql(parsed));
}
