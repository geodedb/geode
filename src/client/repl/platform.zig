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

// CANARY: REQ=REQ-SHELL-INTERRUPT-010; FEATURE="SourceInterrupt"; ASPECT=SignalHandler; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-30
// Global atomic flag for SIGINT (Ctrl+C) - set by signal handler, checked by blocking operations
pub var sigint_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Check if SIGINT (Ctrl+C) has been received and clear the flag
pub fn checkAndClearSigint() bool {
    return sigint_received.swap(false, .seq_cst);
}

/// Check if SIGINT (Ctrl+C) has been received without clearing
pub fn wasSigintReceived() bool {
    return sigint_received.load(.seq_cst);
}

/// Clear the SIGINT flag
pub fn clearSigint() void {
    sigint_received.store(false, .seq_cst);
}

/// Install signal handlers for graceful Ctrl+C handling
pub fn installSignalHandlers() void {
    if (builtin.os.tag == .windows) {
        // Windows: Use SetConsoleCtrlHandler
        _ = std.os.windows.kernel32.SetConsoleCtrlHandler(&windowsCtrlHandler, 1);
    } else {
        // POSIX: Use sigaction for SIGINT
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = posixSigintHandler },
            .mask = std.mem.zeroes(std.posix.sigset_t), // Empty signal mask (cross-platform)
            .flags = 0,
        };
        _ = std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    }
}

/// Restore default signal handlers
pub fn restoreSignalHandlers() void {
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleCtrlHandler(&windowsCtrlHandler, 0);
    } else {
        var sa: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.mem.zeroes(std.posix.sigset_t), // Empty signal mask (cross-platform)
            .flags = 0,
        };
        _ = std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    }
}

// POSIX signal handler for SIGINT
fn posixSigintHandler(_: c_int) callconv(.c) void {
    sigint_received.store(true, .seq_cst);
}

// Windows console control handler
fn windowsCtrlHandler(dwCtrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    if (dwCtrlType == 0) { // CTRL_C_EVENT
        sigint_received.store(true, .seq_cst);
        return 1; // TRUE - we handled it
    }
    return 0; // FALSE - let default handler process it
}
