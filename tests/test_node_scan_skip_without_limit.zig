// KNOWN RED: an intentionally red TDD reproduction (docs/KNOWN_TEST_ISSUES.md).
// It is registered as `zig build test-node-scan-skip-without-limit` but is
// deliberately NOT in the aggregate `zig build test` until the fix lands.
//
// P5, found in review of SONNY-1221 (2026-09-24): with `SKIP k` and no LIMIT
// and no WHERE, the engine-direct node scan returns ONE row, not every row
// after the offset. `resolveRequiredRows` answers k+1 for an OFFSET-only
// query. `collectMatchingSlotIds` treats that as a hard cap on the slots it
// collects (`row_cap`), and the cursor starts at slot k, so one slot is left.
//
// RED: the fast path returns 1 row where the executor returns 20.

const std = @import("std");
const testing = std.testing;
const harness = @import("node_scan_stream_harness.zig");

test "P5 (known red): SKIP without LIMIT on the node-scan fast path returns every row after the offset" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    const query = "MATCH (n:M) RETURN n.s SKIP 5";
    var executor = try h.run(query);
    defer executor.deinit(h.arena.allocator());
    try testing.expectEqual(harness.many - 5, executor.rows.len);

    var stream = try harness.openStream(&h, testing.allocator, &qa, query);
    defer stream.deinit();
    const got = try harness.drainColumn0(&stream, testing.allocator, 0);
    defer harness.freeStrings(testing.allocator, got);
    try testing.expectEqual(executor.rows.len, got.len);
}
