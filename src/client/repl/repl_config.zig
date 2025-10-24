const std = @import("std");
const builtin = @import("builtin");

pub fn getHistoryPath(allocator: std.mem.Allocator) ![]u8 {
    // Check GEODE_HISTORY environment variable first
    if (std.process.getEnvVarOwned(allocator, "GEODE_HISTORY")) |path| {
        return path;
    } else |_| {}

    // Primary: Try ~/.geode_history as the default preference
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &[_][]const u8{ home, ".geode_history" });
    } else |_| {}

    // Secondary: Use platform-specific conventions as fallback
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
            defer allocator.free(appdata);
            return std.fs.path.join(allocator, &[_][]const u8{ appdata, "geode", "history" });
        } else |_| {}
    } else if (builtin.os.tag == .macos) {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "Application Support", "geode", "history" });
        } else |_| {}
    } else {
        // Linux/Unix - use XDG as secondary fallback
        if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |xdg| {
            defer allocator.free(xdg);
            return std.fs.path.join(allocator, &[_][]const u8{ xdg, "geode", "history" });
        } else |_| {
            if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                return std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "share", "geode", "history" });
            } else |_| {}
        }
    }

    // Final fallback
    return allocator.dupe(u8, ".geode_history");
}

/// P2-3: Static GPA for env var check
var color_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var color_gpa_init = false;

pub fn shouldUseColor() bool {
    // P2-3: Use static GPA for env var check
    if (!color_gpa_init) {
        color_gpa_init = true;
    }
    // Check NO_COLOR environment variable
    if (std.process.getEnvVarOwned(color_gpa.allocator(), "NO_COLOR")) |val| {
        color_gpa.allocator().free(val);
        return false;
    } else |_| {}

    // Check if stdout is a TTY
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
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

        const file = std.fs.cwd().openFile(config_path, .{}) catch {
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
        try std.fs.cwd().makePath(dir_path);

        const file = try std.fs.cwd().createFile(config_path, .{});
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
    // Check GEODE_CONFIG environment variable
    if (std.process.getEnvVarOwned(allocator, "GEODE_CONFIG")) |path| {
        return path;
    } else |_| {}

    // Use XDG_CONFIG_HOME / macOS / Windows conventions
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "APPDATA")) |appdata| {
            defer allocator.free(appdata);
            return std.fs.path.join(allocator, &[_][]const u8{ appdata, "geode", "config" });
        } else |_| {}
    } else if (builtin.os.tag == .macos) {
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            return std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "Preferences", "geode.conf" });
        } else |_| {}
    } else {
        // Linux/Unix - use XDG
        if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
            defer allocator.free(xdg);
            return std.fs.path.join(allocator, &[_][]const u8{ xdg, "geode", "config" });
        } else |_| {
            if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                return std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "geode", "config" });
            } else |_| {}
        }
    }

    // Fallback
    return allocator.dupe(u8, ".geode_config");
}
