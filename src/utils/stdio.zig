const std = @import("std");
const builtin = @import("builtin");

pub const StdioError = error{
    StdioUnavailable,
    InvalidHandle,
};

// Cross-platform stdio file handles with proper error handling
// CANARY: REQ=REQ-QUALITY-GAP-406-001; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
pub fn getStdin() StdioError!std.Io.File {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return error.StdioUnavailable;
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.InvalidHandle;
        return std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else {
        return std.Io.File{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };
    }
}

pub fn getStdout() StdioError!std.Io.File {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch return error.StdioUnavailable;
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.InvalidHandle;
        return std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else {
        return std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    }
}

pub fn getStderr() StdioError!std.Io.File {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch return error.StdioUnavailable;
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.InvalidHandle;
        return std.Io.File{ .handle = handle, .flags = .{ .nonblocking = false } };
    } else {
        return std.Io.File{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
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
        return (std.Io.File.stdin().isTty(std.Io.Threaded.global_single_threaded.io()) catch false);
    }
}
