// KNOWN RED: an intentionally red TDD reproduction (docs/KNOWN_TEST_ISSUES.md).
// It is registered as `zig build test-node-scan-duplicate-projection` but is
// deliberately NOT in the aggregate `zig build test` until the fix lands.
//
// P4, found in review of SONNY-1221 (2026-09-24): projecting the same string
// property twice through the engine-direct node scan frees it twice.
// `.Member` evaluation hands each cell the node's own string, not a copy, so
// both cells of `RETURN n.s, n.s AS t` hold one pointer. The page owns its
// values (`owns_value_memory`), and `ExecutionResult.deinit` frees each cell.
// Any reader can reach this memory corruption.
//
// RED: the testing allocator reports "Double free detected" when the first
// page is torn down.

const std = @import("std");
const testing = std.testing;
const harness = @import("node_scan_stream_harness.zig");

test "P4 (known red): a string projected twice by the node-scan fast path is freed once" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    var stream = try harness.openStream(&h, testing.allocator, &qa, "MATCH (n:M) RETURN n.s, n.s AS t");
    defer stream.deinit();
    const got = try harness.drainColumn0(&stream, testing.allocator, 0);
    defer harness.freeStrings(testing.allocator, got);
    try testing.expectEqual(harness.many, got.len);
}
