const std = @import("std");
const scan = @import("scan_requirements.zig");

fn writeTable(alloc: std.mem.Allocator, w: anytype, res: scan.ReqScanResult) !void {
    try w.print("| Requirement ID | Status | Duplicate Count |\n", .{});
    try w.print("| -------------- | ------ | ---------------- |\n", .{});
    // Build frequency map
    var freq = std.StringHashMap(u32).init(alloc);
    defer freq.deinit();
    for (res.ids.items) |id| {
        const g = try freq.getOrPut(id);
        if (!g.found_existing) g.value_ptr.* = 1 else g.value_ptr.* += 1;
    }
    for (res.duplicates.items) |id| {
        const g = try freq.getOrPut(id);
        if (!g.found_existing) g.value_ptr.* = 1 else g.value_ptr.* += 1;
    }
    for (res.ids.items) |id| {
        const count = freq.get(id) orelse 1;
        try w.print("| {s} | Seen | {d} |\n", .{ id, count });
    }
}

fn replaceSegment(content: []const u8, marker_begin: []const u8, marker_end: []const u8, replacement: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const start = std.mem.indexOf(u8, content, marker_begin) orelse return error.MarkerBeginNotFound;
    const end = std.mem.indexOf(u8, content, marker_end) orelse return error.MarkerEndNotFound;
    if (end <= start) return error.MarkerOrder;
    var buf = try alloc.alloc(u8, 0);
    var len: usize = 0;
    // helper to append slice
    inline for (.{}) |_| {}
    const append = struct {
        fn do(alloc: std.mem.Allocator, current: *[]u8, len_ptr: *usize, data: []const u8) !void {
            const old = len_ptr.*;
            const new_len = old + data.len;
            current.* = try alloc.realloc(current.* , new_len);
            std.mem.copyForwards(u8, current.*[old..new_len], data);
            len_ptr.* = new_len;
        }
    };
    try append.do(alloc, &buf, &len, content[0 .. start + marker_begin.len]);
    try append.do(alloc, &buf, &len, "\n");
    try append.do(alloc, &buf, &len, replacement);
    if (content[start + marker_begin.len - 1] != '\n') try append.do(alloc, &buf, &len, "\n");
    try append.do(alloc, &buf, &len, content[end..]);
    return buf;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var scanner = scan.ReqScanner.init(alloc);
    defer scanner.deinit();
    try scanner.scanPaths(&.{ "docs", "src" });
    const res = try scanner.finalize(alloc);
    defer res.gaps.deinit();
    // Build replacement markdown
    var gen_buf = try alloc.alloc(u8, 0);
    var gen_len: usize = 0;
    const append = struct {
        fn do(alloc: std.mem.Allocator, current: *[]u8, len_ptr: *usize, data: []const u8) !void {
            const old = len_ptr.*;
            const new_len = old + data.len;
            current.* = try alloc.realloc(current.* , new_len);
            std.mem.copyForwards(u8, current.*[old..new_len], data);
            len_ptr.* = new_len;
        }
    };
    const W = struct {
        alloc: std.mem.Allocator,
        buf: *[]u8,
        len_ptr: *usize,
        pub fn writeFn(self: @This(), data: []const u8) !usize {
            try append.do(self.alloc, self.buf, self.len_ptr, data);
            return data.len;
        }
    };
    var writer_ctx = W{ .alloc = alloc, .buf = &gen_buf, .len_ptr = &gen_len };
    fn writeProxy(ctx: W, data: []const u8) !usize { return ctx.writeFn(data); }
    const WriterType = std.io.Writer(W, error{OutOfMemory}, writeProxy);
    var w = WriterType{ .context = writer_ctx };
    try w.print("Auto-generated (unix_ts={d})\n\n", .{std.time.timestamp()});
    try writeTable(alloc, w, res);

    const gap_path = "docs/GAP_ANALYSIS.md";
    var gap_file = try std.fs.cwd().openFile(gap_path, .{ .mode = .read_only });
    defer gap_file.close();
    const gap_data = try gap_file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(gap_data);
    const new_gap = try replaceSegment(gap_data, "<!-- AUTOGEN:BEGIN REQUIREMENTS_LEDGER", "<!-- AUTOGEN:END REQUIREMENTS_LEDGER -->", gen_buf[0..gen_len], alloc);
    defer alloc.free(new_gap);
    try std.fs.cwd().writeFile(.{ .sub_path = gap_path, .data = new_gap });

    var stdout = std.io.getStdOut().writer();
    try stdout.print("Updated {s} (ids={d} dups={d} gaps={d})\n", .{ gap_path, res.ids.items.len, res.duplicates.items.len, res.gaps.len });
    if (res.has_issues) std.process.exit(2);
}
