// SONNY-6702: the QUIC handler's ungrouped count fast paths answered their one
// row without applying the statement's window. The handler calls
// `countNodesLabelRefcountFastPath`, `countNodesFastPath`, `countEdgesFastPath`
// and `countFilteredFastPath` BEFORE the executor, and each shape gate declined
// only a literal `LIMIT 0`, so `RETURN count(*) AS c OFFSET 1` and `LIMIT $l`
// with l = 0 still answered the count row. ISO/IEC 39075:2024 14.10: the one
// aggregate row is windowed like any other row. A window that may drop the row
// now declines the fast path, so the executor applies it.
//
// Drives the four exported fast paths exactly as the handler does, on a real
// persisted store (the node-scan harness), leak-checked.
//
// CANARY: REQ=REQ-SONNY-6702-LIMIT-ZERO; FEATURE="AggregateFastPathWindow"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6702_window_fast_paths.zig; OWNER=engine; UPDATED=2026-11-17

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;

const FastPath = enum { label_refcount, nodes, edges, filtered };

/// Whether the handler's `path` fast path answers `query`.
fn answers(path: FastPath, qa: *std.heap.ArenaAllocator, query: []const u8) !bool {
    const allocator = testing.allocator;
    const q = (try harness.parseQuery(qa, query)).*;
    const graph = graph_store.DEFAULT_GRAPH_NAME;
    var result = switch (path) {
        .label_refcount => try execution.countNodesLabelRefcountFastPath(allocator, q, graph, null),
        .nodes => try execution.countNodesFastPath(allocator, q, graph, null),
        .edges => try execution.countEdgesFastPath(allocator, q, graph, null),
        .filtered => try execution.countFilteredFastPath(allocator, q, graph, null),
    } orelse return false;
    result.deinit(allocator);
    return true;
}

fn expectAnswers(path: FastPath, qa: *std.heap.ArenaAllocator, query: []const u8, want: bool) !void {
    const got = try answers(path, qa, query);
    if (got != want) {
        std.debug.print("{s}: fast path {s} {s}, expected it to {s}\n", .{ query, @tagName(path), if (got) "answered" else "declined", if (want) "answer" else "decline" });
        return error.TestExpectedEqual;
    }
}

test "SONNY-6702: a count fast path declines a window that may drop its one row" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedMany(&h);
    var r = try h.run("MATCH (a:M {i: 0}), (b:M {i: 1}) CREATE (a)-[:E6702]->(b)");
    r.deinit(h.arena.allocator());
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    // The control: no window, a literal LIMIT >= 1 and OFFSET 0 keep the row.
    for ([_]FastPath{ .label_refcount, .nodes }) |path| {
        try expectAnswers(path, &qa, "MATCH (n:M) RETURN count(*) AS c", true);
        try expectAnswers(path, &qa, "MATCH (n:M) RETURN count(*) AS c LIMIT 1", true);
    }
    try expectAnswers(.edges, &qa, "MATCH ()-[r]->() RETURN count(r) AS c", true);
    try expectAnswers(.edges, &qa, "MATCH ()-[r:E6702]->() RETURN count(*) AS c LIMIT 2", true);

    // Windows that may drop the row: the single-label and general node counts.
    const dropping = [_][]const u8{
        "MATCH (n:M) RETURN count(*) AS c LIMIT 0",
        "MATCH (n:M) RETURN count(*) AS c SKIP 1",
        "MATCH (n:M) RETURN count(*) AS c OFFSET 1",
        "MATCH (n:M) RETURN count(n) AS c OFFSET 1 LIMIT 3",
        "MATCH (n:M) RETURN count(*) AS c LIMIT $l",
        "MATCH (n:M) RETURN count(*) AS c OFFSET $s",
    };
    for (dropping) |query| {
        try expectAnswers(.label_refcount, &qa, query, false);
        try expectAnswers(.nodes, &qa, query, false);
    }
    try expectAnswers(.nodes, &qa, "MATCH (n) RETURN count(*) AS c OFFSET 1", false);

    // The edge count and the filtered count.
    try expectAnswers(.edges, &qa, "MATCH ()-[r]->() RETURN count(r) AS c LIMIT 0", false);
    try expectAnswers(.edges, &qa, "MATCH ()-[r]->() RETURN count(r) AS c OFFSET 1", false);
    try expectAnswers(.edges, &qa, "MATCH ()-[r:E6702]->() RETURN count(*) AS c LIMIT $l", false);
    try expectAnswers(.filtered, &qa, "MATCH (n:M) WHERE n.i = 3 RETURN count(*) AS c OFFSET 1", false);
    try expectAnswers(.filtered, &qa, "MATCH (n:M) WHERE n.i = 3 RETURN count(*) AS c LIMIT $l", false);
    try expectAnswers(.filtered, &qa, "MATCH (n:M) WHERE n.i = 3 RETURN count(*) AS c LIMIT 0", false);
}
