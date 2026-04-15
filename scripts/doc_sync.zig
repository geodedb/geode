const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var req_ids = std.StringHashMap(void).init(allocator);
    defer req_ids.deinit();

    // Scan src/ and docs/ for tokens REQ-GQL-###
    try scanDir(allocator, "src", &req_ids);
    try scanDir(allocator, "docs", &req_ids);

    // Parse GAP_ANALYSIS.md ledger lines retrieving IDs
    var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), "docs/GAP_ANALYSIS.md", .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(data);
    var in_ledger = false;
    var it = std.mem.splitScalar(u8, data, '\n');
    var ledger_ids = std.StringHashMap(void).init(allocator);
    defer ledger_ids.deinit();
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "| REQ-GQL-")) {
            in_ledger = true;
            // token after first pipe
            var parts = std.mem.splitScalar(u8, line, '|');
            _ = parts.next(); // leading empty
            if (parts.next()) |id_part| {
                const trimmed = std.mem.trim(u8, id_part, " \t");
                if (std.mem.startsWith(u8, trimmed, "REQ-GQL-")) {
                    _ = try ledger_ids.put(trimmed, {});
                }
            }
        } else if (in_ledger and line.len == 0) {
            break; // end table
        }
    }

    var missing = std.ArrayList([]const u8).init(allocator);
    defer missing.deinit();
    var extra = std.ArrayList([]const u8).init(allocator);
    defer extra.deinit();

    { // missing in ledger
        var it_ids = req_ids.keyIterator();
        while (it_ids.next()) |k| if (ledger_ids.get(k.*) == null and isReqId(k.*)) try missing.append(allocator, k.*);
    }
    { // extra in ledger not seen in source
        var it_leg = ledger_ids.keyIterator();
        while (it_leg.next()) |k| if (req_ids.get(k.*) == null) try extra.append(allocator, k.*);
    }

    std.sort.block([]const u8, missing.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    std.sort.block([]const u8, extra.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    var stdout = std.io.getStdOut().writer();
    if (missing.items.len == 0 and extra.items.len == 0) {
        try stdout.print("doc-sync OK: ledger matches source IDs\n", .{});
        return;
    }
    if (missing.items.len > 0) {
        try stdout.print("Missing in ledger ({d}):\n", .{missing.items.len});
        for (missing.items) |m| try stdout.print("  {s}\n", .{m});
    }
    if (extra.items.len > 0) {
        try stdout.print("Extra in ledger ({d}):\n", .{extra.items.len});
        for (extra.items) |e| try stdout.print("  {s}\n", .{e});
    }
}

fn isReqId(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "REQ-GQL-")) return false;
    if (s.len != 12) return false; // REQ-GQL-### (3 digits)
    var i: usize = 8;
    while (i < s.len) : (i += 1) if (s[i] < '0' or s[i] > '9') return false;
    return true;
}

fn scanDir(allocator: std.mem.Allocator, path: []const u8, map: *std.StringHashMap(void)) !void {
    var dir = try std.Io.Dir.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind == .file) {
            if (std.mem.endsWith(u8, e.name, ".zig") or std.mem.endsWith(u8, e.name, ".md")) {
                var f = try dir.openFile(std.Io.Threaded.global_single_threaded.io(), e.name, .{});
                defer f.close();
                const data = try f.readToEndAlloc(allocator, 1 * 1024 * 1024);
                defer allocator.free(data);
                var idx: usize = 0;
                while (idx < data.len) : (idx += 1) {
                    if (data[idx] == 'R' and idx + 11 <= data.len) {
                        const slice = data[idx .. idx + 12];
                        if (isReqId(slice)) _ = try map.put(slice, {});
                    }
                }
            }
        } else if (e.kind == .directory) {
            var buf = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, path);
            try buf.append(allocator, '/');
            try buf.appendSlice(allocator, e.name);
            try scanDir(allocator, buf.items, map);
        }
    }
}
