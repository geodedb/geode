const std = @import("std");
const constraints = @import("../src/storage/constraints.zig");

// TestCANARY_REQ_GQL_032_PatternRegexEscape
// Ensures escaped metacharacters are treated literally.

test "TestCANARY_REQ_GQL_032_PatternRegexEscape" {
    try std.testing.expect(constraints.SchemaConstraints.patternMatch("a*b", "a\\*b"));
    try std.testing.expect(constraints.SchemaConstraints.patternMatch("a?b", "a\\?b"));
    try std.testing.expect(constraints.SchemaConstraints.patternMatch("a[b]", "a\\[b]"));
    try std.testing.expect(!constraints.SchemaConstraints.patternMatch("ab", "a\\?b")); // requires literal '?'
}
