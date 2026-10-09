// SONNY-2464 regression: the engine-direct node scan leaked every property
// value that no row took over.
//
// `.Member` evaluation hands a projection cell the node's own string, and the
// page frees its cells, so `destroyNode` freed a node's property KEYS only: a
// value that a row had taken would otherwise have been freed twice. Every value
// that no row took therefore leaked, on the server's main allocator:
//   * a key read only by the WHERE clause, on rows that pass;
//   * every value of a node that misses the WHERE;
//   * every value of a node that OFFSET skips;
//   * the predicate's values of every node a filtered count tallies;
//   * every value of every node that `slotMatchesPredicate` checks while it
//     collects the slots of a `WHERE ... LIMIT` scan (it materializes the whole
//     node).
//
// One test per path. Each is leak-checked (`std.testing.allocator`), checked
// against the executor's answer for the same query, and pins the path it
// covers by the number of nodes the scan materialized. The nodes carry two
// strings, an integer and a list of strings, so an extended value is freed
// too.
//
// CANARY: REQ=REQ-SONNY-2464-STRING-VALUE-LEAKS; FEATURE="EngineDirectNodeOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2464_string_value_leaks.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const node_scan_stream = geode.node_scan_stream;
const many = harness.many;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Column 0 of the executor's answer to `query`, sorted (harness-arena owned).
fn executorColumn0(h: *harness.Harness, query: []const u8) ![][]const u8 {
    const aa = h.arena.allocator();
    var result = try h.run(query);
    defer result.deinit(aa);
    const out = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, 0..) |row, i| out[i] = try aa.dupe(u8, row[0].Str);
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

/// Column 0 of the fast path's answer to `query`, sorted, and the number of
/// nodes the scan materialized to produce it. The stream prefetches the
/// schema-frame sample first, as both transports do for a projection.
fn fastPathColumn0(h: *harness.Harness, qa: *std.heap.ArenaAllocator, query: []const u8, materialized: *u64) ![][]const u8 {
    const allocator = testing.allocator;
    node_scan_stream.resetNodesMaterializedTotal();
    var stream = try harness.openStream(h, allocator, qa, query);
    defer stream.deinit();
    try stream.prefetchSchemaSample(allocator);
    const got = try harness.drainColumn0(&stream, allocator, 4);
    materialized.* = node_scan_stream.getNodesMaterializedTotal();
    std.mem.sort([]const u8, got, {}, lessThan);
    return got;
}

/// The fast path returns exactly the executor's rows for `query` (no window,
/// so the row set is order-independent), leak-free, after materializing
/// `want_materialized` nodes.
fn expectExecutorRows(query: []const u8, want_rows: usize, want_materialized: u64) !void {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedWide(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    const want = try executorColumn0(&h, query);
    try testing.expectEqual(want_rows, want.len);

    var materialized: u64 = 0;
    const got = try fastPathColumn0(&h, &qa, query, &materialized);
    defer harness.freeStrings(testing.allocator, got);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(want_materialized, materialized);
}

test "SONNY-2464: a key read only by the WHERE is freed on the rows that pass" {
    // Every node passes; each one's `t` is read by the WHERE and by nothing
    // else.
    try expectExecutorRows("MATCH (n:W) WHERE n.t >= 't00' RETURN n.s", many, many);
}

test "SONNY-2464: a node that misses the WHERE is freed in full" {
    // 22 of 25 nodes miss, each holding two strings and a list.
    try expectExecutorRows("MATCH (n:W) WHERE n.i < 3 RETURN n.s, n.t, n.l", 3, many);
}

test "SONNY-2464: a node that OFFSET skips is freed in full" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedWide(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    // Every node passes and the first 5 are skipped. Without an ORDER BY the
    // two paths need not skip the same 5, so compare how many rows come back,
    // and that they are distinct.
    const query = "MATCH (n:W) WHERE n.i >= 0 RETURN n.s, n.t, n.l SKIP 5";
    const want = try executorColumn0(&h, query);
    try testing.expectEqual(many - 5, want.len);

    var materialized: u64 = 0;
    const got = try fastPathColumn0(&h, &qa, query, &materialized);
    defer harness.freeStrings(testing.allocator, got);
    try testing.expectEqual(want.len, got.len);
    try harness.expectDistinct(got);
    try testing.expectEqual(@as(u64, many), materialized);
}

test "SONNY-2464: a filtered count frees the values of every node it tallies" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedWide(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    // `>=` is not the O(1) index-posting shape (a single `=`), so this count
    // is the streamed tally, which reads `t` from every node.
    const query = "MATCH (n:W) WHERE n.t >= 't10' RETURN count(n)";
    var executor = try h.run(query);
    defer executor.deinit(h.arena.allocator());
    try testing.expectEqual(@as(i64, many - 10), executor.rows[0][0].Int);

    node_scan_stream.resetNodesMaterializedTotal();
    var stream = try harness.openStream(&h, testing.allocator, &qa, query);
    defer stream.deinit();
    var page = try stream.buildNextPage(testing.allocator, 0);
    defer page.result.deinit(testing.allocator);
    try testing.expect(page.final);
    try testing.expectEqual(executor.rows[0][0].Int, page.result.rows[0][0].Int);
    try testing.expectEqual(@as(u64, many), node_scan_stream.getNodesMaterializedTotal());
}

test "SONNY-2464: the slot collection of a WHERE ... LIMIT scan frees every node it checks" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    try harness.seedWide(&h);
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    // WHERE with a LIMIT collects slots through `slotMatchesPredicate`, which
    // materializes each candidate in full, until LIMIT of them pass (every node
    // passes here). Paging then materializes the 4 collected slots again: 8.
    const query = "MATCH (n:W) WHERE n.i >= 0 RETURN n.s, n.t LIMIT 4";
    const want = try executorColumn0(&h, query);
    try testing.expectEqual(@as(usize, 4), want.len);

    var materialized: u64 = 0;
    const got = try fastPathColumn0(&h, &qa, query, &materialized);
    defer harness.freeStrings(testing.allocator, got);
    try testing.expectEqual(want.len, got.len);
    try harness.expectDistinct(got);
    try testing.expectEqual(@as(u64, 8), materialized);
}
