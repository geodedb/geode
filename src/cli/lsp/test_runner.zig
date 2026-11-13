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
    _ = @import("server_invalid_params_test.zig");
    _ = @import("server_definition_test.zig");
    _ = @import("mcp_input_guards_test.zig");
    _ = @import("framer_test.zig");
    _ = @import("server_debounce_test.zig");
    // Task 12: per-session auth + schema bind gate tests.
    _ = @import("server_auth_test.zig");
    // SONNY-6511: recommendation diagnostics carry their token's range.
    _ = @import("recommendation_positions_test.zig");
}
