const std = @import("std");
const builtin = @import("builtin");

// CANARY: REQ=REQ-QUALITY-GAP-406-007; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
// Cross-platform stdio handles with proper error handling
// These functions exit on failure since failing to get stdio handles is fatal for a REPL
pub fn getStdinHandle() std.fs.File {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch |err| {
            std.debug.print("Fatal: Cannot get stdin handle: {}\n", .{err});
            std.process.exit(1);
        };
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            std.debug.print("Fatal: Invalid stdin handle\n", .{});
            std.process.exit(1);
        }
        return std.fs.File{ .handle = handle };
    } else {
        return std.fs.File{ .handle = std.posix.STDIN_FILENO };
    }
}

pub fn getStdoutHandle() std.fs.File {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch |err| {
            std.debug.print("Fatal: Cannot get stdout handle: {}\n", .{err});
            std.process.exit(1);
        };
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            std.debug.print("Fatal: Invalid stdout handle\n", .{});
            std.process.exit(1);
        }
        return std.fs.File{ .handle = handle };
    } else {
        return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    }
}

pub fn getStderrHandle() std.fs.File {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch |err| {
            // Can't print to stderr if we can't get stderr handle, just exit
            _ = err;
            std.process.exit(1);
        };
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            std.process.exit(1);
        }
        return std.fs.File{ .handle = handle };
    } else {
        return std.fs.File{ .handle = std.posix.STDERR_FILENO };
    }
}

pub fn isStdinTty() bool {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return false;
        var mode: std.os.windows.DWORD = undefined;
        return std.os.windows.kernel32.GetConsoleMode(handle, &mode) != 0;
    } else {
        return std.posix.isatty(std.posix.STDIN_FILENO);
    }
}

pub fn isStdoutTty() bool {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch return false;
        var mode: std.os.windows.DWORD = undefined;
        return std.os.windows.kernel32.GetConsoleMode(handle, &mode) != 0;
    } else {
        return std.posix.isatty(std.posix.STDOUT_FILENO);
    }
}
