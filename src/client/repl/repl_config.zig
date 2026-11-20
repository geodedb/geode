const std = @import("std");

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}
const builtin = @import("builtin");

// CANARY: REQ=REQ-SONNY-6551-REPL-HISTORY-SECRETS; FEATURE="REPL history"; ASPECT=AbsoluteHistoryPathOnly; STATUS=TESTED; TEST=tests/test_sonny6551_repl_history.zig; OWNER=cli; UPDATED=2026-11-14
/// Where the shell keeps its history, or why it keeps none.
pub const HistoryPath = union(enum) {
    /// Owned by the caller.
    path: []u8,
    unavailable: []const u8,
};

/// SONNY-6551: `GEODE_HISTORY`, else `<HOME>/.geode_history` (USERPROFILE
/// on Windows when HOME is unset), each only when it is an absolute path:
/// the CLI's HOME rule (src/cli/security/home_dir.zig, SONNY-6544). A
/// relative HOME, and the old fallback of `.geode_history` in the working
/// directory, wrote the history (statements, user names) wherever the shell
/// was started; with no usable path there is no history file.
pub fn getHistoryPath(allocator: std.mem.Allocator) !HistoryPath {
    if (posixGetenv("GEODE_HISTORY")) |path| {
        if (path.len > 0 and std.fs.path.isAbsolute(path)) return .{ .path = try allocator.dupe(u8, path) };
        return .{ .unavailable = "GEODE_HISTORY is not an absolute path" };
    }
    const home: ?[:0]const u8 = posixGetenv("HOME") orelse
        if (builtin.os.tag == .windows) posixGetenv("USERPROFILE") else null;
    if (home) |h| {
        if (h.len > 0 and std.fs.path.isAbsolute(h)) {
            return .{ .path = try std.fs.path.join(allocator, &[_][]const u8{ h, ".geode_history" }) };
        }
    }
    return .{ .unavailable = "HOME is not set or not an absolute path" };
}
