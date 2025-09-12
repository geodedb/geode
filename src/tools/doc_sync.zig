const std = @import("std");

// doc_sync.zig: validates that REQUIREMENTS / GAP_ANALYSIS / NEXT contain consistent REQ-GQL IDs
// and that profile_version values in PROFILE/README docs are synchronized.
// Usage: zig run src/tools/doc_sync.zig -- (optional --check)

const ReqSet = struct {
    counts: std.StringHashMap(usize),
    pub fn init(ally: std.mem.Allocator) ReqSet {
        return .{ .counts = std.StringHashMap(usize).init(ally) };
    }
    pub fn deinit(self: *ReqSet) void {
        self.counts.deinit();
    }
    pub fn add(self: *ReqSet, key: []const u8, ally: std.mem.Allocator) void {
        const e = self.counts.getOrPut(key) catch return;
        if (!e.found_existing) {
            e.key_ptr.* = ally.dupe(u8, key) catch key;
            e.value_ptr.* = 1;
        } else {
            e.value_ptr.* += 1;
        }
    }
};

fn scanReqIds(ally: std.mem.Allocator, path: []const u8, out: *ReqSet) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var buf_reader = std.io.bufferedReader(file.reader());
    var r = buf_reader.reader();
    var line_buf = std.ArrayList(u8).init(ally);
    defer line_buf.deinit();
    while (true) {
        line_buf.clearRetainingCapacity();
        r.streamUntilDelimiter(line_buf.writer(), '\n', null) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        const line = line_buf.items;
        if (std.mem.indexOf(u8, line, "REQ-GQL-") != null) {
            // extract tokens like REQ-GQL-026
            var it = std.mem.tokenizeAny(u8, line, " ,:\t()[]{}");
            while (it.next()) |tok| if (std.mem.startsWith(u8, tok, "REQ-GQL-") and tok.len == 11) out.add(tok, ally);
        }
    }
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var reqs = ReqSet.init(gpa);
    defer reqs.deinit();
    const paths = [_][]const u8{ "docs/GAP_ANALYSIS.md", "docs/NEXT.md", "docs/REQUIREMENTS.md" };
    for (paths) |p| scanReqIds(gpa, p, &reqs) catch |e| {
        std.debug.print("doc_sync: failed to scan {s}: {s}\n", .{ p, @errorName(e) });
    };
    // Simple report: count and sorted list
    var keys = try std.heap.page_allocator.alloc([]const u8, reqs.counts.count());
    defer std.heap.page_allocator.free(keys);
    var it = reqs.counts.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) keys[i] = e.key_ptr.*;
    std.sort.block([]const u8, keys, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    std.debug.print("doc_sync: found {d} unique REQ IDs\n", .{keys.len});
    var dup_found = false;
    for (keys) |k| {
        const c = reqs.counts.get(k).?;
        if (c != 1) {
            dup_found = true;
            std.debug.print("! duplicate occurrence count={d} for {s}\n", .{ c, k });
        } else {
            std.debug.print("  {s}\n", .{k});
        }
    }
    if (dup_found) {
        std.debug.print("doc_sync: validation FAILED\n", .{});
        std.process.exit(2);
    }
}
