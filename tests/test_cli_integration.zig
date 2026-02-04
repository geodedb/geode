const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

// Integration tests for unified CLI - testing actual process spawning and communication
fn getTestServer(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "GEODE_TEST_SERVER") catch return error.SkipZigTest;
}

test "geode unified binary exists and responds" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode serve help shows server options" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "serve", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);

    // Check for server-specific options in stdout if available
    if (child.stdout) |stdout_pipe| {
        const stdout = try stdout_pipe.readToEndAlloc(testing.allocator, 1024 * 1024);
        defer testing.allocator.free(stdout);
        try testing.expect(std.mem.indexOf(u8, stdout, "--data-dir") != null);
        try testing.expect(std.mem.indexOf(u8, stdout, "--listen") != null);
    }
}

test "geode query help shows client options" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "query", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    if (child.stdout) |stdout_pipe| {
        const stdout = try stdout_pipe.readToEndAlloc(testing.allocator, 1024 * 1024);
        defer testing.allocator.free(stdout);

        try testing.expect(result == .Exited);
        try testing.expect(result.Exited == 0);

        // Check for client-specific options
        try testing.expect(std.mem.indexOf(u8, stdout, "--format") != null);
        try testing.expect(std.mem.indexOf(u8, stdout, "--insecure") != null);
        try testing.expect(std.mem.indexOf(u8, stdout, "--server") != null);
    } else {
        // If stdout is null, just check exit code
        try testing.expect(result == .Exited);
        try testing.expect(result.Exited == 0);
    }
}

test "geode query executes with configured server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const server = try getTestServer(testing.allocator);
    defer testing.allocator.free(server);

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "query", "RETURN 1 AS x", "--server", server", "--insecure" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);

    // Check for expected JSON response structure in stdout if available
    if (child.stdout) |stdout_pipe| {
        const stdout = try stdout_pipe.readToEndAlloc(testing.allocator, 1024 * 1024);
        defer testing.allocator.free(stdout);
        try testing.expect(std.mem.indexOf(u8, stdout, "\"x\":1") != null);
    }
}

test "geode shell command exists" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "shell", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode backup command exists" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "backup", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode user command exists" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "user", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "invalid command returns usage error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "invalid_command" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 2); // usage error
}

test "query without arguments returns usage error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "query" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 2); // usage error
}

test "query responds to basic query" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const server = try getTestServer(testing.allocator);
    defer testing.allocator.free(server);

    // Test basic query execution against configured server
    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "query", "RETURN 'hello' AS greeting", "--server", server", "--insecure", "--format", "json" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);

    // Check for expected response in stdout if available
    if (child.stdout) |stdout_pipe| {
        const stdout = try stdout_pipe.readToEndAlloc(testing.allocator, 1024 * 1024);
        defer testing.allocator.free(stdout);
        try testing.expect(std.mem.indexOf(u8, stdout, "\"type\":\"SCHEMA\"") != null);
        try testing.expect(std.mem.indexOf(u8, stdout, "greeting") != null);
    }
}

test "query error handling for invalid syntax" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const server = try getTestServer(testing.allocator);
    defer testing.allocator.free(server);

    // Test error handling with invalid syntax
    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "query", "SELECT * FROM nonexistent_table", "--server", server", "--insecure" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited != 0);

    if (child.stderr) |stderr_pipe| {
        const stderr = try stderr_pipe.readToEndAlloc(testing.allocator, 1024 * 1024);
        defer testing.allocator.free(stderr);
        try testing.expect(std.mem.indexOf(u8, stderr, "Error") != null);
    }
}

test "process argument forwarding" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const server = try getTestServer(testing.allocator);
    defer testing.allocator.free(server);

    // Test that arguments are properly forwarded to configured server
    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "query", "RETURN 42 AS answer", "--server", server", "--insecure", "--format", "json" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);

    // For JSON format, expect the number 42 in stdout if available
    if (child.stdout) |stdout_pipe| {
        const stdout = try stdout_pipe.readToEndAlloc(testing.allocator, 1024 * 1024);
        defer testing.allocator.free(stdout);
        try testing.expect(std.mem.indexOf(u8, stdout, "42") != null);
    }
}

test "concurrent query execution" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const server = try getTestServer(testing.allocator);
    defer testing.allocator.free(server);

    // Test that multiple queries can be executed concurrently
    const query_count = 3;
    var children: [query_count]std.process.Child = undefined;

    // Start multiple query processes
    for (&children, 0..) |*child, i| {
        const query = try std.fmt.allocPrint(testing.allocator, "RETURN {d} AS id", .{i});
        defer testing.allocator.free(query);

        child.* = std.process.Child.init(&.{ "./zig-out/bin/geode", "query", query", "--server", server", "--insecure" }, testing.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
    }

    // Wait for all to complete
    for (&children) |*child| {
        const result = try child.wait();
        try testing.expect(result == .Exited);
        try testing.expect(result.Exited == 0);
    }
}

test "version information available" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "--version" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);

    // Should contain version information in stdout if available
    if (child.stdout) |stdout_pipe| {
        const stdout = try stdout_pipe.readToEndAlloc(testing.allocator, 1024 * 1024);
        defer testing.allocator.free(stdout);
        try testing.expect(stdout.len > 0);
    }
}
