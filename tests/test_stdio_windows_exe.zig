const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    // Get stdio handles in a cross-platform way
    const stdout = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = try std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    const stderr = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = try std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) }
    else
        std.fs.File{ .handle = std.posix.STDERR_FILENO };

    // Write test output that the Wine test will look for
    try stdout.writeAll("Test stdout\n");
    try stderr.writeAll("Test stderr\n");
    
    // Exit successfully
    std.process.exit(0);
}