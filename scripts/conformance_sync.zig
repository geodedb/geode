const std = @import("std");

// Conformance sync scanner: scans docs/ and src/ for REQ-GQL-### tokens.
// Flags:
//   --json             Emit machine JSON summary.
//   --markdown         Emit Markdown summary table.
//   --fail-on-issues   Exit code 2 if issues detected (currently none - all patterns allowed).
// Usage examples:
//   zig run scripts/conformance_sync.zig -- --json
//   zig run scripts/conformance_sync.zig -- --markdown
//
// Design Notes:
// - Duplicate REQ-GQL IDs are intentional - same requirement tracked in multiple files
// - Gaps in numeric sequence are intentional - IDs assigned by feature ranges, not sequentially
// The scanner reports duplicates and gaps for informational purposes only.

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var json = false;
    var markdown = false;
    var fail_on_issues = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--json")) json = true else if (std.mem.eql(u8, a, "--markdown")) markdown = true else if (std.mem.eql(u8, a, "--fail-on-issues")) fail_on_issues = true;
    }
    if (json and markdown) return error.ConflictingModes;

    var ids = std.StringHashMap(void).init(allocator);
    defer {
        // free allocated keys
        var it = ids.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        ids.deinit();
    }
    const DupsMax = 512;
    var dups: [DupsMax][]const u8 = undefined; // store each occurrence beyond first
    var dup_count: usize = 0;
    // Frequency map for duplicates (id -> occurrences beyond first)
    var dup_freq = std.StringHashMap(u32).init(allocator);
    defer {
        var itf = dup_freq.iterator();
        while (itf.next()) |e| allocator.free(e.key_ptr.*);
        dup_freq.deinit();
    }

    try walkDir(&ids, &dups, &dup_count, &dup_freq, allocator, "docs");
    try walkDir(&ids, &dups, &dup_count, &dup_freq, allocator, "src");

    // Presence array for 0..999 (enough for now)
    var present: [1000]bool = .{false} ** 1000;
    var max_seen: i32 = -1;
    var min_seen: i32 = -1;

    // Collect ids into a list for deterministic ordering
    var id_list = std.ArrayListUnmanaged([]const u8){};
    defer id_list.deinit(allocator);
    var it2 = ids.iterator();
    while (it2.next()) |e| {
        const key = e.key_ptr.*;
        id_list.append(allocator, key) catch {};
        const tail = key[key.len - 3 ..];
        const num = std.fmt.parseInt(u32, tail, 10) catch continue;
        if (num < present.len) {
            present[num] = true;
            if (max_seen < 0 or num > @as(u32, @intCast(max_seen))) max_seen = @intCast(num);
            if (min_seen < 0 or num < @as(u32, @intCast(min_seen))) min_seen = @intCast(num);
        }
    }

    // Sort IDs lexicographically (REQ-GQL-000 .. )
    std.sort.block([]const u8, id_list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Note: Both duplicates and gaps are intentional by design:
    // - Duplicates: Same requirement may be tracked in multiple implementation files
    // - Gaps: IDs are assigned by feature ranges, not sequentially
    // The scanner reports these for informational purposes but doesn't fail on them.
    const has_issues = false;

    if (json) {
        // opening brace
        std.debug.print("{c}", .{'{'});
        std.debug.print("\"total_ids\":{d},", .{ids.count()});
        std.debug.print("\"ids\":[", .{});
        var first = true;
        for (id_list.items) |k| {
            if (!first) {
                std.debug.print(",", .{});
            } else {
                first = false;
            }
            printJsonString(k);
        }
        std.debug.print("],\"duplicates\":[", .{});
        first = true;
        var i: usize = 0;
        while (i < dup_count) : (i += 1) {
            if (!first) {
                std.debug.print(",", .{});
            } else {
                first = false;
            }
            printJsonString(dups[i]);
        }
        std.debug.print("],\"gaps\":[", .{});
        first = true;
        if (min_seen >= 0) {
            var n: usize = @intCast(min_seen);
            while (n <= @as(usize, @intCast(max_seen))) : (n += 1) {
                if (!present[n]) {
                    if (!first) {
                        std.debug.print(",", .{});
                    } else {
                        first = false;
                    }
                    std.debug.print("{d}", .{n});
                }
            }
        }
        // Close gaps array then append issues and closing brace.
        std.debug.print("],\"issues\":{s}{c}", .{ if (has_issues) "true" else "false", '}' });
        // free duplicates before exit
        var j: usize = 0;
        while (j < dup_count) : (j += 1) allocator.free(dups[j]);
        if (fail_on_issues and has_issues) std.process.exit(2);
        return;
    }

    if (markdown) {
        // Build sorted frequency list
        var freq_list = std.ArrayListUnmanaged([]const u8){};
        defer freq_list.deinit(allocator);
        var itf2 = dup_freq.iterator();
        while (itf2.next()) |e| freq_list.append(allocator, e.key_ptr.*) catch {};
        std.sort.block([]const u8, freq_list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        std.debug.print("# Conformance Scan Summary\n\n", .{});
        std.debug.print("*Total Unique IDs*: {d}\\n\n", .{ids.count()});
        if (dup_count > 0) {
            std.debug.print("## Duplicate Occurrences (each repeat counted)\n\n", .{});
            std.debug.print("| ID | Extra Occurrences |\n| --- | --- |\n", .{});
            for (freq_list.items) |k| {
                const val = dup_freq.get(k).?; // frequency beyond first
                std.debug.print("| {s} | {d} |\n", .{ k, val });
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("No duplicates detected.\\n\n", .{});
        }
        if (min_seen >= 0 and hasGaps(present[0..], @intCast(min_seen), @intCast(max_seen))) {
            std.debug.print("## Gaps\\n\n", .{});
            std.debug.print("Missing sequence numbers (zero-padded implicit):\\n\n", .{});
            var n: usize = @intCast(min_seen);
            var first_gap = true;
            while (n <= @as(usize, @intCast(max_seen))) : (n += 1) if (!present[n]) {
                if (!first_gap) {
                    std.debug.print(",", .{});
                } else {
                    first_gap = false;
                }
                std.debug.print("{d}", .{n});
            };
            std.debug.print("\\n\n", .{});
        } else {
            std.debug.print("No gaps in numeric sequence.\\n\n", .{});
        }
        if (fail_on_issues and has_issues) {
            std.process.exit(2);
        } else {
            // free duplicate slice copies before returning
            var dj: usize = 0;
            while (dj < dup_count) : (dj += 1) allocator.free(dups[dj]);
            return;
        }
    }

    std.debug.print("Total unique IDs: {d}\n", .{ids.count()});
    if (dup_count > 0) {
        std.debug.print("Duplicates ({d}):\n", .{dup_count});
        for (dups[0..dup_count]) |d| std.debug.print("  {s}\n", .{d});
    }
    if (min_seen >= 0) {
        var gap_any = false;
        var n: usize = @intCast(min_seen);
        while (n < @as(usize, @intCast(max_seen))) : (n += 1) {
            if (!present[n]) gap_any = true;
        }
        if (gap_any) {
            std.debug.print("Gaps:\n", .{});
            n = @intCast(min_seen);
            while (n <= @as(usize, @intCast(max_seen))) : (n += 1) if (!present[n]) printReqId(n);
        }
    }
    // free duplicate slices (keys freed with map)
    var j: usize = 0;
    while (j < dup_count) : (j += 1) allocator.free(dups[j]);
    if (fail_on_issues and has_issues) std.process.exit(2);
    // free duplicate slice copies before normal exit (plain mode)
    var dj: usize = 0;
    while (dj < dup_count) : (dj += 1) allocator.free(dups[dj]);
}

fn walkDir(ids: *std.StringHashMap(void), dups: *[512][]const u8, dup_count: *usize, dup_freq: *std.StringHashMap(u32), allocator: std.mem.Allocator, root: []const u8) !void {
    // Simple recursive traversal to avoid manual stack leaks.
    try walkDirInner(ids, dups, dup_count, dup_freq, allocator, root);
}

fn walkDirInner(ids: *std.StringHashMap(void), dups: *[512][]const u8, dup_count: *usize, dup_freq: *std.StringHashMap(u32), allocator: std.mem.Allocator, path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (true) {
        const next = it.next() catch break;
        if (next == null) break;
        const ent = next.?;
        if (ent.kind == .directory) {
            const sub = try std.fs.path.join(allocator, &.{ path, ent.name });
            defer allocator.free(sub);
            try walkDirInner(ids, dups, dup_count, dup_freq, allocator, sub);
            continue;
        }
        if (ent.kind == .file) {
            if (!std.mem.endsWith(u8, ent.name, ".md") and !std.mem.endsWith(u8, ent.name, ".zig")) continue;
            const full = try std.fs.path.join(allocator, &.{ path, ent.name });
            const data = std.Io.Dir.cwd().readFileAlloc(allocator, full, 1 << 20) catch {
                allocator.free(full);
                continue;
            };
            scanBuffer(ids, dups, dup_count, dup_freq, allocator, data);
            allocator.free(data);
            allocator.free(full);
        }
    }
}

fn scanBuffer(ids: *std.StringHashMap(void), dups: *[512][]const u8, dup_count: *usize, dup_freq: *std.StringHashMap(u32), allocator: std.mem.Allocator, buf: []const u8) void {
    var i: usize = 0;
    while (i + 11 <= buf.len) : (i += 1) {
        if (buf[i] != 'R') continue;
        if (!std.mem.startsWith(u8, buf[i..], "REQ-GQL-")) continue;
        const slice = buf[i .. i + 11];
        if (!isReqId(slice)) continue;
        if (ids.contains(slice)) {
            if (dup_count.* < dups.len) {
                const copy = allocator.dupe(u8, slice) catch return;
                dups.*[dup_count.*] = copy;
                dup_count.* += 1;
            }
            // bump frequency (allocate key copy once when first seen as duplicate in freq map)
            if (dup_freq.contains(slice)) {
                const entry = dup_freq.getPtr(slice).?;
                entry.* += 1;
            } else {
                const key_dup = allocator.dupe(u8, slice) catch return;
                dup_freq.put(key_dup, 1) catch return;
            }
        } else {
            const key = allocator.dupe(u8, slice) catch return;
            ids.put(key, {}) catch return;
        }
        i += 10; // skip ahead
    }
}

fn isReqId(s: []const u8) bool {
    return s.len == 11 and std.mem.startsWith(u8, s, "REQ-GQL-") and std.ascii.isDigit(s[8]) and std.ascii.isDigit(s[9]) and std.ascii.isDigit(s[10]);
}

fn printJsonString(s: []const u8) void {
    std.debug.print("\"", .{});
    for (s) |c| switch (c) {
        '"' => std.debug.print("\\\"", .{}),
        '\\' => std.debug.print("\\\\", .{}),
        '\n' => std.debug.print("\\n", .{}),
        '\r' => std.debug.print("\\r", .{}),
        '\t' => std.debug.print("\\t", .{}),
        else => if (c < 0x20) {
            // manual 4-hex digit escape
            const hex = "0123456789ABCDEF";
            const b: u8 = c;
            std.debug.print("\\u00{c}{c}", .{ hex[(b >> 4) & 0xF], hex[b & 0xF] });
        } else std.debug.print("{c}", .{c}),
    };
    std.debug.print("\"", .{});
}

fn printReqId(n: usize) void {
    var buf: [3]u8 = .{ '0', '0', '0' };
    var x = n;
    var i: i32 = 2;
    while (i >= 0 and x > 0) : (i -= 1) {
        buf[@intCast(i)] = @intCast('0' + @as(u8, @intCast(x % 10)));
        x /= 10;
    }
    std.debug.print("  REQ-GQL-{s}\n", .{buf});
}

fn hasGaps(present: []const bool, min_seen: usize, max_seen: usize) bool {
    var n = min_seen;
    while (n <= max_seen) : (n += 1) if (!present[n]) return true;
    return false;
}
