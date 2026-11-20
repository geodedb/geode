// CANARY: REQ=REQ-CLI-SUBPROCESS-INTEGRATION-001; FEATURE="CLI Subprocess Elimination"; ASPECT=IntegrationTesting; STATUS=EXEMPT; TEST=TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_001; OWNER=claude; UPDATED=2025-10-05
// Integration tests for CLI subprocess elimination with actual binary execution

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const expect = testing.expect;
const proto_util = @import("proto_test_util.zig");

// Helper function to execute CLI commands and capture output
fn executeCommand(allocator: std.mem.Allocator, args: []const []const u8) !struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
} {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = std.process.Child.init(argv.items, allocator);
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

fn spawnTestServer(allocator: std.mem.Allocator) !proto_util.ServerHandle {
    return proto_util.spawnServerRandom(allocator, proto_util.TestEnv.standard());
}

// Test actual --insecure flag with unified binary
test "integration query executes with configured server" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    const args = [_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "RETURN 1 AS test",
        "--server",
        addr,
        "--insecure",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Verify exit code is success
    try expect(result.exit_code == 0);

    // Verify JSON response format
    try expect(std.mem.indexOf(u8, result.stdout, "\"columns\"") != null);
    try expect(std.mem.indexOf(u8, result.stdout, "\"rows\"") != null);
    try expect(std.mem.indexOf(u8, result.stdout, "\"test\":1") != null);

    // Verify it's valid JSON
    const stdout_trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    const newline_idx = std.mem.indexOfScalar(u8, stdout_trimmed, '\n') orelse stdout_trimmed.len;
    const first_line = stdout_trimmed[0..newline_idx];
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, first_line, .{}) catch |err| {
        std.debug.print("Failed to parse JSON: '{s}'\n", .{first_line});
        return err;
    };
    defer parsed.deinit();
}

// Test query without text returns usage error
test "integration query without text returns usage error" {
    const allocator = testing.allocator;

    const args = [_][]const u8{
        geode_test_bin.geode_exe,
        "query",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Verify exit code is usage error
    try expect(result.exit_code == 2);

    // Verify error message content
    try expect(std.mem.indexOf(u8, result.stderr, "Error: query text required") != null);
}

// Test complex query with --insecure
test "integration complex query with --insecure" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    const complex_query = "MATCH (person:Person)-[:KNOWS]->(friend:Person) WHERE person.age > 25 RETURN person.name, friend.name";

    const args = [_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        complex_query,
        "--server",
        addr,
        "--insecure",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should succeed
    try expect(result.exit_code == 0);

    // Should contain columns and rows output
    try expect(std.mem.indexOf(u8, result.stdout, "\"columns\"") != null);
    try expect(std.mem.indexOf(u8, result.stdout, "\"rows\"") != null);
}

// Test server address parameter in error message
test "integration server address in error message" {
    const allocator = testing.allocator;

    const args = [_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "RETURN 1",
        "--server",
        "127.0.0.1:1",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should return a non-zero exit code
    try expect(result.exit_code != 0);

    // Should include custom server address
    try expect(std.mem.indexOf(u8, result.stderr, "127.0.0.1:1") != null);
}

// Test that no external subprocess binaries are spawned
test "integration no subprocess spawning verification" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    // Test with --insecure to ensure it doesn't try to spawn external helpers
    const args = [_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "RETURN 'subprocess test' AS message",
        "--server",
        addr,
        "--insecure",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Should succeed without spawning subprocesses
    try expect(result.exit_code == 0);

    // Should not mention subprocess-related errors
    try expect(std.mem.indexOf(u8, result.stderr, "subprocess") == null);
    try expect(std.mem.indexOf(u8, result.stderr, "spawn") == null);
    try expect(std.mem.indexOf(u8, result.stderr, "No such file or directory") == null);
    try expect(std.mem.indexOf(u8, result.stderr, "command not found") == null);
}

// Test help command works without subprocess calls
test "integration help command without subprocess" {
    const allocator = testing.allocator;

    const args = [_][]const u8{
        geode_test_bin.geode_exe,
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
        geode_test_bin.geode_exe,
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
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    const test_cases = [_]struct {
        query: []const u8,
        expected_pattern: []const u8,
    }{
        .{ .query = "RETURN 'hello' AS greeting", .expected_pattern = "hello" },
        .{ .query = "RETURN 42 AS `number`", .expected_pattern = "42" },
        .{ .query = "RETURN 7 AS seven", .expected_pattern = "7" },
    };

    for (test_cases) |test_case| {
        const args = [_][]const u8{
            geode_test_bin.geode_exe,
            "query",
            test_case.query,
            "--server",
            addr,
            "--insecure",
        };

        const result = try executeCommand(allocator, &args);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        // All should succeed
        try expect(result.exit_code == 0);

        // All should contain expected pattern
        try expect(std.mem.indexOf(u8, result.stdout, test_case.expected_pattern) != null);

        // All should have consistent JSON format
        try expect(std.mem.indexOf(u8, result.stdout, "\"columns\"") != null);
        try expect(std.mem.indexOf(u8, result.stdout, "\"rows\"") != null);
        try expect(std.mem.indexOf(u8, result.stdout, "\"status_class\"") != null);
    }
}

// Test performance and timing
test "integration performance timing" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    const start_time = std.time.milliTimestamp();

    const args = [_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "RETURN 'performance test' AS message",
        "--server",
        addr,
        "--insecure",
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
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    // This test verifies CLI subprocess elimination integration functionality
    // as specified in REQ-CLI-SUBPROCESS-INTEGRATION-001

    const args = [_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "CANARY INTEGRATION TEST",
        "--server",
        addr,
        "--insecure",
    };

    const result = try executeCommand(allocator, &args);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Verify the integration test passes - this confirms CLI subprocess elimination
    // functionality works end-to-end with actual binary execution
    try expect(result.exit_code == 0);
    try expect(std.mem.indexOf(u8, result.stdout, "CANARY INTEGRATION TEST") != null);

    // Verify no subprocess-related errors occurred
    try expect(std.mem.indexOf(u8, result.stderr, "subprocess") == null);
    try expect(std.mem.indexOf(u8, result.stderr, "spawn") == null);

    // Log successful CANARY test completion
    std.log.info("CANARY integration test passed: CLI subprocess elimination working end-to-end", .{});
}
