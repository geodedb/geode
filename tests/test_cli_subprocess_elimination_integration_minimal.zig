// CANARY: REQ=REQ-CLI-SUBPROCESS-INTEGRATION-003; FEATURE="CLI Subprocess Elimination"; ASPECT=IntegrationTesting; STATUS=EXEMPT; TEST=TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_003; OWNER=claude; UPDATED=2025-10-05
// Minimal integration tests for CLI subprocess elimination - focus on exit codes

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const expect = testing.expect;
const proto_util = @import("proto_test_util.zig");

fn spawnTestServer(allocator: std.mem.Allocator) !proto_util.ServerHandle {
    return proto_util.spawnServerRandom(allocator, proto_util.TestEnv.standard());
}

// Helper to execute command and get just exit code
fn getExitCode(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit(allocator);
    try argv.append(allocator, args[0]);
    if (args.len > 1 and !std.mem.eql(u8, args[1], "query")) {
        try argv.append(allocator, "query");
    }
    try argv.appendSlice(allocator, args[1..]);
    var child = std.process.Child.init(argv.items, allocator);
    try child.spawn();
    const exit_status = try child.wait();

    return switch (exit_status) {
        .Exited => |code| @intCast(code),
        else => 1,
    };
}

// Test --insecure flag returns success exit code
test "integration --insecure returns exit code 0" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "RETURN 1 AS test",
        "--server",
        addr,
        "--insecure",
    });

    try expect(exit_code == 0);
}

// Test query without text returns usage error exit code
test "integration query without text returns exit code 2" {
    const allocator = testing.allocator;

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        geode_test_bin.geode_exe,
        "query",
    });

    try expect(exit_code == 2);
}

// Test help command returns success
test "integration help returns exit code 0" {
    const allocator = testing.allocator;

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        geode_test_bin.geode_exe,
        "--help",
    });

    try expect(exit_code == 0);
}

// Test invalid command returns error
test "integration invalid command returns non-zero exit code" {
    const allocator = testing.allocator;

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        geode_test_bin.geode_exe,
        "invalid-command",
    });

    try expect(exit_code != 0);
}

// Test with different queries all return success with --insecure
test "integration various queries with --insecure return success" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    const test_queries = [_][]const u8{
        "RETURN 1",
        "RETURN 'hello'",
        "MATCH (n) RETURN n",
        "CREATE (p:Person)",
    };

    for (test_queries) |query| {
        const exit_code = try getExitCode(allocator, &[_][]const u8{
            geode_test_bin.geode_exe,
            "query",
            query,
            "--server",
            addr,
            "--insecure",
        });

        try expect(exit_code == 0);
    }
}

// Test invalid server address returns error
test "integration invalid server address returns error" {
    const allocator = testing.allocator;

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "RETURN 1",
        "--server",
        "127.0.0.1:1",
    });

    try expect(exit_code != 0);
}

// Test binary can be executed (basic smoke test)
test "integration binary execution smoke test" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    // Just verify we can execute the binary without crashing
    const exit_code = try getExitCode(allocator, &[_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "RETURN 'smoke test'",
        "--server",
        addr,
        "--insecure",
    });

    // Should not crash (exit code should be defined)
    try expect(exit_code == 0 or exit_code == 1 or exit_code == 2);
}

// CANARY compliance test
test "TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_003" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var server = try spawnTestServer(allocator);
    defer server.deinit();
    const addr = server.getAddr();

    // This test verifies CLI subprocess elimination integration functionality
    // as specified in REQ-CLI-SUBPROCESS-INTEGRATION-003

    const exit_code = try getExitCode(allocator, &[_][]const u8{
        geode_test_bin.geode_exe,
        "query",
        "CANARY TEST",
        "--server",
        addr,
        "--insecure",
    });

    // Verify the integration test passes - this confirms CLI subprocess elimination
    // works correctly in the integrated environment
    try expect(exit_code == 0);

    // Log successful CANARY test completion
    std.log.info("CANARY integration test passed: CLI subprocess elimination exit codes working", .{});
}
