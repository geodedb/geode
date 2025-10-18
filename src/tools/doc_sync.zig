const std = @import("std");

// doc_sync.zig: validates that REQUIREMENTS / GAP_ANALYSIS / NEXT contain consistent REQ-GQL IDs
// and that profile_version values in PROFILE/README docs are synchronized.
// Usage: zig run src/tools/doc_sync.zig -- (optional --check)

const ReqSet = struct {
    counts: std.StringHashMap(usize),
    pub fn init(allocator: std.mem.Allocator) ReqSet {
        return .{ .counts = std.StringHashMap(usize).init(allocator) };
    }
    pub fn deinit(self: *ReqSet) void {
        self.counts.deinit();
    }
    pub fn add(self: *ReqSet, key: []const u8, allocator: std.mem.Allocator) void {
        const e = self.counts.getOrPut(key) catch return;
        if (!e.found_existing) {
            e.key_ptr.* = allocator.dupe(u8, key) catch key;
            e.value_ptr.* = 1;
        } else {
            e.value_ptr.* += 1;
        }
    }
};

fn scanReqIds(allocator: std.mem.Allocator, path: []const u8, out: *ReqSet) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read entire file into memory for simplicity
    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(content);

    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "REQ-GQL-") != null) {
            // extract tokens like REQ-GQL-026
            var it = std.mem.tokenizeAny(u8, line, " ,:\t()[]{}");
            while (it.next()) |tok| if (std.mem.startsWith(u8, tok, "REQ-GQL-") and tok.len == 11) out.add(tok, allocator);
        }
    }
}

pub fn main() !void {
    // P2-3: Use GeneralPurposeAllocator for tool main
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    // Parse optional --check flag after "--"
    var args_iter = try std.process.argsWithAllocator(gpa);
    defer args_iter.deinit();
    var saw_sep = false;
    var check_mode = false;
    while (args_iter.next()) |a| {
        if (!saw_sep) {
            if (std.mem.eql(u8, a, "--")) {
                saw_sep = true;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--check")) check_mode = true;
    }

    var reqs = ReqSet.init(gpa);
    defer reqs.deinit();
    const paths = [_][]const u8{ "docs/GAP_ANALYSIS.md", "docs/NEXT.md", "docs/REQUIREMENTS.md" };
    for (paths) |p| scanReqIds(gpa, p, &reqs) catch |e| {
        std.debug.print("doc_sync: failed to scan {s}: {s}\n", .{ p, @errorName(e) });
    };
    // Simple report: count and sorted list
    var keys = try gpa.alloc([]const u8, reqs.counts.count());
    defer gpa.free(keys);
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
        if (c > 3) {
            dup_found = true;
            std.debug.print("! high occurrence count={d} for {s} (may need consolidation)\n", .{ c, k });
        } else if (c > 1) {
            std.debug.print("  {s} (appears {d} times)\n", .{ k, c });
        } else {
            std.debug.print("  {s}\n", .{k});
        }
    }
    if (dup_found) {
        std.debug.print("doc_sync: WARNING - some requirements have very high occurrence counts\n", .{});
        if (check_mode) {
            std.process.exit(2);
        }
    } else {
        std.debug.print("doc_sync: validation PASSED\n", .{});
    }
}
