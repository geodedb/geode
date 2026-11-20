const std = @import("std");
const builtin = @import("builtin");
const dsn_credentials = @import("../dsn_credentials.zig");

// CANARY: REQ=REQ-SONNY-6551-REPL-HISTORY-SECRETS; FEATURE="REPL history"; ASPECT=NoCredentialsInHistory; STATUS=TESTED; TEST=tests/test_sonny6551_repl_history.zig; OWNER=cli; UPDATED=2026-11-14
/// SONNY-6551: words that mark a line as carrying a credential, matched
/// case-insensitively anywhere in it. mysql's rule (its client keeps lines
/// matching `*IDENTIFIED*:*PASSWORD*` out of its history): such a line is not
/// recorded at all, in memory or in the file. It covers `CREATE USER` /
/// `ALTER USER ... SET PASSWORD` and the procedures that take a password
/// (`geode.auth.user_change_password`, `user_reset_password`), TOTP secrets
/// and codes (`geode.auth.mfa_*`), and `geode.auth.user_create` /
/// `user_import`, whose arguments include a password.
const secret_markers = [_][]const u8{
    "password",
    "identified",
    "secret",
    "geode.auth.user_create",
    "geode.auth.user_import",
    "geode.auth.mfa_",
};

fn carriesSecret(line: []const u8) bool {
    for (secret_markers) |marker| {
        if (std.ascii.findIgnoreCase(line, marker) != null) return true;
    }
    return false;
}

/// SONNY-6551: what the history records for `line`, owned by the caller;
/// null when nothing is recorded. `\connect <address>` (or `/connect`) is
/// recorded with its address redacted (`dsn_credentials.redacted`: no
/// userinfo, secret query values masked); a line that carries a credential
/// (`secret_markers`) is not recorded.
pub fn historyEntry(allocator: std.mem.Allocator, line: []const u8) !?[]u8 {
    if (line.len > 1 and (line[0] == '\\' or line[0] == '/')) {
        const body = line[1..];
        const space = std.mem.indexOfAny(u8, body, " \t");
        const cmd = if (space) |i| body[0..i] else body;
        if (std.mem.eql(u8, cmd, "connect")) {
            const args = std.mem.trim(u8, if (space) |i| body[i..] else "", " \t");
            if (args.len == 0) return try allocator.dupe(u8, line);
            return try std.fmt.allocPrint(allocator, "{c}connect {f}", .{ line[0], dsn_credentials.redacted(args) });
        }
    }
    if (carriesSecret(line)) return null;
    return try allocator.dupe(u8, line);
}

/// SONNY-6551: the history file is private (0600), like a shell's
/// `~/.bash_history`; an existing file with group or other access is
/// tightened when it is opened.
const history_file_mode: std.posix.mode_t = 0o600;

