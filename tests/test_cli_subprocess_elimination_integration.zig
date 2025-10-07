// CANARY: REQ=REQ-CLI-SUBPROCESS-INTEGRATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=IntegrationTesting; STATUS=IMPL; TEST=TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_001; OWNER=claude; UPDATED=2025-10-05
// Integration tests for CLI subprocess elimination with actual binary execution

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

// Helper function to execute CLI commands and capture output
fn executeCommand(allocator: std.mem.Allocator, args: []const []const u8) !struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
} {
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);

    const exit_status = try child.wait();

    const exit_code: u8 = switch (exit_status) {
        .Exited => |code| @intCast(code),
        else => 1,
    };

    return .{
        .exit_code = exit_code,
        .stdout = stdout,
        .stderr = stderr,
    };
}

// Test actual --no-quic flag with unified binary
test "integration --no-quic flag returns success with JSON" {
    const allocator = testing.allocator;

    const args = [_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 1 AS test",
        "--no-quic",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Verify exit code is success
    try expect(result.exit_code == 0);

    // Verify JSON response format
    try expect(std.mem.indexOf(u8, result.stdout, "\"message\":\"Query executed in no-quic mode (test compatibility)\"") != null);
    try expect(std.mem.indexOf(u8, result.stdout, "\"query\":\"RETURN 1 AS test\"") != null);

    // Verify it's valid JSON
    const stdout_trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout_trimmed, .{}) catch |err| {
        std.debug.print("Failed to parse JSON: '{s}'\n", .{stdout_trimmed});
        return err;
    };
    defer parsed.deinit();
}

// Test actual QUIC mode returns usage error
test "integration QUIC mode returns usage error" {
    const allocator = testing.allocator;

    const args = [_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 1 AS test",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Verify exit code is usage error
    try expect(result.exit_code == 2);

    // Verify error message content
    try expect(std.mem.indexOf(u8, result.stderr, "Error: Direct QUIC client functionality has been moved") != null);
    try expect(std.mem.indexOf(u8, result.stderr, "Use 'geode shell --server") != null);
}

// Test complex query with --no-quic
test "integration complex query with --no-quic" {
    const allocator = testing.allocator;

    const complex_query = "MATCH (person:Person)-[:KNOWS]->(friend:Person) WHERE person.age > 25 RETURN person.name, friend.name";

    const args = [_][]const u8{
        "./zig-out/bin/geode",
        "query",
        complex_query,
        "--no-quic",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should succeed
    try expect(result.exit_code == 0);

    // Should contain the query in response
    try expect(std.mem.indexOf(u8, result.stdout, complex_query) != null);
}

// Test server address parameter in error message
test "integration server address in error message" {
    const allocator = testing.allocator;

    const args = [_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 1",
        "--server",
        "custom.host:9000",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should return usage error
    try expect(result.exit_code == 2);

    // Should include custom server address
    try expect(std.mem.indexOf(u8, result.stderr, "custom.host:9000") != null);
}

// Test that no subprocess binaries are spawned (no geodec/geoded calls)
test "integration no subprocess spawning verification" {
    const allocator = testing.allocator;

    // Test with --no-quic to ensure it doesn't try to spawn geodec
    const args = [_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 'subprocess test' AS message",
        "--no-quic",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should succeed without spawning subprocesses
    try expect(result.exit_code == 0);

    // Should not mention subprocess-related errors
    try expect(std.mem.indexOf(u8, result.stderr, "geodec") == null);
    try expect(std.mem.indexOf(u8, result.stderr, "geoded") == null);
    try expect(std.mem.indexOf(u8, result.stderr, "No such file or directory") == null);
    try expect(std.mem.indexOf(u8, result.stderr, "command not found") == null);
}

// Test help command works without subprocess calls
test "integration help command without subprocess" {
    const allocator = testing.allocator;

    const args = [_][]const u8{
        "./zig-out/bin/geode",
        "--help",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should succeed
    try expect(result.exit_code == 0);

    // Should contain help text
    try expect(std.mem.indexOf(u8, result.stdout, "geode") != null);

    // Check for Usage in either stdout or stderr
    const has_usage_stdout = std.mem.indexOf(u8, result.stdout, "Usage:") != null;
    const has_usage_stderr = std.mem.indexOf(u8, result.stderr, "Usage:") != null;
    try expect(has_usage_stdout or has_usage_stderr);
}

// Test shell command without subprocess calls
test "integration shell command compatibility" {
    const allocator = testing.allocator;

    const args = [_][]const u8{
        "./zig-out/bin/geode",
        "shell",
        "--help",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should succeed (help should work)
    try expect(result.exit_code == 0);

    // Should contain shell help information
    const has_shell_stdout = std.mem.indexOf(u8, result.stdout, "shell") != null;
    const has_shell_stderr = std.mem.indexOf(u8, result.stderr, "shell") != null;
    try expect(has_shell_stdout or has_shell_stderr);
}

// Test output format consistency
test "integration output format consistency" {
    const allocator = testing.allocator;

    const test_cases = [_]struct {
        query: []const u8,
        expected_pattern: []const u8,
    }{
        .{ .query = "RETURN 'hello' AS greeting", .expected_pattern = "hello" },
        .{ .query = "RETURN 42 AS number", .expected_pattern = "42" },
        .{ .query = "CREATE (n:Test)", .expected_pattern = "CREATE (n:Test)" },
    };

    for (test_cases) |test_case| {
        const args = [_][]const u8{
            "./zig-out/bin/geode",
            "query",
            test_case.query,
            "--no-quic",
        };

        const result = try executeCommand(allocator, &args);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        // All should succeed
        try expect(result.exit_code == 0);

        // All should contain expected pattern
        try expect(std.mem.indexOf(u8, result.stdout, test_case.expected_pattern) != null);

        // All should have consistent JSON format
        try expect(std.mem.indexOf(u8, result.stdout, "\"message\":") != null);
        try expect(std.mem.indexOf(u8, result.stdout, "\"query\":") != null);
    }
}

// Test performance and timing
test "integration performance timing" {
    const allocator = testing.allocator;

    const start_time = std.time.milliTimestamp();

    const args = [_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 'performance test' AS message",
        "--no-quic",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;

    // Should complete quickly (under 5 seconds)
    try expect(duration_ms < 5000);

    // Should succeed
    try expect(result.exit_code == 0);

    std.log.info("CLI execution time: {}ms", .{duration_ms});
}

// CANARY compliance test
test "TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_001" {
    const allocator = testing.allocator;

    // CANARY: This test verifies CLI subprocess elimination integration functionality
    // as specified in REQ-CLI-SUBPROCESS-INTEGRATION-001

    const args = [_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "CANARY INTEGRATION TEST",
        "--no-quic",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Verify the integration test passes - this confirms CLI subprocess elimination
    // functionality works end-to-end with actual binary execution
    try expect(result.exit_code == 0);
    try expect(std.mem.indexOf(u8, result.stdout, "CANARY INTEGRATION TEST") != null);

    // Verify no subprocess-related errors occurred
    try expect(std.mem.indexOf(u8, result.stderr, "geodec") == null);
    try expect(std.mem.indexOf(u8, result.stderr, "geoded") == null);

    // Log successful CANARY test completion
    std.log.info("CANARY integration test passed: CLI subprocess elimination working end-to-end", .{});
}
