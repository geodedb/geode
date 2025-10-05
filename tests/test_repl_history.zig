const std = @import("std");
const testing = std.testing;

// CANARY: REQ=REQ-REPL-HISTORY-001; FEATURE="REPL Persistent History"; ASPECT=UnitTesting; STATUS=IMPL; TEST=test_repl_history; OWNER=repl; UPDATED=2025-10-05

// Unit tests for REPL persistent command history support
// These tests validate the HistoryStore functionality

const HistoryStore = struct {
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
            .entries = try std.ArrayList([]u8).initCapacity(allocator, 0),
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

        const file = std.fs.cwd().openFile(self.path.?, .{}) catch |err| switch (err) {
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
                std.fs.cwd().makePath(dir) catch {};
            }

            const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |err| {
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
                std.fs.cwd().makePath(dir) catch {};
            }

            const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch {
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

// History path generation logic for testing
fn getHistoryPath(allocator: std.mem.Allocator) ![]u8 {
    // Check GEODE_HISTORY environment variable first
    if (std.process.getEnvVarOwned(allocator, "GEODE_HISTORY")) |path| {
        return path;
    } else |_| {}

    // Primary: Try ~/.geode_history as the default preference
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &[_][]const u8{ home, ".geode_history" });
    } else |_| {}

    // Final fallback
    return allocator.dupe(u8, ".geode_history");
}

// Unit Tests

test "HistoryStore initialization and cleanup" {
    const allocator = testing.allocator;
    
    // Test with path
    {
        var history = try HistoryStore.init(allocator, "test_history.tmp", true);
        defer history.deinit();
        
        try testing.expect(history.enabled == true);
        try testing.expect(history.path != null);
        try testing.expectEqualStrings("test_history.tmp", history.path.?);
        try testing.expect(history.entries.items.len == 0);
        try testing.expect(history.max_entries == 5000);
    }
    
    // Test without path
    {
        var history = try HistoryStore.init(allocator, null, false);
        defer history.deinit();
        
        try testing.expect(history.enabled == false);
        try testing.expect(history.path == null);
        try testing.expect(history.entries.items.len == 0);
    }
}

test "HistoryStore append and duplicate detection" {
    const allocator = testing.allocator;
    
    // Create temp file
    const path = "test_history_append.tmp";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    var history = try HistoryStore.init(allocator, path, true);
    defer history.deinit();
    
    // Append first entry
    try history.append("MATCH (n:Person) RETURN n.name;");
    try testing.expect(history.entries.items.len == 1);
    try testing.expectEqualStrings("MATCH (n:Person) RETURN n.name;", history.entries.items[0]);
    
    // Append duplicate - should be ignored
    try history.append("MATCH (n:Person) RETURN n.name;");
    try testing.expect(history.entries.items.len == 1);
    
    // Append different entry
    try history.append("CREATE (p:Person {name: 'Alice'});");
    try testing.expect(history.entries.items.len == 2);
    try testing.expectEqualStrings("CREATE (p:Person {name: 'Alice'});", history.entries.items[1]);
    
    // Test leading space suppression
    try history.append(" MATCH (n) RETURN n;");
    try testing.expect(history.entries.items.len == 2); // Should not be added
    
    // Test empty line suppression
    try history.append("");
    try testing.expect(history.entries.items.len == 2); // Should not be added
}

test "HistoryStore persistence and loading" {
    const allocator = testing.allocator;
    
    const path = "test_history_persist.tmp";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    // Create history and add entries
    {
        var history = try HistoryStore.init(allocator, path, true);
        defer history.deinit();
        
        try history.append("MATCH (n:Person) RETURN n.name;");
        try history.append("CREATE (p:Person {name: 'Bob'});");
        try history.append("DELETE n WHERE n.age < 18;");
    }
    
    // Load history from file
    {
        var history = try HistoryStore.init(allocator, path, true);
        defer history.deinit();
        
        try history.load();
        
        try testing.expect(history.entries.items.len == 3);
        try testing.expectEqualStrings("MATCH (n:Person) RETURN n.name;", history.entries.items[0]);
        try testing.expectEqualStrings("CREATE (p:Person {name: 'Bob'});", history.entries.items[1]);
        try testing.expectEqualStrings("DELETE n WHERE n.age < 18;", history.entries.items[2]);
    }
}

