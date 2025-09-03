const std = @import("std");
const heap = @import("../src/storage/heap.zig");

test "heap tlv: roundtrip primitives" {
    const ally = std.testing.allocator;
    // Null
    const b0 = try heap.encodeValue(ally, .{ .Null = {} });
    defer ally.free(b0);
    const v0 = try heap.decodeValue(ally, b0);
    switch (v0) {
        .Null => {},
        else => return error.BadRoundtrip,
    }

    // Bool
    const b1 = try heap.encodeValue(ally, .{ .Bool = true });
    defer ally.free(b1);
    const v1 = try heap.decodeValue(ally, b1);
    try std.testing.expect(v1 == .Bool and v1.Bool);

    // Int
    const b2 = try heap.encodeValue(ally, .{ .Int = -42 });
    defer ally.free(b2);
    const v2 = try heap.decodeValue(ally, b2);
    try std.testing.expect(v2 == .Int and v2.Int == -42);

    // Str
    const b3 = try heap.encodeValue(ally, .{ .Str = "hello" });
    defer ally.free(b3);
    const v3 = try heap.decodeValue(ally, b3);
    try std.testing.expect(v3 == .Str and std.mem.eql(u8, v3.Str, "hello"));
}