pub const HistoryStore = struct {
    allocator: std.mem.Allocator,
    path: ?[]u8,
    enabled: bool,
    entries: std.ArrayList([]u8),
    max_entries: usize = 5000,
    file_mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8, enabled: bool) !HistoryStore {
        var store = HistoryStore{
            .allocator = allocator,
            .path = null,
            .enabled = enabled,
            .entries = std.ArrayList([]u8).empty,
        };

        if (path) |p| {
            store.path = try allocator.dupe(u8, p);
        }

        return store;
    }

    pub fn deinit(self: *HistoryStore) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);

        if (self.path) |p| {
            self.allocator.free(p);
        }
    }

    pub fn load(self: *HistoryStore) !void {
        if (!self.enabled or self.path == null) return;

        self.file_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.file_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), self.path.?, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(std.Io.Threaded.global_single_threaded.io());
        file.setPermissions(std.Io.Threaded.global_single_threaded.io(), std.Io.File.Permissions.fromMode(history_file_mode)) catch {};

        // Read entire file
        const file_size = try file.length(std.Io.Threaded.global_single_threaded.io());
        const content = try self.allocator.alloc(u8, @intCast(file_size));
        defer self.allocator.free(content);
        _ = try file.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), content, 0);

        // Split into lines
        var it = std.mem.tokenizeScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len > 0) {
                const entry = try self.allocator.dupe(u8, line);
                try self.entries.append(self.allocator, entry);

                // Enforce max entries
                if (self.entries.items.len > self.max_entries) {
                    const old = self.entries.orderedRemove(0);
                    self.allocator.free(old);
                }
            }
        }
    }

    pub fn append(self: *HistoryStore, line: []const u8) !void {
        if (!self.enabled) return;

        // Skip leading-space lines
        if (line.len > 0 and line[0] == ' ') return;

        // Skip empty lines
        if (line.len == 0) return;

        // SONNY-6551: a credential never reaches the history.
        const entry = (try historyEntry(self.allocator, line)) orelse return;
        var entry_owned = true;
        defer if (entry_owned) self.allocator.free(entry);

        // Check for duplicate
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, entry)) return;
        }

        // Add to memory
        try self.entries.append(self.allocator, entry);
        entry_owned = false;

        // Enforce max entries
        if (self.entries.items.len > self.max_entries) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old);
        }

        // Persist to file
        if (self.path) |path| {
            self.file_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.file_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

            // Ensure directory exists
            if (std.fs.path.dirname(path)) |dir| {
                std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
            }

            const file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{
                .truncate = false,
                .permissions = std.Io.File.Permissions.fromMode(history_file_mode),
            }) catch |err| {
                // If we can't save history, just continue without persisting
                if (err == error.FileNotFound) return;
                return err;
            };
            const rh_io = std.Io.Threaded.global_single_threaded.io();
            defer file.close(rh_io);
            try file.setPermissions(rh_io, std.Io.File.Permissions.fromMode(history_file_mode));

            const rh_stat = try file.stat(rh_io);
            try file.writePositionalAll(rh_io, entry, rh_stat.size);
            try file.writePositionalAll(rh_io, "\n", rh_stat.size + entry.len);
        }
    }

    pub fn clear(self: *HistoryStore) !void {
        // Clear memory
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.clearRetainingCapacity();

        // Clear file
        if (self.path) |path| {
            self.file_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.file_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

            // Ensure directory exists
            if (std.fs.path.dirname(path)) |dir| {
                std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
            }

            const file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{
                .truncate = true,
                .permissions = std.Io.File.Permissions.fromMode(history_file_mode),
            }) catch {
                // If we can't clear the file, just continue
                return;
            };
            file.setPermissions(std.Io.Threaded.global_single_threaded.io(), std.Io.File.Permissions.fromMode(history_file_mode)) catch {};
            file.close(std.Io.Threaded.global_single_threaded.io());
        }
    }

    pub fn search(self: *HistoryStore, pattern: []const u8) ?[]const u8 {
        var i = self.entries.items.len;
        while (i > 0) : (i -= 1) {
            const entry = self.entries.items[i - 1];
            if (std.mem.indexOf(u8, entry, pattern)) |_| {
                return entry;
            }
        }
        return null;
    }
};

test "history leading-space suppression" {
    const allocator = std.testing.allocator;

    // A history file in a private temp directory (it was test_history.tmp
    // in the working directory).
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/history", .{&tmp.sub_path});
    defer allocator.free(path);

    var history = try HistoryStore.init(allocator, path, true);
    defer history.deinit();

    // Append with leading space - should be ignored
    try history.append(" SELECT 1;");
    try std.testing.expect(history.entries.items.len == 0);

    // Append without leading space - should be saved
    try history.append("SELECT 1;");
    try std.testing.expect(history.entries.items.len == 1);
    try std.testing.expectEqualStrings("SELECT 1;", history.entries.items[0]);

    // Verify file content
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(100));
    defer allocator.free(content);
    try std.testing.expectEqualStrings("SELECT 1;\n", content);
}

test "SONNY-6551: lines that set a password are not recorded; \\connect is recorded without its userinfo" {
    const allocator = std.testing.allocator;
    const skipped = [_][]const u8{
        "CREATE USER bob SET PASSWORD 'Alpha Bravo Charlie Delta'",
        "alter user bob set password 'Alpha Bravo Charlie Delta'",
        "CALL geode.auth.user_change_password('bob', 'old one', 'new one')",
        "CALL geode.auth.user_create('bob', 'Alpha Bravo Charlie Delta')",
        "CALL GEODE.AUTH.MFA_VERIFY('bob', '123456')",
        "CREATE USER bob IDENTIFIED BY 'x'",
    };
    for (skipped) |line| {
        try std.testing.expect((try historyEntry(allocator, line)) == null);
    }
    const kept = [_][]const u8{ "RETURN 1 AS x", "MATCH (n:Person) RETURN n.name", "\\graphs", "\\connect" };
    for (kept) |line| {
        const got = (try historyEntry(allocator, line)).?;
        defer allocator.free(got);
        try std.testing.expectEqualStrings(line, got);
    }
    const connects = [_][2][]const u8{
        .{ "\\connect geode:s3cr@t@127.0.0.1:3141", "\\connect 127.0.0.1:3141" },
        .{ "/connect  quic://admin:pw@[::1]:3141/g", "/connect quic://[::1]:3141/g" },
        .{ "\\connect localhost:3141?user=a&pass=hunter2", "\\connect localhost:3141?user=a&pass=***" },
    };
    for (connects) |c| {
        const got = (try historyEntry(allocator, c[0])).?;
        defer allocator.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}
