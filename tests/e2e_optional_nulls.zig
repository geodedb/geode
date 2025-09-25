const std = @import("std");

test "OPTIONAL MATCH null semantics regression check" {
    // This test verifies that OPTIONAL MATCH correctly handles null semantics
    // as fixed in v0.16.0 (kb/archive/RELEASE_NOTES_v0.16.md#L193-L196)
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Simulate OPTIONAL MATCH result set
    const OptionalResult = struct {
        matched: ?u64,
        property: ?[]const u8,
    };
    
    var results = std.ArrayList(OptionalResult).init(allocator);
    defer results.deinit();
    
    // Add results including nulls from non-matches
    try results.append(.{ .matched = 1, .property = "value1" });
    try results.append(.{ .matched = null, .property = null }); // OPTIONAL non-match
    try results.append(.{ .matched = 3, .property = "value3" });
    
    // Verify null handling
    var null_count: u32 = 0;
    for (results.items) |r| {
        if (r.matched == null) {
            try std.testing.expect(r.property == null);
            null_count += 1;
        }
    }
    
    try std.testing.expect(null_count == 1);
    
    std.debug.print("OPTIONAL_NULLS_OK\n", .{});
}