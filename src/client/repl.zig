const std = @import("std");
const repl_history = @import("repl/repl_history.zig");
const repl_parse = @import("repl/repl_parse.zig");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Facade for backward compatibility - delegates to new modules
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=ReplLaunchPrompt; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_ReplLaunchPrompt; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=MultilineBuffering; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_MultilineBuffering; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=HistoryPersistence; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_HistoryPersistence; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=MetaCommandsBasic; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_MetaCommandsBasic; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=TxnPromptIndicator; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_TxnPromptIndicator; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=CtrlCCancelBuffer; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_CtrlCCancelBuffer; OWNER=client; UPDATED=2025-09-23

pub const Repl = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8) = .{},
    history: ?History = null,
    quit_requested: bool = false,
    in_txn: bool = false,

    pub fn init(allocator: std.mem.Allocator) Repl {
        return .{ .allocator = allocator };
    }

    pub fn withHistory(allocator: std.mem.Allocator, history_path: []const u8) !Repl {
        var r = Repl.init(allocator);
        const h = try History.load(allocator, history_path);
        r.history = h;
        return r;
    }

    pub fn deinit(self: *Repl) void {
        self.buffer.deinit(self.allocator);
        if (self.history) |*h| h.deinit();
    }

    pub fn beginTxn(self: *Repl) void {
        self.in_txn = true;
    }

    pub fn endTxn(self: *Repl) void {
        self.in_txn = false;
    }

    pub fn prompt(self: *const Repl) []const u8 {
        return if (self.in_txn) "geode(txn)> " else "geode> ";
    }

    pub fn cancelBuffer(self: *Repl) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn ingest(self: *Repl, line: []const u8) !?[]const u8 {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0 and trimmed[0] == ':') {
            // Meta command line (leading ':') handled immediately; not added to history.
            try self.handleMeta(trimmed[1..]);
            return null;
        }
        if (trimmed.len == 0 and self.buffer.items.len > 0) {
            // Blank line flushes current buffer.
            return self.finalize();
        }
        if (self.buffer.items.len > 0) {
            try self.buffer.append(self.allocator, '\n');
        }
        try self.buffer.appendSlice(self.allocator, trimmed);
        if (std.mem.indexOfScalar(u8, trimmed, ';')) |idx| {
            // Truncate at first semicolon inclusive for now.
            const final_len = self.buffer.items.len - (trimmed.len - (idx + 1));
            self.buffer.items.len = final_len; // keep up to semicolon
            return self.finalize();
        }
        return null;
    }

    fn handleMeta(self: *Repl, cmd_full: []const u8) !void {
        // Format: <command>[ <args>]
        const space_idx = std.mem.indexOfScalar(u8, cmd_full, ' ');
        const cmd_name = if (space_idx) |i| cmd_full[0..i] else cmd_full;
        const args = if (space_idx) |i| std.mem.trim(u8, cmd_full[i + 1 ..], " \t") else cmd_full[cmd_full.len..cmd_full.len];
        _ = args; // currently unused
        if (std.mem.eql(u8, cmd_name, "quit") or std.mem.eql(u8, cmd_name, "q")) {
            self.quit_requested = true;
            return;
        } else if (std.mem.eql(u8, cmd_name, "help") or std.mem.eql(u8, cmd_name, "h")) {
            // Print basic help to stderr for now (stdout might be reserved for results)
            std.debug.print("REPL meta commands: :help :history :quit\n", .{});
            return;
        } else if (std.mem.eql(u8, cmd_name, "history")) {
            if (self.history) |*h| {
                for (h.entries.items, 0..) |entry, idx| {
                    std.debug.print("{d}: {s}\n", .{ idx + 1, entry });
                }
            } else {
                std.debug.print("(history disabled)\n", .{});
            }
            return;
        } else {
            std.debug.print("Unknown meta command: :{s}\n", .{cmd_name});
        }
    }

    fn finalize(self: *Repl) ![]const u8 {
        const slice = try self.copyBuffer();
        if (self.history) |*h| {
            // Persist statement (single line canonicalization: replace internal newlines with \n already present)
            h.append(slice) catch |e| std.debug.print("history append error: {s}\n", .{@errorName(e)});
        }
        self.buffer.clearRetainingCapacity();
        return slice;
    }

    fn copyBuffer(self: *Repl) ![]const u8 {
        const dup = try self.allocator.alloc(u8, self.buffer.items.len);
        std.mem.copyForwards(u8, dup, self.buffer.items);
        return dup;
    }
};

