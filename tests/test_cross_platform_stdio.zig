const std = @import("std");
const builtin = @import("builtin");

test "cross-platform stdio handles" {
    // Test that we can correctly create File handles for stdin, stdout, stderr
    // on both Windows and POSIX systems
    const stdout = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    const stderr = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDERR_FILENO };

    const stdin = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDIN_FILENO };

    // Simple write test using writeAll directly on the file handles
    try stdout.writeAll("Test stdout\n");
    try stderr.writeAll("Test stderr\n");

    // Verify stdin handle is valid by checking we can read from it
    // We don't actually read since there may be no input
    _ = stdin;
}
