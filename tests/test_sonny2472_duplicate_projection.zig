// SONNY-2472 regression: projecting the same string property twice through the
// engine-direct node scan freed it twice.
//
// `.Member` evaluation hands a projection cell the node's own string, not a
// copy. `MATCH (n:M) RETURN n.s, n.s AS t` therefore put ONE allocation in both
// cells of every row, and page teardown (`ExecutionResult.deinit` ->
// `freeValue`: the page owns its values) freed it once per cell. It was a
// double free that any reader could trigger with an ordinary query.
//
// Every row of every page is checked: the cells of one repeated property must
// hold equal text in DIFFERENT allocations. The allocator is
// `std.testing.allocator`, which also fails the test on a leak and reports a
// double free.
//
// CANARY: REQ=REQ-SONNY-2472-DUPLICATE-PROJECTION; FEATURE="EngineDirectProjectionOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2472_duplicate_projection.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const NodeScanStream = geode.node_scan_stream.NodeScanStream;

const Case = struct {
    query: []const u8,
    /// Column pairs that project the same string property.
    twins: []const [2]usize,
};

const cases = [_]Case{
    .{ .query = "MATCH (n:M) RETURN n.s, n.s AS t", .twins = &.{.{ 0, 1 }} },
    // Three copies of one property, not adjacent, around a non-string column.
    .{ .query = "MATCH (n:M) RETURN n.s, n.i, n.s AS t, n.s AS u", .twins = &.{ .{ 0, 2 }, .{ 0, 3 }, .{ 2, 3 } } },
};

/// Page `stream` to its end at `page_size`, checking every row's `twins`, and
/// return column 0 in serve order (owned by `allocator`).
fn drainTwins(stream: *NodeScanStream, allocator: std.mem.Allocator, page_size: usize, twins: []const [2]usize) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages > harness.many + 1) return error.NeverFinal;
        var page = try stream.buildNextPage(allocator, page_size);
        defer page.result.deinit(allocator);
        for (page.result.rows) |row| {
            for (twins) |pair| {
                const a = row[pair[0]].Str;
                const b = row[pair[1]].Str;
                try testing.expectEqualStrings(a, b);
                if (a.ptr == b.ptr) {
                    std.debug.print("row {s}: columns {d} and {d} share one allocation\n", .{ a, pair[0], pair[1] });
                    return error.CellsShareOneAllocation;
                }
            }
            try out.append(allocator, try allocator.dupe(u8, row[0].Str));
        }
        if (page.final) break;
    }
    try testing.expect(!stream.hasRemaining());
    return out.toOwnedSlice(allocator);
}

test "SONNY-2472: a string projected twice by the node-scan fast path is two allocations, each freed once" {
    harness.silenceEngineLogs();
    const allocator = testing.allocator;
    var h = try harness.Harness.init(allocator);
    defer h.deinit();
    try harness.seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();

    for (cases) |case| {
        // Plain, one default-size page; and the way both transports serve a
        // projection: the schema-frame sample prefetched, then small pages.
        for ([_]bool{ false, true }) |prefetch| {
            var stream = try harness.openStream(&h, allocator, &qa, case.query);
            defer stream.deinit();
            if (prefetch) try stream.prefetchSchemaSample(allocator);
            const got = try drainTwins(&stream, allocator, if (prefetch) 3 else 0, case.twins);
            defer harness.freeStrings(allocator, got);

            // Every node once: s00 .. s24.
            try testing.expectEqual(harness.many, got.len);
            std.mem.sort([]const u8, got, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            for (got, 0..) |s, i| {
                var buf: [8]u8 = undefined;
                try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "s{d:0>2}", .{i}), s);
            }
        }
    }
}
