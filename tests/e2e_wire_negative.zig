const std = @import("std");
const protocol = @import("../src/protocol.zig");

// Negative wire tests exercising malformed frame parse and unsupported capability negotiation.
// These expand coverage for REQ-GQL-001 / REQ-GQL-002 beyond the happy HELLO round trip.

fn parse(line: []const u8) !protocol.ClientMessage {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    return protocol.parseClientMessage(gpa.allocator(), line);
}

// TestCANARY_REQ_GQL_001_WireMalformedFrame - ensures invalid JSON / structure is rejected.
test "TestCANARY_REQ_GQL_001_WireMalformedFrame" {
    // Missing closing brace and wrong field types
    const bads = [_][]const u8{
        "{\"type\":123}", // type must be string
        "{\"type\":\"HELLO\",\"client_name\":1}", // client_name must be string
        "{\"typo\":\"HELLO\"}", // missing type key
    };
    var any_err: bool = false;
    for (bads) |b| {
        const res = parse(b);
        if (res) |_| {
            // Should not succeed
            any_err = true; // mark failure
        } else |_| {
            // Expected path
        }
    }
    // Expect zero successes
    try std.testing.expect(!any_err);
}

// TestCANARY_REQ_GQL_002_WireUnsupportedCapability - unknown type should be invalid.
test "TestCANARY_REQ_GQL_002_WireUnsupportedCapability" {
    const line = "{\"type\":\"UNSUPPORTED_FOO\"}";
    if (parse(line)) |_| {
        return error.UnexpectedSuccess;
    } else |_| {}
}
