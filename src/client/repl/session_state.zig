const std = @import("std");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// CANARY: REQ=REQ-REPL-SESSION-001; FEATURE="REPL Session Persistence"; ASPECT=Implementation; STATUS=TESTED; TEST=test_session_state; OWNER=repl; UPDATED=2025-11-17

/// Session state that can be persisted
pub const SessionState = struct {
    /// Current working database
    database: ?[]const u8 = null,

    /// Active transaction state
    in_transaction: bool = false,

    /// Output format preference
    format: Format = .table,

    /// Timing display preference
    show_timing: bool = false,

    /// Keymap preference
    keymap: Keymap = .emacs,

    /// Last server connection
    last_server: ?[]const u8 = null,

    /// Custom variables
    variables: std.StringHashMap([]const u8),

    pub const Format = enum { table, csv, json };
    pub const Keymap = enum { emacs, vi };

    pub fn init(allocator: std.mem.Allocator) SessionState {
        return .{
            .variables = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *SessionState, allocator: std.mem.Allocator) void {
        if (self.database) |db| allocator.free(db);
        if (self.last_server) |server| allocator.free(server);

        var it = self.variables.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.variables.deinit();
    }

    /// Save session state to file
    pub fn save(self: *const SessionState, allocator: std.mem.Allocator, path: []const u8) !void {
        // Create JSON representation
        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        try json.appendSlice(allocator, "{\n");

        // Database
        try json.appendSlice(allocator, "  \"database\": ");
        if (self.database) |db| {
            try json.appendSlice(allocator, "\"");
            try json.appendSlice(allocator, db);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, "null");
        }
        try json.appendSlice(allocator, ",\n");

        // Transaction state
        var buf: [256]u8 = undefined;
        const txn_line = try std.fmt.bufPrint(&buf, "  \"in_transaction\": {s},\n", .{if (self.in_transaction) "true" else "false"});
        try json.appendSlice(allocator, txn_line);

        // Format
        const format_str = switch (self.format) {
            .table => "table",
            .csv => "csv",
            .json => "json",
        };
        const format_line = try std.fmt.bufPrint(&buf, "  \"format\": \"{s}\",\n", .{format_str});
        try json.appendSlice(allocator, format_line);

        // Timing
        const timing_line = try std.fmt.bufPrint(&buf, "  \"show_timing\": {s},\n", .{if (self.show_timing) "true" else "false"});
        try json.appendSlice(allocator, timing_line);

        // Keymap
        const keymap_str = switch (self.keymap) {
            .emacs => "emacs",
            .vi => "vi",
        };
        const keymap_line = try std.fmt.bufPrint(&buf, "  \"keymap\": \"{s}\",\n", .{keymap_str});
        try json.appendSlice(allocator, keymap_line);

        // Last server
        try json.appendSlice(allocator, "  \"last_server\": ");
        if (self.last_server) |server| {
            try json.appendSlice(allocator, "\"");
            try json.appendSlice(allocator, server);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, "null");
        }
        try json.appendSlice(allocator, ",\n");

        // Variables
        try json.appendSlice(allocator, "  \"variables\": {\n");
        var it = self.variables.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try json.appendSlice(allocator, ",\n");
            first = false;
            try json.appendSlice(allocator, "    \"");
            try json.appendSlice(allocator, entry.key_ptr.*);
            try json.appendSlice(allocator, "\": \"");
            try json.appendSlice(allocator, entry.value_ptr.*);
            try json.appendSlice(allocator, "\"");
        }
        try json.appendSlice(allocator, "\n  }\n");

        try json.appendSlice(allocator, "}\n");

        // Write to file
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_fs, path, .{});
        defer file.close(io_fs);
        try file.writeStreamingAll(io_fs, json.items);
    }

    /// Load session state from file
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !SessionState {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io_fs, path, .{});
        defer file.close(io_fs);

        var file_reader_buf: [4096]u8 = undefined;
        var file_reader = file.reader(io_fs, &file_reader_buf);
        const content = try file_reader.interface.allocRemaining(allocator, .limited(1 << 20)); // 1MB max
        defer allocator.free(content);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        var state = SessionState.init(allocator);
        errdefer state.deinit(allocator);

        // Database
        if (root.get("database")) |db_value| {
            if (db_value != .null) {
                state.database = try allocator.dupe(u8, db_value.string);
            }
        }

        // Transaction state
        if (root.get("in_transaction")) |txn_value| {
            state.in_transaction = txn_value.bool;
        }

        // Format
        if (root.get("format")) |format_value| {
            const format_str = format_value.string;
            if (std.mem.eql(u8, format_str, "table")) {
                state.format = .table;
            } else if (std.mem.eql(u8, format_str, "csv")) {
                state.format = .csv;
            } else if (std.mem.eql(u8, format_str, "json")) {
                state.format = .json;
            }
        }

        // Timing
        if (root.get("show_timing")) |timing_value| {
            state.show_timing = timing_value.bool;
        }

        // Keymap
        if (root.get("keymap")) |keymap_value| {
            const keymap_str = keymap_value.string;
            if (std.mem.eql(u8, keymap_str, "emacs")) {
                state.keymap = .emacs;
            } else if (std.mem.eql(u8, keymap_str, "vi")) {
                state.keymap = .vi;
            }
        }

        // Last server
        if (root.get("last_server")) |server_value| {
            if (server_value != .null) {
                state.last_server = try allocator.dupe(u8, server_value.string);
            }
        }

        // Variables
        if (root.get("variables")) |vars_value| {
            const vars = vars_value.object;
            var it = vars.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const value = try allocator.dupe(u8, entry.value_ptr.*.string);
                errdefer allocator.free(value);
                try state.variables.put(key, value);
            }
        }

        return state;
    }
};

