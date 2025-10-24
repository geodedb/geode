const std = @import("std");
const builtin = @import("builtin");

// Cross-platform stdio file handles
pub fn getStdin() std.fs.File {
    if (builtin.os.tag == .windows) {
        return std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable };
    } else {
        return std.fs.File{ .handle = std.posix.STDIN_FILENO };
    }
}

pub fn getStdout() std.fs.File {
    if (builtin.os.tag == .windows) {
        return std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable };
    } else {
        return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    }
}

pub fn getStderr() std.fs.File {
    if (builtin.os.tag == .windows) {
        return std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable };
    } else {
        return std.fs.File{ .handle = std.posix.STDERR_FILENO };
    }
}

// Check if a file handle is a TTY
pub fn isStdinTty() bool {
    if (builtin.os.tag == .windows) {
        // On Windows, check the console mode
        var mode: std.os.windows.DWORD = undefined;
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return false;
        if (std.os.windows.kernel32.GetConsoleMode(handle, &mode) != 0) {
            return true;
        }
        return false;
    } else {
        return std.posix.isatty(std.posix.STDIN_FILENO);
    }
}
