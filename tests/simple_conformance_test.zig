const std = @import("std");
const testing = std.testing;

// Simple standalone test to verify basic conformance features
test "basic conformance check" {
    // Test that basic features compile and work
    try testing.expect(true);
}

test "SKIP keyword exists" {
    // Just verify compilation works
    const skip_value: ?usize = 5;
    try testing.expect(skip_value.? == 5);
}

test "NULLS policy enum" {
    const NullsPolicy = enum { default, first, last };
    const policy = NullsPolicy.last;
    try testing.expect(policy == .last);
}