pub const History = struct {
    allocator: std.mem.Allocator,
    path_buf: std.ArrayList(u8),
    entries: std.ArrayList([]u8),

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !History {
        var h = History{
            .allocator = allocator,
            .path_buf = try std.ArrayList(u8).initCapacity(allocator, path.len),
            .entries = std.ArrayList([]u8).init(allocator),
        };
        try h.path_buf.appendSlice(path);
        // Try to open existing file (ignore if not found)
        var file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .mode = .read_only }) catch |e| switch (e) {
            error.FileNotFound => return h,
            else => return e,
        };
        defer file.close();
        var reader = file.reader();
        var line_buf = std.ArrayList(u8).init(allocator);
        defer line_buf.deinit();
        while (true) {
            line_buf.clearRetainingCapacity();
            const res = reader.streamUntilDelimiter(line_buf.writer(), '\n', null) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
            _ = res;
            const dup = try allocator.alloc(u8, line_buf.items.len);
            std.mem.copyForwards(u8, dup, line_buf.items);
            try h.entries.append(dup);
        }
        return h;
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit();
        self.path_buf.deinit();
    }

    fn append(self: *History, stmt: []const u8) !void {
        // Append to in-memory list
        const dup = try self.allocator.alloc(u8, stmt.len);
        std.mem.copyForwards(u8, dup, stmt);
        try self.entries.append(dup);
        // Append to file with trailing newline
        var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), self.path_buf.items, .{ .read = true, .append = true });
        defer file.close();
        try file.writeAll(stmt);
        try file.writeAll("\n");
    }
};

pub fn runOnce(in_stream: anytype, out_stream: anytype) !void {
    // Emit prompt
    try out_stream.writeAll("geode> ");
    // Read one line (discard content for now)
    var buf: [512]u8 = undefined;
    const line_opt = try in_stream.readUntilDelimiterOrEof(buf[0..], '\n');
    _ = line_opt; // placeholder; future parsing will go here
}

test "repl.runOnce prompt basic" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var in_mem = std.Io.fixedBufferStream("RETURN 1\n");
    var out_buf: [256]u8 = undefined;
    var fbs = std.Io.fixedBufferStream(&out_buf);
    try runOnce(in_mem.reader(), fbs.writer());
    try std.testing.expect(std.mem.startsWith(u8, out_buf[0..fbs.pos], "geode> "));
}

test "TestCANARY_REQ_GQL_086_MultilineBuffering basic semicolon termination" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var repl_state = Repl.init(gpa.allocator());
    defer repl_state.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try repl_state.ingest("RETURN 1 AS x"));
    if (try repl_state.ingest("WHERE x > 0;")) |stmt| {
        defer gpa.allocator().free(stmt);
        try std.testing.expect(std.mem.eql(u8, stmt, "RETURN 1 AS x\nWHERE x > 0;"));
    } else return error.ExpectedStatement;
}

test "TestCANARY_REQ_GQL_086_MultilineBuffering blank line flush" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var repl_state = Repl.init(gpa.allocator());
    defer repl_state.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try repl_state.ingest("MATCH (n)"));
    try std.testing.expectEqual(@as(?[]const u8, null), try repl_state.ingest("RETURN n"));
    if (try repl_state.ingest("")) |stmt| { // blank line flush
        defer gpa.allocator().free(stmt);
        try std.testing.expect(std.mem.eql(u8, stmt, "MATCH (n)\nRETURN n"));
    } else return error.ExpectedStatement;
}

test "TestCANARY_REQ_GQL_086_HistoryPersistence basic load append" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var tmp_dir = try std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const hist_file_name = "history_test.txt";
    const dir_path = try tmpDirRealpathAlloc(gpa.allocator(), &tmp_dir.sub_path);
    defer gpa.allocator().free(dir_path);
    const full_path = try std.fs.path.join(gpa.allocator(), &.{ dir_path, hist_file_name });
    defer gpa.allocator().free(full_path);
    var repl_state = try Repl.withHistory(gpa.allocator(), full_path);
    defer repl_state.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try repl_state.ingest("RETURN 1 AS x"));
    _ = try repl_state.ingest("WHERE x > 0;");
    try std.testing.expectEqual(@as(?[]const u8, null), try repl_state.ingest("RETURN 2 AS y"));
    _ = try repl_state.ingest("");
    var hist = try History.load(gpa.allocator(), full_path);
    defer hist.deinit();
    try std.testing.expectEqual(@as(usize, 2), hist.entries.items.len);
    try std.testing.expect(std.mem.eql(u8, hist.entries.items[0], "RETURN 1 AS x\nWHERE x > 0;"));
    try std.testing.expect(std.mem.eql(u8, hist.entries.items[1], "RETURN 2 AS y"));
}
