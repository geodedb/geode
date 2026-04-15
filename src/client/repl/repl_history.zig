const std = @import("std");
const builtin = @import("builtin");

pub const HistoryStore = struct {
    allocator: std.mem.Allocator,
    path: ?[]u8,
    enabled: bool,
    entries: std.ArrayList([]u8),
    max_entries: usize = 5000,
    file_mutex: std.Thread.Mutex = .{},

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

        self.file_mutex.lock();
        defer self.file_mutex.unlock();

        const file = std.Io.Dir.cwd().openFile(self.path.?, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        // Read entire file
        const file_size = try file.getEndPos();
        const content = try self.allocator.alloc(u8, @intCast(file_size));
        defer self.allocator.free(content);
        _ = try file.read(content);

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

        // Check for duplicate
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }

        // Add to memory
        const entry = try self.allocator.dupe(u8, line);
        try self.entries.append(self.allocator, entry);

        // Enforce max entries
        if (self.entries.items.len > self.max_entries) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old);
        }

        // Persist to file
        if (self.path) |path| {
            self.file_mutex.lock();
            defer self.file_mutex.unlock();

            // Ensure directory exists
            if (std.fs.path.dirname(path)) |dir| {
                std.Io.Dir.cwd().makePath(dir) catch {};
            }

            const file = std.Io.Dir.cwd().createFile(path, .{ .truncate = false }) catch |err| {
                // If we can't save history, just continue without persisting
                if (err == error.FileNotFound) return;
                return err;
            };
            defer file.close();

            try file.seekFromEnd(0);
            try file.writeAll(line);
            try file.writeAll("\n");
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
            self.file_mutex.lock();
            defer self.file_mutex.unlock();

            // Ensure directory exists
            if (std.fs.path.dirname(path)) |dir| {
                std.Io.Dir.cwd().makePath(dir) catch {};
            }

            const file = std.Io.Dir.cwd().createFile(path, .{ .truncate = true }) catch {
                // If we can't clear the file, just continue
                return;
            };
            file.close();
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

    // Create temp file
    const path = "test_history.tmp";
    defer std.Io.Dir.cwd().deleteFile(path) catch {};

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
    const file = try std.Io.Dir.cwd().openFile(path, .{});
    defer file.close();

    var buf: [100]u8 = undefined;
    const n = try file.read(&buf);
    try std.testing.expectEqualStrings("SELECT 1;\n", buf[0..n]);
}
