const std = @import("std");
const testing = std.testing;

test "ArrayList API check" {
    // Test the correct way to initialize ArrayList in Zig 0.15
    var list = std.ArrayList(u64).init(testing.allocator);
    defer list.deinit();

    try list.append(42);
    try testing.expect(list.items.len == 1);
}