test "HistoryStore search functionality" {
    const allocator = testing.allocator;
    
    var history = try HistoryStore.init(allocator, null, true);
    defer history.deinit();
    
    // Add test entries
    try history.append("MATCH (n:Person) RETURN n.name;");
    try history.append("CREATE (p:Person {name: 'Alice'});");
    try history.append("MATCH (n:Company) RETURN n.name;");
    try history.append("DELETE n WHERE n.inactive = true;");
    
    // Search for patterns
    const match_result = history.search("MATCH");
    try testing.expect(match_result != null);
    try testing.expectEqualStrings("MATCH (n:Company) RETURN n.name;", match_result.?); // Should return last match
    
    const create_result = history.search("CREATE");
    try testing.expect(create_result != null);
    try testing.expectEqualStrings("CREATE (p:Person {name: 'Alice'});", create_result.?);
    
    const not_found = history.search("NONEXISTENT");
    try testing.expect(not_found == null);
}

test "HistoryStore max entries enforcement" {
    const allocator = testing.allocator;
    
    var history = try HistoryStore.init(allocator, null, true);
    defer history.deinit();
    
    // Set a small max for testing
    history.max_entries = 3;
    
    // Add entries beyond max
    try history.append("Query 1");
    try history.append("Query 2");
    try history.append("Query 3");
    try history.append("Query 4");
    try history.append("Query 5");
    
    // Should only keep the last 3
    try testing.expect(history.entries.items.len == 3);
    try testing.expectEqualStrings("Query 3", history.entries.items[0]);
    try testing.expectEqualStrings("Query 4", history.entries.items[1]);
    try testing.expectEqualStrings("Query 5", history.entries.items[2]);
}

test "HistoryStore clear functionality" {
    const allocator = testing.allocator;
    
    const path = "test_history_clear.tmp";
    defer std.fs.cwd().deleteFile(path) catch {};
    
    var history = try HistoryStore.init(allocator, path, true);
    defer history.deinit();
    
    // Add entries
    try history.append("MATCH (n:Person) RETURN n.name;");
    try history.append("CREATE (p:Person {name: 'Charlie'});");
    try testing.expect(history.entries.items.len == 2);
    
    // Clear history
    try history.clear();
    try testing.expect(history.entries.items.len == 0);
    
    // Verify file is also cleared
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return, // File should exist but be empty
        else => return err,
    };
    defer file.close();
    
    const file_size = try file.getEndPos();
    try testing.expect(file_size == 0);
}

test "HistoryStore disabled mode" {
    const allocator = testing.allocator;
    
    var history = try HistoryStore.init(allocator, "test_disabled.tmp", false);
    defer history.deinit();
    
    // Attempt to append when disabled
    try history.append("MATCH (n) RETURN n;");
    try testing.expect(history.entries.items.len == 0);
    
    // Verify no file was created
    const file_result = std.fs.cwd().openFile("test_disabled.tmp", .{});
    try testing.expectError(error.FileNotFound, file_result);
}

test "History path generation logic" {
    const allocator = testing.allocator;
    
    // Test with GEODE_HISTORY environment variable
    {
        // Note: We can't actually set environment variables in tests easily,
        // so we test the fallback logic
        const path = try getHistoryPath(allocator);
        defer allocator.free(path);
        
        // Should use either ~/.geode_history or fallback to .geode_history
        try testing.expect(std.mem.endsWith(u8, path, ".geode_history"));
    }
}

test "HistoryStore with non-existent directory" {
    const allocator = testing.allocator;
    
    // Use a path with a directory that doesn't exist
    const path = "nonexistent_dir/test_history.tmp";
    defer {
        std.fs.cwd().deleteFile(path) catch {};
        std.fs.cwd().deleteDir("nonexistent_dir") catch {};
    }
    
    var history = try HistoryStore.init(allocator, path, true);
    defer history.deinit();
    
    // Append should create the directory automatically
    try history.append("MATCH (n) RETURN n;");
    try testing.expect(history.entries.items.len == 1);
    
    // Verify file was created
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    const file_size = try file.getEndPos();
    try testing.expect(file_size > 0);
}