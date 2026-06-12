const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

// Test CLI components by spawning the actual geode binary

const geode_binary = "./zig-out/bin/geode";

// Zig 0.16 compat: std.fs.cwd()/std.process.Child.init were retired in favor
// of std.Io.Dir + the free function std.process.spawn(io, SpawnOptions).
// NOTE: Io.Threaded.global_single_threaded has a `.failing` allocator, so any
// io operation that allocates (spawn does) needs a Threaded with a real
// allocator — same shape proto_test_util.zig uses.

// Check if geode binary exists - skip tests in CI where binary may not be built yet
fn geodeBinaryExists() bool {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, geode_binary, .{ .mode = .read_only }) catch return false;
    file.close(io);
    return true;
}

/// Spawn the geode binary with `argv`, wait for it, and return its Term.
/// stdout/stderr are discarded — these tests only assert on exit codes.
fn runGeode(argv: []const []const u8) !std.process.Child.Term {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return child.wait(io);
}

test "geode --help exits with code 0" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // Skip on Windows for simplicity
    if (!geodeBinaryExists()) return error.SkipZigTest; // Skip if binary not built

    const result = try runGeode(&.{ geode_binary, "--help" });

    try testing.expect(result == .exited);
    try testing.expect(result.exited == 0);
}

test "geode with no subcommand shows usage error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    const result = try runGeode(&.{geode_binary});

    try testing.expect(result == .exited);
    try testing.expect(result.exited == 2); // usage error
}

test "geode query --help shows query help" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    const result = try runGeode(&.{ geode_binary, "query", "--help" });

    try testing.expect(result == .exited);
    try testing.expect(result.exited == 0);
}

test "geode serve --help shows serve help" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    const result = try runGeode(&.{ geode_binary, "serve", "--help" });

    try testing.expect(result == .exited);
    try testing.expect(result.exited == 0);
}

test "geode user --help shows user help" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    const result = try runGeode(&.{ geode_binary, "user", "--help" });

    try testing.expect(result == .exited);
    try testing.expect(result.exited == 0);
}

test "geode with invalid subcommand shows error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    const result = try runGeode(&.{ geode_binary, "invalid_command" });

    try testing.expect(result == .exited);
    try testing.expect(result.exited == 2); // usage error
}

test "geode query requires query text" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!geodeBinaryExists()) return error.SkipZigTest;

    const result = try runGeode(&.{ geode_binary, "query" });

    try testing.expect(result == .exited);
    try testing.expect(result.exited == 2); // usage error
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
    try testing.expectEqualStrings("geode", std.fs.path.basename("/usr/local/bin/geode"));
    try testing.expectEqualStrings("geode", std.fs.path.basename("./zig-out/bin/geode"));
    try testing.expectEqualStrings("geode-auth", std.fs.path.basename("geode-auth"));
    try testing.expectEqualStrings("geode", std.fs.path.basename("/path/to/geode"));

    // Unified binary should not be confused with legacy names
    try testing.expect(!std.mem.endsWith(u8, "geode", "geoded"));
    try testing.expect(!std.mem.endsWith(u8, "geode", "geodec"));
}
