// SONNY-2671 regression: the engine-direct node scan's `buildNextPage`
// leaked the row it had just built when appending it to the page failed.
//
// The page's row list is reserved for at most 256 rows; a page over 256 rows
// grows it on the 257th append. `buildRow` had already built the row (its
// cells and, for a returned node, the node's tracking), and `try
// rows.append(allocator, row)` returned OutOfMemory with the row in no list:
// the page's errdefer freed the rows before it, not this one. The slot is
// now reserved before the row is built.
//
// A persisted store holds 300 `:Big` nodes; a 300-row page is built with its
// N-th allocation failing, for every N around the 256-row boundary (located
// with a counting run of a 256-row page), and for every N of a small page.
// After each failure the stream is closed and every allocation of the page's
// allocator must have been freed. No mocks: the real stream over the real
// storage adapter.
//
// CANARY: REQ=REQ-SONNY-2671-SCAN-PAGE-APPEND-OOM; FEATURE="EngineDirectNodeOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2671_scan_page_append_oom.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const harness = @import("node_scan_stream_harness.zig");

const node_count: usize = 300;
const query = "MATCH (n:Big) RETURN n.s, n.i, n";

fn seed(h: *harness.Harness) !void {
    const aa = h.arena.allocator();
    for (0..node_count) |i| {
        var r = try h.run(try std.fmt.allocPrint(aa, "CREATE (:Big {{s: 's{d}', i: {d}}})", .{ i, i }));
        r.deinit(aa);
    }
}

/// Build one page of `page_size` rows on an allocator failing at
/// `fail_index` (null: never). Returns how many allocations the page made,
/// and whether the failure was reached; fails the test on a leak.
fn pageWithFailure(h: *harness.Harness, page_size: usize, fail_index: ?usize) !struct { allocations: usize, failed: bool } {
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    var stream = try harness.openStream(h, testing.allocator, &qa, query);
    defer stream.deinit();
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index orelse std.math.maxInt(usize) });
    const fa = failing.allocator();
    if (stream.buildNextPage(fa, page_size)) |page_const| {
        var page = page_const;
        page.result.deinit(fa);
    } else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
    }
    if (failing.allocations != failing.deallocations) {
        std.debug.print("page of {d}, allocation {?d} failing: {d} allocations, {d} freed\n", .{ page_size, fail_index, failing.allocations, failing.deallocations });
        return error.PageLeaked;
    }
    return .{ .allocations = failing.allocations, .failed = failing.has_induced_failure };
}

test "SONNY-2671: a scan page over 256 rows frees the row it built when the append fails" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);

    // Where the 257th row is appended: after about 256 rows' allocations.
    const at_256 = (try pageWithFailure(&h, 256, null)).allocations;
    const full = (try pageWithFailure(&h, node_count, null)).allocations;
    try testing.expect(full > at_256);
    const per_row = (full - at_256) / (node_count - 256);
    var n = at_256 -| 4 * per_row;
    var leaks: usize = 0;
    while (n < at_256 + 4 * per_row) : (n += 1) {
        _ = pageWithFailure(&h, node_count, n) catch |err| switch (err) {
            error.PageLeaked => {
                leaks += 1;
                continue;
            },
            else => return err,
        };
    }
    try testing.expectEqual(@as(usize, 0), leaks);
}

test "SONNY-2671: a small scan page frees what it built at every allocation failure" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try seed(&h);
    var n: usize = 0;
    while (true) : (n += 1) {
        const r = try pageWithFailure(&h, 4, n);
        if (!r.failed) break;
    }
}
