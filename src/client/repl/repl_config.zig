const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}
const builtin = @import("builtin");
// CANARY: REQ=REQ-LIB-MIGRATION-CONFIG-001; FEATURE="Config Library Migration"; ASPECT=ReplConfigXdg; STATUS=EXEMPT; OWNER=client; UPDATED=2026-01-25
const config_lib = @import("config");

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

pub fn shouldUseColor() bool {
    // Check NO_COLOR environment variable (uses non-owning getenv)
    if (comptime builtin.os.tag != .windows) {
        if (posixGetenv("NO_COLOR") != null) {
            return false;
        }
    }

    // Check if stdout is a TTY
    const stdout = std.Io.File{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    return stdout.isTty();
}

pub const Config = struct {
    keymap: enum { emacs, vi } = .emacs,
    format: enum { table, csv, json } = .table,
    history_enabled: bool = true,
    timing_enabled: bool = false,
    verbose: bool = false,
    colors_enabled: bool = true,

    pub fn load(allocator: std.mem.Allocator) !Config {
        var config = Config{};
        config.colors_enabled = shouldUseColor();

        // Try to load from config file
        const config_path = try getConfigPath(allocator);
        defer allocator.free(config_path);

        const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), config_path, .{}) catch {
            return config;
        };
        defer file.close();

        // Parse simple key=value format
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        var lines = std.mem.tokenize(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_idx| {
                const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
                const value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t");

                if (std.mem.eql(u8, key, "repl.keymap")) {
                    if (std.mem.eql(u8, value, "vi")) {
                        config.keymap = .vi;
                    } else if (std.mem.eql(u8, value, "emacs")) {
                        config.keymap = .emacs;
                    }
                } else if (std.mem.eql(u8, key, "repl.format")) {
                    if (std.mem.eql(u8, value, "csv")) {
                        config.format = .csv;
                    } else if (std.mem.eql(u8, value, "json")) {
                        config.format = .json;
                    } else if (std.mem.eql(u8, value, "table")) {
                        config.format = .table;
                    }
                } else if (std.mem.eql(u8, key, "repl.history")) {
                    config.history_enabled = std.mem.eql(u8, value, "true");
                } else if (std.mem.eql(u8, key, "repl.timing")) {
                    config.timing_enabled = std.mem.eql(u8, value, "true");
                } else if (std.mem.eql(u8, key, "repl.verbose")) {
                    config.verbose = std.mem.eql(u8, value, "true");
                }
            }
        }

        return config;
    }

    pub fn save(self: *const Config, allocator: std.mem.Allocator) !void {
        const config_path = try getConfigPath(allocator);
        defer allocator.free(config_path);

        // Ensure directory exists
        const dir_path = std.fs.path.dirname(config_path) orelse ".";
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir_path);

        const file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), config_path, .{});
        defer file.close();

        const writer = file.writer();
        try writer.print("# Geode REPL Configuration\n", .{});
        try writer.print("repl.keymap={s}\n", .{@tagName(self.keymap)});
        try writer.print("repl.format={s}\n", .{@tagName(self.format)});
        try writer.print("repl.history={s}\n", .{if (self.history_enabled) "true" else "false"});
        try writer.print("repl.timing={s}\n", .{if (self.timing_enabled) "true" else "false"});
        try writer.print("repl.verbose={s}\n", .{if (self.verbose) "true" else "false"});
    }
};

fn getConfigPath(allocator: std.mem.Allocator) ![]u8 {
    // Check GEODE_CONFIG environment variable (user override)
    if (getEnvVarOwned(allocator, "GEODE_CONFIG")) |path| {
        return path;
    } else |_| {}

    // Use XDG-compliant platform-specific config directory
    const config_dir = config_lib.xdg.getConfigDir(allocator, "geode") catch {
        return allocator.dupe(u8, ".geode_config");
    };
    defer allocator.free(config_dir);

    return std.fs.path.join(allocator, &[_][]const u8{ config_dir, "config" });
}
