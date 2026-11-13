const std = @import("std");
const builtin = @import("builtin");

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
            self.file_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.file_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

            // Ensure directory exists
            if (std.fs.path.dirname(path)) |dir| {
                std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), dir) catch {};
            }

            const file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .truncate = false }) catch |err| {
                // If we can't save history, just continue without persisting
                if (err == error.FileNotFound) return;
                return err;
            };
            const rh_io = std.Io.Threaded.global_single_threaded.io();
            defer file.close(rh_io);

            const rh_stat = try file.stat(rh_io);
            try file.writePositionalAll(rh_io, line, rh_stat.size);
            try file.writePositionalAll(rh_io, "\n", rh_stat.size + line.len);
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

            const file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .truncate = true }) catch {
                // If we can't clear the file, just continue
                return;
            };
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
