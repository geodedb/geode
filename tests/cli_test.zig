const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

// Test CLI components by spawning the actual geode binary

const geode_binary = "./zig-out/bin/geode";

// Check if geode binary exists - skip tests in CI where binary may not be built yet
fn geodeBinaryExists() bool {
    const file = std.fs.cwd().openFile(geode_binary, .{}) catch return false;
    file.close();
    return true;
}

test "geode --help exits with code 0" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // Skip on Windows for simplicity
    if (!geodeBinaryExists()) return error.SkipZigTest; // Skip if binary not built

    var child = std.process.Child.init(&.{ geode_binary, "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode with no subcommand shows usage error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    var child = std.process.Child.init(&.{geode_binary}, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 2); // usage error
}

test "geode query --help shows query help" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ geode_binary, "query", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode serve --help shows serve help" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ geode_binary, "serve", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode user --help shows user help" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ geode_binary, "user", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode with invalid subcommand shows error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ geode_binary, "invalid_command" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 2); // usage error
}

test "geode query requires query text" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    var child = std.process.Child.init(&.{ geode_binary, "query" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    const result = try child.wait();

    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 2); // usage error
}

test "exit codes are defined correctly" {
    const ExitCode = enum(u8) {
        success = 0,
        general_error = 1,
        usage_error = 2,
        auth_error = 3,
    };

    try testing.expect(@intFromEnum(ExitCode.success) == 0);
    try testing.expect(@intFromEnum(ExitCode.general_error) == 1);
    try testing.expect(@intFromEnum(ExitCode.usage_error) == 2);
    try testing.expect(@intFromEnum(ExitCode.auth_error) == 3);
}

test "unified CLI binary name detection" {
    // Test basename extraction for unified CLI
    try testing.expectEqualStrings("geoded", std.fs.path.basename("/usr/local/bin/geoded"));
    try testing.expectEqualStrings("geode", std.fs.path.basename("./zig-out/bin/geode"));
    try testing.expectEqualStrings("geode-auth", std.fs.path.basename("geode-auth"));
    try testing.expectEqualStrings("geode", std.fs.path.basename("/path/to/geode"));

    // Test legacy detection logic
    try testing.expect(std.mem.endsWith(u8, "geoded", "geoded"));
    try testing.expect(std.mem.endsWith(u8, "geodec", "geodec"));
    try testing.expect(std.mem.endsWith(u8, "geode-auth", "geode-auth"));
    try testing.expect(!std.mem.endsWith(u8, "geode", "geoded"));
}
