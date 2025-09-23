const std = @import("std");

// Minimal interactive REPL skeleton for initial CANARY promotion.
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=ReplLaunchPrompt; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_ReplLaunchPrompt; OWNER=client; UPDATED=2025-09-23
// CANARY: REQ=REQ-GQL-086; FEATURE="InteractiveRepl"; ASPECT=MultilineBuffering; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_086_MultilineBuffering; OWNER=client; UPDATED=2025-09-23

pub const Repl = struct {
    allocator: std.mem.Allocator,
    // Accumulates lines until a terminator (currently ';') is seen or a blank line after partial input.
    buffer: std.ArrayListUnmanaged(u8) = .{},

    pub fn init(allocator: std.mem.Allocator) Repl {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Repl) void {
        self.buffer.deinit(self.allocator);
    }

    /// Ingest a line (without trailing newline). Returns optional full statement when complete.
    /// Termination rules (initial policy):
    /// 1. Any line containing a ';' (semicolon) finalizes the statement (keeps content up to semicolon, ignores remainder for now)
    /// 2. A blank line when buffer has content finalizes accumulated statement.
    pub fn ingest(self: *Repl, line: []const u8) !?[]const u8 {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
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

    fn finalize(self: *Repl) ![]const u8 {
        const slice = try self.copyBuffer();
        // Reset for next statement.
        self.buffer.clearRetainingCapacity();
        return slice;
    }

    fn copyBuffer(self: *Repl) ![]const u8 {
        const dup = try self.allocator.alloc(u8, self.buffer.items.len);
        std.mem.copyForwards(u8, dup, self.buffer.items);
        return dup;
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var in_mem = std.io.fixedBufferStream("RETURN 1\n");
    var out_buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    try runOnce(in_mem.reader(), fbs.writer());
    try std.testing.expect(std.mem.startsWith(u8, out_buf[0..fbs.pos], "geode> "));
}

test "TestCANARY_REQ_GQL_086_MultilineBuffering basic semicolon termination" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
