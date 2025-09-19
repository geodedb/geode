const std = @import("std");
const builtin = @import("builtin");

test "cross-platform stdio handles" {
    // Test that we can correctly create File handles for stdin, stdout, stderr
    // on both Windows and POSIX systems
    const stdin = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDIN_FILENO };
    
    const stdout = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else  
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        
    const stderr = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDERR_FILENO };
    
    // Verify we can get writers from these handles
    const stdout_writer = stdout.deprecatedWriter();
    const stderr_writer = stderr.deprecatedWriter();
    
    // Simple write test
    try stdout_writer.writeAll("Test stdout\n");
    try stderr_writer.writeAll("Test stderr\n");
    
    // Verify stdin reader works
    var read_buf: [1024]u8 = undefined;
    _ = stdin.reader(&read_buf);
}