test "SessionState save and load" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmpDirRealpathAlloc(allocator, &tmp_dir.sub_path);
    defer allocator.free(tmp_path);

    const session_file = try std.fs.path.join(allocator, &.{ tmp_path, "test_session.json" });
    defer allocator.free(session_file);

    // Create session
    var state = SessionState.init(allocator);
    defer state.deinit(allocator);

    state.database = try allocator.dupe(u8, "mydb");
    state.in_transaction = true;
    state.format = .csv;
    state.show_timing = true;
    state.keymap = .vi;
    state.last_server = try allocator.dupe(u8, "localhost:3141");

    try state.variables.put(try allocator.dupe(u8, "foo"), try allocator.dupe(u8, "bar"));
    try state.variables.put(try allocator.dupe(u8, "baz"), try allocator.dupe(u8, "qux"));

    // Save
    try state.save(allocator, session_file);

    // Load
    var loaded = try SessionState.load(allocator, session_file);
    defer loaded.deinit(allocator);

    // Verify
    try std.testing.expectEqualStrings("mydb", loaded.database.?);
    try std.testing.expectEqual(true, loaded.in_transaction);
    try std.testing.expectEqual(SessionState.Format.csv, loaded.format);
    try std.testing.expectEqual(true, loaded.show_timing);
    try std.testing.expectEqual(SessionState.Keymap.vi, loaded.keymap);
    try std.testing.expectEqualStrings("localhost:3141", loaded.last_server.?);
    try std.testing.expectEqual(@as(usize, 2), loaded.variables.count());
    try std.testing.expectEqualStrings("bar", loaded.variables.get("foo").?);
    try std.testing.expectEqualStrings("qux", loaded.variables.get("baz").?);
}

test "SessionState handles missing fields" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmpDirRealpathAlloc(allocator, &tmp_dir.sub_path);
    defer allocator.free(tmp_path);

    const session_file = try std.fs.path.join(allocator, &.{ tmp_path, "minimal_session.json" });
    defer allocator.free(session_file);

    // Create minimal session file
    {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_fs, session_file, .{});
        defer file.close(io_fs);
        try file.writeStreamingAll(io_fs, "{\"format\": \"json\"}");
    }

    // Load
    var loaded = try SessionState.load(allocator, session_file);
    defer loaded.deinit(allocator);

    // Verify defaults
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.database);
    try std.testing.expectEqual(false, loaded.in_transaction);
    try std.testing.expectEqual(SessionState.Format.json, loaded.format);
    try std.testing.expectEqual(false, loaded.show_timing);
    try std.testing.expectEqual(SessionState.Keymap.emacs, loaded.keymap);
}
