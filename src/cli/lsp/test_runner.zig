// Module implementation
// Main test runner for all LSP tests

const std = @import("std");

test {
    // Import all test files to run their tests
    _ = @import("protocol_test.zig");
    _ = @import("document_test.zig");
    _ = @import("features_test.zig");
    _ = @import("server_test.zig");
    _ = @import("e2e_test.zig");
    _ = @import("transport_test.zig");
    _ = @import("json_helpers_test.zig");
}
