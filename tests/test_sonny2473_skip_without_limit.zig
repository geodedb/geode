// SONNY-2473 regression: `SKIP k` with no LIMIT returned one row on the
// engine-direct node scan.
//
// With no WHERE, matched rows are scanned slots, so the scan bounds slot
// collection by the rows the window needs and starts its cursor at the OFFSET.
// `resolveRequiredRows` answered k+1 for an OFFSET with no LIMIT, and
// `collectMatchingSlotIds` treats that answer as a hard cap on the slots it
// collects, so one slot was left after the cursor skipped k:
// `MATCH (n:M) RETURN n.s SKIP 5` over 25 nodes returned 1 row, not 20.
//
// The expected rows come from the seed, not from the executor: on a persisted
// deployment the executor's planned-read path caps this same shape at k+1 rows
// too (`planned_read_runtime.requiredStartRows`), so it also answers 1. Each
// `SKIP k` must return exactly the rows after the first k of the scan's own
// unskipped order: without a WHERE (the defect) at several offsets, including
// 0 and past the end, for a projection and for the bare node; and behind a
// WHERE, where the OFFSET counts matched rows instead. Projections are drained
// with and without the schema-frame sample prefetched, as the transports serve
// them. Leak-checked (`std.testing.allocator`).
//
// CANARY: REQ=REQ-SONNY-2473-SKIP-WITHOUT-LIMIT; FEATURE="EngineDirectRowWindow"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2473_skip_without_limit.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const harness = @import("node_scan_stream_harness.zig");

const many = harness.many;

/// The fast path's column 0 for `query`, in serve order.
fn fastPath(h: *harness.Harness, qa: *std.heap.ArenaAllocator, query: []const u8, prefetch: bool) ![][]const u8 {
    const allocator = testing.allocator;
    var stream = try harness.openStream(h, allocator, qa, query);
    defer stream.deinit();
    if (prefetch) try stream.prefetchSchemaSample(allocator);
    return harness.drainColumn0(&stream, allocator, if (prefetch) 4 else 0);
}

/// `base` returns `matched` rows, and `base SKIP k` returns exactly the rows
/// after the first k of them, in the same order.
fn expectSkip(h: *harness.Harness, qa: *std.heap.ArenaAllocator, base: []const u8, matched: usize, k: usize) !void {
    const query = try std.fmt.allocPrint(qa.allocator(), "{s} SKIP {d}", .{ base, k });
    for ([_]bool{ false, true }) |prefetch| {
        const all = try fastPath(h, qa, base, prefetch);
        defer harness.freeStrings(testing.allocator, all);
        try testing.expectEqual(matched, all.len);
        const got = try fastPath(h, qa, query, prefetch);
        defer harness.freeStrings(testing.allocator, got);
        if (got.len != matched -| k) {
            std.debug.print("{s} (prefetch={}): expected {d} rows, found {d}\n", .{ query, prefetch, matched -| k, got.len });
            return error.TestExpectedEqual;
        }
        for (all[@min(k, all.len)..], got) |w, g| try testing.expectEqualStrings(w, g);
    }
}

test "SONNY-2473: SKIP without LIMIT or WHERE on the node-scan fast path returns every row after the offset" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    for ([_]usize{ 5, 0, 1, 24, 25, 30 }) |k| try expectSkip(&h, &qa, "MATCH (n:M) RETURN n.s", many, k);

    // The bare node is bounded the same way.
    var stream = try harness.openStream(&h, testing.allocator, &qa, "MATCH (n:M) RETURN n SKIP 5");
    defer stream.deinit();
    var rows: usize = 0;
    while (true) {
        var page = try stream.buildNextPage(testing.allocator, 0);
        defer page.result.deinit(testing.allocator);
        rows += page.result.rows.len;
        if (page.final) break;
    }
    try testing.expectEqual(many - 5, rows);
}

test "SONNY-2473: SKIP without LIMIT behind a WHERE counts matched rows" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    // 22 nodes match.
    for ([_]usize{ 5, 1, 22, 30 }) |k| try expectSkip(&h, &qa, "MATCH (n:M) WHERE n.i >= 3 RETURN n.s", many - 3, k);
}
