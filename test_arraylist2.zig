const std = @import("std");

test "ArrayList creation" {
    const allocator = std.testing.allocator;
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(allocator);
    try std.testing.expect(list.items.len == 0);
}
