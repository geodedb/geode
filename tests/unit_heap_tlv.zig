const std = @import("std");
const heap = @import("storage/heap.zig");

test "heap tlv: roundtrip primitives" {
    const allocator = std.testing.allocator;
    const b0 = try heap.encodeValue(allocator, .{ .Null = {} });
    defer allocator.free(b0);
    const v0 = try heap.decodeValue(allocator, b0);
    switch (v0) {
        .Null => {},
        else => return error.BadRoundtrip,
    }

    const b1 = try heap.encodeValue(allocator, .{ .Bool = true });
    defer allocator.free(b1);
    const v1 = try heap.decodeValue(allocator, b1);
    try std.testing.expect(v1 == .Bool and v1.Bool);

    const b2 = try heap.encodeValue(allocator, .{ .Int = -42 });
    defer allocator.free(b2);
    const v2 = try heap.decodeValue(allocator, b2);
    try std.testing.expect(v2 == .Int and v2.Int == -42);

    const b3 = try heap.encodeValue(allocator, .{ .Str = "hello" });
    defer allocator.free(b3);
    const v3 = try heap.decodeValue(allocator, b3);
    try std.testing.expect(v3 == .Str and std.mem.eql(u8, v3.Str, "hello"));
}
