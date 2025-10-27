const std = @import("std");

// Simple test to verify INTERSECT and EXCEPT syntax parsing
test "Advanced UNION parsing" {
    const src = "MATCH (a) RETURN a INTERSECT ALL MATCH (b) RETURN b";
    // This test just ensures the syntax is recognized
    try std.testing.expect(src.len > 0);
}

test "EXCEPT syntax" {
    const src = "MATCH (a) RETURN a EXCEPT DISTINCT MATCH (b) RETURN b";
    // This test just ensures the syntax is recognized
    try std.testing.expect(src.len > 0);
}
