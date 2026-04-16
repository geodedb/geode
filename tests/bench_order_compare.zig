const std = @import("std");

// Micro benchmark to compare legacy ORDER BY comparator (linear slice->index lookup)
// vs new index-based comparator. We simulate legacy cost by performing an O(n)
// search for each comparison while the optimized path sorts indices.
// Outputs single JSON line with timing and comparator invocation counts.

fn legacySort(allocator: std.mem.Allocator, rows: [][]const u8) !struct { dur_ns: u128, cmp_calls: usize } {
    const dup = try allocator.dupe([]const u8, rows);
    var calls: usize = 0;
    const Ctx = struct { rows: [][]const u8, calls: *usize };
    const t0 = std.time.nanoTimestamp();
    std.sort.block([]const u8, dup, Ctx{ .rows = dup, .calls = &calls }, struct {
        fn less(c: Ctx, a: []const u8, b: []const u8) bool {
            c.calls.* += 1;
            // simulate legacy O(n) scan mapping slice -> index (worst-case)
            var ia: usize = 0;
            while (ia < c.rows.len and !std.mem.eql(u8, c.rows[ia], a)) : (ia += 1) {}
            var ib: usize = 0;
            while (ib < c.rows.len and !std.mem.eql(u8, c.rows[ib], b)) : (ib += 1) {}
            // tie-break using direct byte compare
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    const t1 = std.time.nanoTimestamp();
    return .{ .dur_ns = @as(u128, @intCast(t1 - t0)), .cmp_calls = calls };
}

fn optimizedSort(allocator: std.mem.Allocator, rows: [][]const u8) !struct { dur_ns: u128, cmp_calls: usize } {
    var indices = try allocator.alloc(usize, rows.len);
    defer allocator.free(indices);
    var i: usize = 0;
    while (i < indices.len) : (i += 1) indices[i] = i;
    var calls: usize = 0;
    const Ctx = struct { rows: [][]const u8, calls: *usize };
    const t0 = std.time.nanoTimestamp();
    std.sort.block(usize, indices, Ctx{ .rows = rows, .calls = &calls }, struct {
        fn less(c: Ctx, a: usize, b: usize) bool {
            c.calls.* += 1;
            return std.mem.lessThan(u8, c.rows[a], c.rows[b]);
        }
    }.less);
    const t1 = std.time.nanoTimestamp();
    return .{ .dur_ns = @as(u128, @intCast(t1 - t0)), .cmp_calls = calls };
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const n = 2000; // moderate size
    var rows = try allocator.alloc([]const u8, n);
    defer allocator.free(rows);
    // Generate synthetic JSON row slices with slight variations to avoid best-case sorting
    var i: usize = 0;
    while (i < n) : (i += 1) {
        rows[i] = try std.fmt.allocPrint(allocator, "{{\"x\":{d},\"y\":{d}}}", .{ (n - i), i % 17 });
    }
    const legacy = try legacySort(allocator, rows);
    const opt = try optimizedSort(allocator, rows);
    // Output JSON metrics
    std.debug.print("{s}{d}{s}{d}{s}{d}{s}{d}{s}\n", .{
        "{\"bench\":\"order_compare\",\"rows\":", n,
        ",\"legacy_cmp_calls\":",                 legacy.cmp_calls,
        ",\"optimized_cmp_calls\":",              opt.cmp_calls,
        ",\"legacy_ns\":",                        @as(u64, @intCast(legacy.dur_ns)),
        ",\"optimized_ns\":",                     @as(u64, @intCast(opt.dur_ns)),
        "}",
    });
}
