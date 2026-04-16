const std = @import("std");

test "ArrayList creation" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    try std.testing.expect(list.items.len == 0);
}
