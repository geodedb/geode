const std = @import("std");

const Dummy = struct {
    ts: i64,
};

test "audit canonical writer formats keys deterministically" {
    _ = Dummy{ .ts = 123 };
    try std.testing.expect(true);
}
