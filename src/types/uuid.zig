const std = @import("std");
const uuid_lib = @import("uuid");

/// UUID - compatibility wrapper around the external uuid library.
/// Delegates UUID generation and formatting to gitlab.com/devnw/zig/uuid.
pub const UUID = struct {
    bytes: [16]u8,

    pub const Error = error{
        InvalidFormat,
        InvalidLength,
    };

    pub fn fromString(str: []const u8) Error!UUID {
        const u = uuid_lib.UUID.fromString(str) catch |err| {
            return switch (err) {
                uuid_lib.Error.InvalidLength => Error.InvalidLength,
                else => Error.InvalidFormat,
            };
        };
        return UUID{ .bytes = u.bytes };
    }

    pub fn toString(self: UUID, allocator: std.mem.Allocator) ![]u8 {
        return (uuid_lib.UUID{ .bytes = self.bytes }).toStringAlloc(allocator);
    }

    pub fn v4() UUID {
        return .{ .bytes = (uuid_lib.newV4() catch unreachable).bytes };
    }

    pub fn v7() UUID {
        return .{ .bytes = (uuid_lib.newV7() catch unreachable).bytes };
    }

    pub fn equal(self: UUID, other: UUID) bool {
        return (uuid_lib.UUID{ .bytes = self.bytes }).eql(uuid_lib.UUID{ .bytes = other.bytes });
    }
};

test "uuid parsing" {
    const u = try UUID.fromString("550e8400-e29b-41d4-a716-446655440000");
    std.testing.expect(u.bytes.len == 16) catch unreachable;
}

test "uuid generation" {
    const uuid4 = UUID.v4();
    const uuid7 = UUID.v7();
    std.testing.expect(!UUID.equal(uuid4, uuid7)) catch unreachable;
}
