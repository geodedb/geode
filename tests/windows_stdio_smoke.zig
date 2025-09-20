const std = @import("std");
const builtin = @import("builtin");

// Simple standalone program to test stdout/stderr emission on Windows when cross-compiled
// and executed via Wine. Avoids using `zig test` harness which may embed metadata that
// confuses some Wine configurations when cross compiled with --test-no-exec.

fn writeAllStdout(bytes: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const handle = w.GetStdHandle(w.STD_OUTPUT_HANDLE) catch return error.Unexpected;
        var written: w.DWORD = 0;
        if (w.kernel32.WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null) == 0) return error.Unexpected;
        if (written != bytes.len) return error.Unexpected;
    } else {
        var slice = bytes;
        while (slice.len > 0) {
            const n = try std.posix.write(std.posix.STDOUT_FILENO, slice);
            slice = slice[n..];
        }
    }
}

fn writeAllStderr(bytes: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const handle = w.GetStdHandle(w.STD_ERROR_HANDLE) catch return error.Unexpected;
        var written: w.DWORD = 0;
        if (w.kernel32.WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null) == 0) return error.Unexpected;
        if (written != bytes.len) return error.Unexpected;
    } else {
        var slice = bytes;
        while (slice.len > 0) {
            const n = try std.posix.write(std.posix.STDERR_FILENO, slice);
            slice = slice[n..];
        }
    }
}

pub fn main() !void {
    try writeAllStdout("Test stdout\n");
    try writeAllStderr("Test stderr\n");
}
