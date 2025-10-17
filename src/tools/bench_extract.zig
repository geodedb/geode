const std = @import("std");
const builtin = @import("builtin");

// CANARY: REQ=REQ-GQL-010; FEATURE="Benchmark Extraction"; ASPECT=Tooling; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_BenchExtractParse; OWNER=engine; UPDATED=2025-09-20
// Reads stdin and emits JSON lines for recognized benchmark prefixes.

pub fn main() !void {
    // P2-3: Use GeneralPurposeAllocator for tool main
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const ally = gpa_instance.allocator();
    var stdin_file = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var stdout_file = if (builtin.os.tag == .windows)
        std.fs.File{ .handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable }
    else
        std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    var buf = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    defer buf.deinit(ally);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try stdin_file.read(&tmp);
        if (n == 0) break;
        try buf.appendSlice(ally, tmp[0..n]);
    }
    var slice = buf.items;
    while (slice.len > 0) {
        const nl = std.mem.indexOfScalar(u8, slice, '\n') orelse slice.len;
        const line = slice[0..nl];
        if (line.len > 0) {
            if (try parseLineAlloc(ally, line)) |json_line| {
                defer ally.free(json_line);
                try stdout_file.writeAll(json_line);
            }
        }
        if (nl == slice.len) break;
        slice = slice[nl + 1 ..];
    }
}

pub fn parseLine(line: []const u8, w: anytype) !void {
    var it = std.mem.splitAny(u8, line, " =");
    const first = it.next() orelse return error.Skip;
    if (std.mem.startsWith(u8, first, "DiagnosticsFoldLarge")) return parseKV("DiagnosticsFoldLarge", line, w);
    if (std.mem.startsWith(u8, first, "CDC_BackfillLatency")) return parseKV("CDC_BackfillLatency", line, w);
    if (std.mem.startsWith(u8, first, "TxnConflictMatrix")) return parseKV("TxnConflictMatrix", line, w);
    if (std.mem.startsWith(u8, first, "PropertyAccessHotPath")) return parseKV("PropertyAccessHotPath", line, w);
    if (std.mem.startsWith(u8, first, "FrameDecode")) return parseKV("FrameDecode", line, w);
    if (std.mem.startsWith(u8, first, "PathExpandBreadth")) return parseKV("PathExpandBreadth", line, w);
    return error.Skip;
}

fn parseKV(kind: []const u8, line: []const u8, w: anytype) !void {
    try std.fmt.format(w, "{{\"kind\":\"{s}\",", .{kind});
    const ts = std.time.milliTimestamp();
    try std.fmt.format(w, "\"ts_ms\":{d},\"raw\":\"", .{ts});
    for (line) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        if (c == '\n' or c == '\r') continue;
        try w.writeByte(c);
    }
    try w.writeByte('"');
    var tok_it = std.mem.splitScalar(u8, line, ' ');
    while (tok_it.next()) |tok| {
        if (tok.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, tok, '=') orelse continue;
        const key = tok[0..eq_index];
        const val = tok[eq_index + 1 ..];
        if (key.len == 0 or val.len == 0) continue;
        var is_num = true;
        for (val) |c| if (c < '0' or c > '9') {
            is_num = false;
            break;
        };
        try w.writeByte(',');
        try std.fmt.format(w, "\"{s}\":", .{key});
        if (is_num) {
            try w.writeAll(val);
        } else {
            try w.writeByte('"');
            for (val) |c| {
                if (c == '"' or c == '\\') try w.writeByte('\\');
                try w.writeByte(c);
            }
            try w.writeByte('"');
        }
    }
    try w.writeAll("}\n");
}

fn parseLineAlloc(ally: std.mem.Allocator, line: []const u8) !?[]u8 {
    var list = std.ArrayList(u8).initCapacity(ally, 0) catch return error.OutOfMemory;
    errdefer list.deinit(ally);
    const w = list.writer(ally);
    parseLine(line, w) catch |err| switch (err) {
        error.Skip => return null,
        else => return err,
    };
    const owned = try list.toOwnedSlice(ally);
    return owned; // Some([]u8)
}
