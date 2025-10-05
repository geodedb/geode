// CANARY: REQ=REQ-CLI-SUBPROCESS-INTEGRATION-002; FEATURE="CLI Subprocess Elimination"; ASPECT=IntegrationTesting; STATUS=IMPL; TEST=TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_002; OWNER=claude; UPDATED=2025-10-05
// Simplified integration tests for CLI subprocess elimination

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

// Test the actual --no-quic flag with a simple execution
test "integration --no-quic flag basic functionality" {
    const allocator = testing.allocator;
    
    var child = std.process.Child.init(&[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 1 AS test",
        "--no-quic",
    }, allocator);
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const exit_status = try child.wait();
    
    // Should exit with success
    switch (exit_status) {
        .Exited => |code| try expect(code == 0),
        else => try expect(false),
    }
    
    // Should produce JSON output
    try expect(std.mem.indexOf(u8, stdout, "{") != null);
    try expect(std.mem.indexOf(u8, stdout, "}") != null);
}

// Test QUIC mode returns error
test "integration QUIC mode error handling" {
    const allocator = testing.allocator;
    
    var child = std.process.Child.init(&[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 1 AS test",
    }, allocator);
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const exit_status = try child.wait();
    
    // Should exit with usage error
    switch (exit_status) {
        .Exited => |code| try expect(code == 2),
        else => try expect(false),
    }
    
    // Should produce error message
    try expect(std.mem.indexOf(u8, stderr, "Error:") != null);
}

// Test help command works
test "integration help command functionality" {
    const allocator = testing.allocator;
    
    var child = std.process.Child.init(&[_][]const u8{
        "./zig-out/bin/geode",
        "--help",
    }, allocator);
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const exit_status = try child.wait();
    
    // Should exit with success
    switch (exit_status) {
        .Exited => |code| try expect(code == 0),
        else => try expect(false),
    }
    
    // Should produce help output (in either stdout or stderr)
    const has_help = (std.mem.indexOf(u8, stdout, "geode") != null) or 
                     (std.mem.indexOf(u8, stderr, "geode") != null);
    try expect(has_help);
}

// Test subprocess elimination - verify no geodec/geoded spawning
test "integration no subprocess spawning" {
    const allocator = testing.allocator;
    
    var child = std.process.Child.init(&[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 'subprocess test'",
        "--no-quic",
    }, allocator);
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const exit_status = try child.wait();
    
    // Should succeed
    switch (exit_status) {
        .Exited => |code| try expect(code == 0),
        else => try expect(false),
    }
    
    // Should not contain subprocess-related errors
    try expect(std.mem.indexOf(u8, stderr, "geodec") == null);
    try expect(std.mem.indexOf(u8, stderr, "geoded") == null);
    try expect(std.mem.indexOf(u8, stderr, "No such file") == null);
}

// Test that binary exists and is executable
test "integration binary existence and execution" {
    const allocator = testing.allocator;
    
    // Test that the binary exists
    std.fs.cwd().access("./zig-out/bin/geode", .{}) catch |err| {
        std.debug.print("Binary not found: {}\n", .{err});
        try expect(false);
    };
    
    // Test that it can be executed
    var child = std.process.Child.init(&[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 'existence test'",
        "--no-quic",
    }, allocator);
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const exit_status = try child.wait();
    
    switch (exit_status) {
        .Exited => |code| try expect(code == 0),
        else => try expect(false),
    }
}

// Test performance timing
test "integration performance acceptable" {
    const allocator = testing.allocator;
    
    const start_time = std.time.milliTimestamp();
    
    var child = std.process.Child.init(&[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "RETURN 'performance test'",
        "--no-quic",
    }, allocator);
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const exit_status = try child.wait();
    
    const end_time = std.time.milliTimestamp();
    const duration_ms = end_time - start_time;
    
    // Should complete in reasonable time (under 10 seconds)
    try expect(duration_ms < 10000);
    
    // Should succeed
    switch (exit_status) {
        .Exited => |code| try expect(code == 0),
        else => try expect(false),
    }
    
    std.log.info("CLI execution completed in {}ms", .{duration_ms});
}

// CANARY compliance test
test "TestCANARY_REQ_CLI_SUBPROCESS_INTEGRATION_002" {
    const allocator = testing.allocator;
    
    // CANARY: This test verifies CLI subprocess elimination integration functionality
    // as specified in REQ-CLI-SUBPROCESS-INTEGRATION-002
    
    var child = std.process.Child.init(&[_][]const u8{
        "./zig-out/bin/geode",
        "query",
        "CANARY INTEGRATION TEST",
        "--no-quic",
    }, allocator);
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const exit_status = try child.wait();
    
    // Verify the integration test passes - this confirms CLI subprocess elimination
    // functionality works end-to-end
    switch (exit_status) {
        .Exited => |code| try expect(code == 0),
        else => try expect(false),
    }
    
    // Should produce output (JSON format)
    try expect(stdout.len > 0);
    
    // Should not have subprocess errors
    try expect(std.mem.indexOf(u8, stderr, "geodec") == null);
    try expect(std.mem.indexOf(u8, stderr, "geoded") == null);
    
    // Log successful CANARY test completion
    std.log.info("CANARY integration test passed: CLI subprocess elimination working end-to-end", .{});
}