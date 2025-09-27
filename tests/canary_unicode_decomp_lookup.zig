const std = @import("std");
const unicode = @import("../src/unicode/geode_unicode.zig");

// Test for decomposition lookup (REQ-GQL-UNICODE-003)
test "TestCANARY_REQ_GQL_UNICODE_003_DecompLookup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // We rely on placeholder generated.decomp entries for É (00C9) and é (00E9)
    // Validate simpleDecompose produces expected sequence for both.
    var list = std.ArrayList(u32).init(alloc);
    defer list.deinit();
    try unicode.simpleDecompose(0x00C9, &list);
    try std.testing.expect(list.items.len == 2 and list.items[0] == 0x0045 and list.items[1] == 0x0301);
    list.clearRetainingCapacity();
    try unicode.simpleDecompose(0x00E9, &list);
    try std.testing.expect(list.items.len == 2 and list.items[0] == 0x0065 and list.items[1] == 0x0301);
}
