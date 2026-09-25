// SONNY-2463 regression: the engine-direct node scan leaked the internals of
// every node it returned.
//
// A row that returns the bare node (`MATCH (n:L) RETURN n`, or a projection
// with a bare `n` column) hands the page the node itself, and the page keeps it
// alive in its `OwnedGraphEntities` until teardown. `OwnedGraphEntities.deinit`
// destroys only the Node struct, because an executor node may not own its
// interior (planned reads keep it in a per-query arena). A node this scan
// materializes does own its interior, so each returned node leaked its property
// keys and values, its label slice and each label, its graph name and its
// property map's entry slice. Memory grew with every row returned, on the
// server's main allocator.
//
// The pages the scan builds now destroy their nodes with the scan's own deep
// `destroyNode`. The tests page `RETURN n` and bare-node projections over nodes
// with two strings, an integer and a list of strings, at several page sizes,
// behind a WHERE, and with the schema-frame sample prefetched and then served
// or dropped. Each reads every returned node while its page is alive and is
// leak-checked (`std.testing.allocator`), which also reports a double free.
//
// CANARY: REQ=REQ-SONNY-2463-BARE-NODE-LEAK; FEATURE="EngineDirectNodeOwnership"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2463_bare_node_leak.zig; OWNER=engine; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const graph_store = geode.graph_store;
const NodeScanStream = geode.node_scan_stream.NodeScanStream;
const many = harness.many;

/// The index `k` that a `seedWide` node was created with, after checking the
/// node is alive and whole: s = 'sKK', t = 'tKK', i = k, l = ['lKK', 'mKK'].
fn checkWideNode(node: *const graph_store.Node) !usize {
    const s = (node.properties.get("s") orelse return error.NodePropertyMissing).String;
    const t = (node.properties.get("t") orelse return error.NodePropertyMissing).String;
    const i = (node.properties.get("i") orelse return error.NodePropertyMissing).Int;
    _ = node.properties.get("l") orelse return error.NodePropertyMissing;
    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("W", node.labels[0]);
    const k: usize = @intCast(i);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "s{d:0>2}", .{k}), s);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "t{d:0>2}", .{k}), t);
    return k;
}

/// Page `stream` to its end at `page_size`. `node_col` is the bare-node column,
/// and each of `s_cols` projects `n.s`: it must equal the node's `s` in an
/// allocation of its own, apart from the node's and from the other `s_cols`.
/// Returns how many rows came back, after checking no node came back twice.
fn drainNodes(stream: *NodeScanStream, page_size: usize, node_col: usize, s_cols: []const usize) !usize {
    const allocator = testing.allocator;
    var seen = [_]bool{false} ** many;
    var rows: usize = 0;
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages > many + 1) return error.NeverFinal;
        var page = try stream.buildNextPage(allocator, page_size);
        defer page.result.deinit(allocator);
        for (page.result.rows) |row| {
            const node = row[node_col].Node;
            const k = try checkWideNode(node);
            try testing.expect(!seen[k]);
            seen[k] = true;
            const own = node.properties.get("s").?.String;
            for (s_cols, 0..) |c, i| {
                try testing.expectEqualStrings(own, row[c].Str);
                try testing.expect(row[c].Str.ptr != own.ptr);
                for (s_cols[0..i]) |earlier| try testing.expect(row[c].Str.ptr != row[earlier].Str.ptr);
            }
            rows += 1;
        }
        if (page.final) break;
    }
    try testing.expect(!stream.hasRemaining());
    return rows;
}

fn executorRowCount(h: *harness.Harness, query: []const u8) !usize {
    var result = try h.run(query);
    defer result.deinit(h.arena.allocator());
    return result.rows.len;
}

test "SONNY-2463: RETURN n frees every returned node in full, at any page size" {
    harness.silenceEngineLogs();
    const allocator = testing.allocator;
    var h = try harness.Harness.init(allocator);
    defer h.deinit();
    try harness.seedWide(&h);
    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();

    const query = "MATCH (n:W) RETURN n";
    try testing.expectEqual(many, try executorRowCount(&h, query));
    for ([_]usize{ 1, 3, 0 }) |page_size| {
        var stream = try harness.openStream(&h, allocator, &qa, query);
        defer stream.deinit();
        try testing.expectEqual(many, try drainNodes(&stream, page_size, 0, &.{}));
    }
}

test "SONNY-2463: RETURN n behind a WHERE, an OFFSET and a LIMIT frees every node" {
    harness.silenceEngineLogs();
    const allocator = testing.allocator;
    var h = try harness.Harness.init(allocator);
    defer h.deinit();
    try harness.seedWide(&h);
    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();

    // The WHERE rejects nodes, the OFFSET skips some that pass, and the LIMIT
    // makes the slot collection check candidates itself: every node is freed
    // on one of those paths or by the page that returns it.
    for ([_][]const u8{
        "MATCH (n:W) WHERE n.i >= 20 RETURN n",
        "MATCH (n:W) WHERE n.i >= 10 RETURN n SKIP 3 LIMIT 4",
    }) |query| {
        const want = try executorRowCount(&h, query);
        var stream = try harness.openStream(&h, allocator, &qa, query);
        defer stream.deinit();
        try testing.expectEqual(want, try drainNodes(&stream, 2, 0, &.{}));
    }
}

test "SONNY-2463: a bare-node projection frees its nodes, prefetched or not" {
    harness.silenceEngineLogs();
    const allocator = testing.allocator;
    var h = try harness.Harness.init(allocator);
    defer h.deinit();
    try harness.seedWide(&h);
    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();

    // `n.s` twice beside the node: each cell is its own copy, not the node's
    // string, so page teardown frees the cells and the node once each.
    const query = "MATCH (n:W) RETURN n, n.s, n.s AS t";
    try testing.expectEqual(many, try executorRowCount(&h, query));
    for ([_]bool{ false, true }) |prefetch| {
        var stream = try harness.openStream(&h, allocator, &qa, query);
        defer stream.deinit();
        if (prefetch) try stream.prefetchSchemaSample(allocator);
        try testing.expectEqual(many, try drainNodes(&stream, 3, 0, &.{ 1, 2 }));
    }

    // Dropped with prefetched rows (and their nodes) still pending: before any
    // page, and after a page served part of them.
    for ([_]usize{ 0, 4 }) |served| {
        var stream = try harness.openStream(&h, allocator, &qa, query);
        defer stream.deinit();
        try stream.prefetchSchemaSample(allocator);
        if (served > 0) {
            var page = try stream.buildNextPage(allocator, served);
            defer page.result.deinit(allocator);
            for (page.result.rows) |row| _ = try checkWideNode(row[0].Node);
        }
        try testing.expect(stream.hasRemaining());
    }
}
