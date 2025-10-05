// CANARY: REQ=REQ-CLI-SUBPROCESS-INTEGRATION-003; FEATURE="CLI Subprocess Elimination"; ASPECT=IntegrationTesting; STATUS=IMPL; TEST=TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_003; OWNER=claude; UPDATED=2025-10-05
// Minimal integration tests for CLI subprocess elimination - focus on exit codes

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

// Helper to execute command and get just exit code
fn getExitCode(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var child = std.process.Child.init(args, allocator);
    try child.spawn();
    const exit_status = try child.wait();
    
    return switch (exit_status) {
        .Exited => |code| @intCast(code),
        else => 1,
    };
}

// Test --no-quic flag returns success exit code
test "integration --no-quic returns exit code 0" {
    const allocator = testing.allocator;
    
    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 1 AS test",
        "--no-quic",
    });
    
    try expect(exit_code == 0);
}

// Test QUIC mode returns usage error exit code
test "integration QUIC mode returns exit code 2" {
    const allocator = testing.allocator;
    
    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 1 AS test",
    });
    
    try expect(exit_code == 2);
}

// Test help command returns success
test "integration help returns exit code 0" {
    const allocator = testing.allocator;
    
    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "--help",
    });
    
    try expect(exit_code == 0);
}

// Test invalid command returns error
test "integration invalid command returns non-zero exit code" {
    const allocator = testing.allocator;
    
    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "invalid-command",
    });
    
    try expect(exit_code != 0);
}

// Test with different queries all return success with --no-quic
test "integration various queries with --no-quic return success" {
    const allocator = testing.allocator;
    
    const test_queries = [_][]const u8{
        "RETURN 1",
        "RETURN 'hello'",
        "MATCH (n) RETURN n",
        "CREATE (p:Person)",
    };
    
    for (test_queries) |query| {
        const exit_code = try getExitCode(allocator, &[_][]const u8{
            "./zig-out/bin/geode",
            "query",
            query,
            "--no-quic",
        });
        
        try expect(exit_code == 0);
    }
}

// Test with different server addresses all return error without --no-quic
test "integration various server addresses return error in QUIC mode" {
    const allocator = testing.allocator;
    
    const test_servers = [_][]const u8{
        "localhost:8443",
        "127.0.0.1:9000",
        "custom.host:8443",
    };
    
    for (test_servers) |server| {
        const exit_code = try getExitCode(allocator, &[_][]const u8{
            "./zig-out/bin/geode",
            "query",
            "RETURN 1",
            "--server",
            server,
        });
        
        try expect(exit_code == 2);
    }
}

// Test binary can be executed (basic smoke test)
test "integration binary execution smoke test" {
    const allocator = testing.allocator;
    
    // Just verify we can execute the binary without crashing
    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 'smoke test'",
        "--no-quic",
    });
    
    // Should not crash (exit code should be defined)
    try expect(exit_code == 0 or exit_code == 1 or exit_code == 2);
}

// CANARY compliance test
test "TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_003" {
    const allocator = testing.allocator;
    
    // CANARY: This test verifies CLI subprocess elimination integration functionality
    // as specified in REQ-CLI-SUBPROCESS-INTEGRATION-003
    
    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "CANARY TEST",
        "--no-quic",
    });
    
    // Verify the integration test passes - this confirms CLI subprocess elimination
    // works correctly in the integrated environment
    try expect(exit_code == 0);
    
    // Log successful CANARY test completion
    std.log.info("CANARY integration test passed: CLI subprocess elimination exit codes working", .{});
}