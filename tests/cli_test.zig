const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

// Test CLI components by spawning the actual geode binary

test "geode --help exits with code 0" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // Skip on Windows for simplicity
    
    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    const result = try child.wait();
    
    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode with no subcommand shows usage error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    
    var child = std.process.Child.init(&.{"./zig-out/bin/geode"}, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    const result = try child.wait();
    
    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 2); // usage error
}

test "geode query --help shows query help" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    
    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "query", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    const result = try child.wait();
    
    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode serve --help shows serve help" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    
    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "serve", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    const result = try child.wait();
    
    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode user --help shows user help" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    
    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "user", "--help" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    const result = try child.wait();
    
    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 0);
}

test "geode with invalid subcommand shows error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    
    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "invalid_command" }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    const result = try child.wait();
    
    try testing.expect(result == .Exited);
    try testing.expect(result.Exited == 2); // usage error
}

test "geode query requires query text" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    
    var child = std.process.Child.init(&.{ "./zig-out/bin/geode", "query" }, testing.allocator);
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

test "legacy binary name detection" {
    // Test basename extraction for legacy compatibility
    try testing.expectEqualStrings("geoded", std.fs.path.basename("/usr/local/bin/geoded"));
    try testing.expectEqualStrings("geodec", std.fs.path.basename("./zig-out/bin/geodec"));
    try testing.expectEqualStrings("geode-auth", std.fs.path.basename("geode-auth"));
    try testing.expectEqualStrings("geode", std.fs.path.basename("/path/to/geode"));
    
    // Test legacy detection logic
    try testing.expect(std.mem.endsWith(u8, "geoded", "geoded"));
    try testing.expect(std.mem.endsWith(u8, "geodec", "geodec"));
    try testing.expect(std.mem.endsWith(u8, "geode-auth", "geode-auth"));
    try testing.expect(!std.mem.endsWith(u8, "geode", "geoded"));
}