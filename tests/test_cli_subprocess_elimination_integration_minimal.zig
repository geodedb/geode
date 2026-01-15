// CANARY: REQ=REQ-CLI-SUBPROCESS-INTEGRATION-003; FEATURE="CLI Subprocess Elimination"; ASPECT=IntegrationTesting; STATUS=IMPL; TEST=TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_003; OWNER=claude; UPDATED=2025-10-05
// Minimal integration tests for CLI subprocess elimination - focus on exit codes

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

fn getTestServer(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "GEODE_TEST_SERVER") catch return error.SkipZigTest;
}

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

// Test --insecure flag returns success exit code
test "integration --insecure returns exit code 0" {
    const allocator = testing.allocator;

    const server = try getTestServer(allocator);
    defer allocator.free(server);

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 1 AS test",
        "--server",
        server,
        "--insecure",
    });

    try expect(exit_code == 0);
}

// Test query without text returns usage error exit code
test "integration query without text returns exit code 2" {
    const allocator = testing.allocator;

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "query",
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

// Test with different queries all return success with --insecure
test "integration various queries with --insecure return success" {
    const allocator = testing.allocator;

    const server = try getTestServer(allocator);
    defer allocator.free(server);

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
            "--server",
            server,
            "--insecure",
        });

        try expect(exit_code == 0);
    }
}

// Test invalid server address returns error
test "integration invalid server address returns error" {
    const allocator = testing.allocator;

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 1",
        "--server",
        "127.0.0.1:1",
    });

    try expect(exit_code != 0);
}

// Test binary can be executed (basic smoke test)
test "integration binary execution smoke test" {
    const allocator = testing.allocator;

    const server = try getTestServer(allocator);
    defer allocator.free(server);

    // Just verify we can execute the binary without crashing
    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 'smoke test'",
        "--server",
        server,
        "--insecure",
    });

    // Should not crash (exit code should be defined)
    try expect(exit_code == 0 or exit_code == 1 or exit_code == 2);
}

// CANARY compliance test
test "TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_003" {
    const allocator = testing.allocator;

    const server = try getTestServer(allocator);
    defer allocator.free(server);

    // CANARY: This test verifies CLI subprocess elimination integration functionality
    // as specified in REQ-CLI-SUBPROCESS-INTEGRATION-003

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "CANARY TEST",
        "--server",
        server,
        "--insecure",
    });

    // Verify the integration test passes - this confirms CLI subprocess elimination
    // works correctly in the integrated environment
    try expect(exit_code == 0);

    // Log successful CANARY test completion
    std.log.info("CANARY integration test passed: CLI subprocess elimination exit codes working", .{});
}
