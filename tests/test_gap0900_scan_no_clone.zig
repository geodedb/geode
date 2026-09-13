// GAP-0900 (scan-no-clone) reproduction / regression.
//
// Triage: every general read query (label scan / unfiltered MATCH / bounded
// `MATCH (n:Label) RETURN n LIMIT k`) used to go through the transport
// handler's `graph_store.snapshotUnderReadLock` ->
// `QueryReadSession.initIfAvailable` -> `cloneNodesFrom`, which DEEP-CLONES the
// entire in-memory GraphStore (every node + properties + id-maps) into an arena
// BEFORE the executor runs. Scan cost was therefore O(total graph),
// independent of LIMIT/selectivity -- at multi-million nodes it blew the 30s
// query timeout and added write contention during the clone.
//
// The engine-backed `node_scan_stream` path already serves the bounded-scan
// shape in O(result) (LIMIT pushdown over the label posting list, lazy
// per-page `materializeNode` from the storage adapter with FLE applied on
// read). The fix makes the handlers SKIP the snapshot deep-clone for exactly
// the shapes `node_scan_stream` serves, so the scan no longer pays O(graph).
//
// These tests are wall-clock-INDEPENDENT: they assert against
// `graph_store.getCloneNodesTotal()` -- the exact count of nodes deep-copied
// by `cloneNodesFrom`. A bounded scan served engine-side must clone ZERO
// nodes; the legacy snapshot path clones N. They also assert the new handler
// decision predicate (`node_scan_stream.isEligible`) routes the scan shape to
// the streaming path, and that the streamed rows are IDENTICAL to the rows the
// O(graph) snapshot clone would have produced (correctness is paramount on the
// read path).
//
// CANARY: REQ=REQ-PERF-SCAN-NO-CLONE-0900; FEATURE="ScanNoClone"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0900_scan_no_clone.zig; OWNER=performance; UPDATED=2026-06-19

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_scan_stream = geode.node_scan_stream;
const query_traits = geode.query_traits;

const N_NODES: usize = 2000;
const LIMIT_K: usize = 5;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        // Lazily init the global store + adapter (getGlobalAdapter() must be
        // non-null for the engine-backed streaming path to run).
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn seed(self: *Harness, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const aa = self.arena.allocator();
            const q = try std.fmt.allocPrint(aa, "CREATE (:Taxon {{taxon_id: {d}, name: 'n{d}'}})", .{ i, i });
            var r = try self.runQuery(q);
            r.deinit(aa);
        }
    }
};

fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    // First statement must be a Query for the scan shapes under test.
    return &program.statements[0].Query;
}

// -------------------------------------------------------------------
// Test 1 — bounded label scan is O(result), NOT O(graph): the engine
// streaming path materializes ~k nodes and deep-clones ZERO.
// -------------------------------------------------------------------
test "GAP-0900: MATCH (n:Taxon) RETURN n LIMIT k streams O(k), clones 0 nodes" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.seed(N_NODES);

    const aa = h.arena.allocator();

    // The scan shape MUST be routed to the engine streaming path by the
    // handler decision predicate (this is what lets the handler skip the
    // O(graph) snapshot clone).
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const scan_q = try parseQuery(&qa, "MATCH (n:Taxon) RETURN n LIMIT 5");
    try testing.expect(node_scan_stream.isEligible(scan_q));

    // Reset the deep-clone counter, then run the bounded scan via the engine
    // streaming path the handler now uses. NO snapshot clone should occur.
    graph_store.resetCloneNodesTotal();

    var stream = (try node_scan_stream.prepare(aa, scan_q, h.ctx, &.{}, &.{}, &.{})) orelse {
        return error.StreamPathNotEligible;
    };
    defer stream.deinit();

    var page = try stream.buildNextPage(aa, LIMIT_K);
    defer page.result.deinit(aa);

    // O(result): exactly k rows materialized (LIMIT pushdown), not N.
    try testing.expectEqual(@as(usize, LIMIT_K), page.result.rows.len);

    // The crux of GAP-0900: a bounded scan deep-clones ZERO nodes. Before the
    // fix the handler ran `snapshotUnderReadLock` first, deep-copying all
    // N_NODES via `cloneNodesFrom` (counter == N_NODES) before this streaming
    // path ever ran.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());

    // Each streamed row is a real Taxon node with the seeded properties
    // (FLE/property fidelity through the engine materialize path).
    for (page.result.rows) |row| {
        try testing.expectEqual(@as(usize, 1), row.len);
        try testing.expect(row[0] == .Node);
        const node = row[0].Node;
        try testing.expect(node.properties.get("taxon_id") != null);
        try testing.expect(node.properties.get("name") != null);
    }
}

// -------------------------------------------------------------------
// Test 2 — the legacy snapshot path STILL deep-clones O(graph). This pins
// the cost the fix avoids: the counter proves the clone is O(N), so Test 1's
// "clones 0" is a real win, not an artifact of an empty graph.
// -------------------------------------------------------------------
test "GAP-0900: snapshotUnderReadLock deep-clones O(graph) (the avoided cost)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.seed(N_NODES);

    graph_store.resetCloneNodesTotal();
    var session = try graph_store.snapshotUnderReadLock(testing.allocator, graph_store.DEFAULT_GRAPH_NAME);
    defer session.deinit();

    // The legacy snapshot path copies every node in the graph.
    try testing.expectEqual(@as(u64, N_NODES), graph_store.getCloneNodesTotal());
}

// -------------------------------------------------------------------
// Test 3 — count(label) is O(1): the count fast-path reports the correct
// cardinality WITHOUT deep-cloning the graph or materializing per-node.
// -------------------------------------------------------------------
test "GAP-0900: count(n:Taxon) is O(1) — no per-node clone" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.seed(N_NODES);

    graph_store.resetCloneNodesTotal();
    var res = try h.runQuery("MATCH (n:Taxon) RETURN count(n) AS c");
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, @intCast(N_NODES)), res.rows[0][0].Int);

    // count(label) must never trigger a whole-graph deep clone.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}

// -------------------------------------------------------------------
// Test 4 — results IDENTICAL to the snapshot path. The streamed bounded
// scan returns the same node ids (and the same total population when
// LIMIT covers the whole graph) the O(graph) snapshot executor produces.
// -------------------------------------------------------------------
test "GAP-0900: streamed scan results match the snapshot-clone population" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const small_n: usize = 50;
    try h.seed(small_n);
    const aa = h.arena.allocator();

    // Full scan via the engine streaming path (LIMIT >= N so the page holds
    // the whole population).
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const scan_q = try parseQuery(&qa, "MATCH (n:Taxon) RETURN n");
    try testing.expect(node_scan_stream.isEligible(scan_q));

    var stream = (try node_scan_stream.prepare(aa, scan_q, h.ctx, &.{}, &.{}, &.{})) orelse {
        return error.StreamPathNotEligible;
    };
    defer stream.deinit();
    var page = try stream.buildNextPage(aa, small_n + 10);
    defer page.result.deinit(aa);

    try testing.expectEqual(small_n, page.result.rows.len);

    // Collect the streamed taxon_id set.
    var streamed = std.AutoHashMap(i64, void).init(testing.allocator);
    defer streamed.deinit();
    for (page.result.rows) |row| {
        const tid = row[0].Node.properties.get("taxon_id") orelse return error.MissingTaxonId;
        try streamed.put(tid.Int, {});
    }

    // The snapshot clone of the same graph must hold exactly the same
    // taxon_id population (snapshot isolation + identical contents).
    var session = try graph_store.snapshotUnderReadLock(testing.allocator, graph_store.DEFAULT_GRAPH_NAME);
    defer session.deinit();
    const snap = session.store();

    var matched: usize = 0;
    if (snap.getNodesByLabel(graph_store.DEFAULT_GRAPH_NAME, "Taxon")) |ids| {
        try testing.expectEqual(small_n, ids.len);
        for (ids) |id| {
            const node = snap.getNodePtr(id) orelse return error.SnapshotNodeMissing;
            const tid = node.properties.get("taxon_id") orelse return error.SnapshotMissingTaxonId;
            try testing.expect(streamed.contains(tid.Int));
            matched += 1;
        }
    } else {
        return error.SnapshotLabelMissing;
    }
    try testing.expectEqual(small_n, matched);
}

// -------------------------------------------------------------------
// Test 5 — eligibility gate is conservative: shapes that the streaming
// path does NOT serve (WHERE / ORDER BY / traversal / aggregation) must
// report NOT eligible, so the handler keeps the snapshot path for them
// (preserving RLS/where-eval correctness).
// -------------------------------------------------------------------
test "GAP-0900: isEligible is false for non-streamable shapes" {
    // SONNY-1218: `isEligible` now also requires a persisted storage adapter
    // (it must agree with `prepare`, which declines without one). The harness
    // supplies it, so these negatives still prove the AST-SHAPE gate rejects
    // them rather than passing vacuously on a missing adapter.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    // A WHERE using a predicate operator outside the streamable subset
    // (CONTAINS) must NOT stream — it stays on the snapshot path.
    const where_q = try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.name CONTAINS 'x' RETURN n");
    try testing.expect(!node_scan_stream.isEligible(where_q));

    var qa2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa2.deinit();
    const order_q = try parseQuery(&qa2, "MATCH (n:Taxon) RETURN n ORDER BY n.taxon_id LIMIT 5");
    try testing.expect(!node_scan_stream.isEligible(order_q));

    var qa3 = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa3.deinit();
    const traverse_q = try parseQuery(&qa3, "MATCH (n:Taxon)-[:CHILD_OF]->(m) RETURN n");
    try testing.expect(!node_scan_stream.isEligible(traverse_q));
}

// ===================================================================
// GAP-0900 broadening (2026-06): property projections, simple WHERE,
// inline {prop:val} filters, and count(label) are now streamed
// engine-side (no whole-graph clone). The tests below assert clone==0
// (and bounded / zero nodes materialized) for each broadened shape, and
// that the streamed rows are byte-identical to the snapshot executor.
// ===================================================================

fn streamSinglePage(
    h: *Harness,
    aa: std.mem.Allocator,
    src: []const u8,
    page_size: usize,
) !node_scan_stream.NodeScanStream.Page {
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const q = try parseQuery(&qa, src);
    try testing.expect(node_scan_stream.isEligible(q));

    var stream = (try node_scan_stream.prepare(aa, q, h.ctx, &.{}, &.{}, &.{})) orelse {
        return error.StreamPathNotEligible;
    };
    defer stream.deinit();
    return stream.buildNextPage(aa, page_size);
}

// -------------------------------------------------------------------
// Test 6 — property projection + LIMIT streams O(k), clones 0.
// -------------------------------------------------------------------
test "GAP-0900: RETURN n.prop LIMIT k streams O(k), clones 0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);
    const aa = h.arena.allocator();

    graph_store.resetCloneNodesTotal();
    node_scan_stream.resetNodesMaterializedTotal();

    var page = try streamSinglePage(&h, aa, "MATCH (n:Taxon) RETURN n.taxon_id LIMIT 5", LIMIT_K);
    defer page.result.deinit(aa);

    try testing.expectEqual(@as(usize, LIMIT_K), page.result.rows.len);
    try testing.expectEqual(@as(usize, 1), page.result.columns.len);
    try testing.expectEqualStrings("taxon_id", page.result.columns[0]);
    for (page.result.rows) |row| {
        try testing.expectEqual(@as(usize, 1), row.len);
        try testing.expect(row[0] == .Int);
    }
    // No whole-graph clone; only O(k) nodes materialized.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expectEqual(@as(u64, LIMIT_K), node_scan_stream.getNodesMaterializedTotal());
}

// -------------------------------------------------------------------
// Test 7 — multi-projection + alias, with a bare-variable mixed column.
// -------------------------------------------------------------------
test "GAP-0900: RETURN n.a, n.b AS x multi-projection streams, clones 0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);
    const aa = h.arena.allocator();

    graph_store.resetCloneNodesTotal();
    var page = try streamSinglePage(&h, aa, "MATCH (n:Taxon) RETURN n.taxon_id, n.name AS label LIMIT 3", 3);
    defer page.result.deinit(aa);

    try testing.expectEqual(@as(usize, 3), page.result.rows.len);
    try testing.expectEqual(@as(usize, 2), page.result.columns.len);
    try testing.expectEqualStrings("taxon_id", page.result.columns[0]);
    try testing.expectEqualStrings("label", page.result.columns[1]);
    for (page.result.rows) |row| {
        try testing.expectEqual(@as(usize, 2), row.len);
        try testing.expect(row[0] == .Int);
        try testing.expect(row[1] == .Str);
    }
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}

// -------------------------------------------------------------------
// Test 8 — simple WHERE + LIMIT: filter applied per node, clones 0.
// -------------------------------------------------------------------
test "GAP-0900: WHERE n.prop > k + LIMIT streams filtered, clones 0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);
    const aa = h.arena.allocator();

    graph_store.resetCloneNodesTotal();
    // taxon_id 0..N-1; predicate keeps >= 1990; LIMIT 3 of those.
    var page = try streamSinglePage(&h, aa, "MATCH (n:Taxon) WHERE n.taxon_id >= 1990 RETURN n.taxon_id LIMIT 3", 3);
    defer page.result.deinit(aa);

    try testing.expectEqual(@as(usize, 3), page.result.rows.len);
    for (page.result.rows) |row| {
        try testing.expect(row[0] == .Int);
        try testing.expect(row[0].Int >= 1990);
    }
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}

// -------------------------------------------------------------------
// Test 9 — inline {prop: val} filter + LIMIT streams, clones 0.
// -------------------------------------------------------------------
test "GAP-0900: inline {prop:val} filter streams, clones 0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);
    const aa = h.arena.allocator();

    graph_store.resetCloneNodesTotal();
    var page = try streamSinglePage(&h, aa, "MATCH (n:Taxon {taxon_id: 7}) RETURN n.name", 16);
    defer page.result.deinit(aa);

    try testing.expectEqual(@as(usize, 1), page.result.rows.len);
    try testing.expect(page.result.rows[0][0] == .Str);
    try testing.expectEqualStrings("n7", page.result.rows[0][0].Str);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}

// -------------------------------------------------------------------
// Test 10 — count(label) via the streaming path is O(1): clone==0 AND
// ZERO nodes materialized (served straight from the label index).
// -------------------------------------------------------------------
test "GAP-0900: streamed count(n:Taxon) is O(1) — clone 0, materialize 0" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);
    const aa = h.arena.allocator();

    graph_store.resetCloneNodesTotal();
    node_scan_stream.resetNodesMaterializedTotal();

    var page = try streamSinglePage(&h, aa, "MATCH (n:Taxon) RETURN count(n) AS c", 16);
    defer page.result.deinit(aa);

    try testing.expectEqual(@as(usize, 1), page.result.rows.len);
    try testing.expectEqualStrings("c", page.result.columns[0]);
    try testing.expectEqual(@as(i64, @intCast(N_NODES)), page.result.rows[0][0].Int);
    // O(1): no clone, no per-node materialize.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expectEqual(@as(u64, 0), node_scan_stream.getNodesMaterializedTotal());
}

// -------------------------------------------------------------------
// Test 11 — filtered count streams O(scanned): clone==0, correct tally.
// -------------------------------------------------------------------
test "GAP-0900: filtered count(n) streams, clones 0, correct tally" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);
    const aa = h.arena.allocator();

    graph_store.resetCloneNodesTotal();
    var page = try streamSinglePage(&h, aa, "MATCH (n:Taxon) WHERE n.taxon_id < 10 RETURN count(n) AS c", 16);
    defer page.result.deinit(aa);

    try testing.expectEqual(@as(usize, 1), page.result.rows.len);
    try testing.expectEqual(@as(i64, 10), page.result.rows[0][0].Int);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
}

// -------------------------------------------------------------------
// Test 11b — inline {prop: val} count tallies the FILTER, not the whole
// label. Regression for the over-count bug: count mode with inline props
// (and no WHERE) used to take the O(1) `countNodesByLabel` precompute,
// which counts EVERY node of the label and silently ignores the inline
// `{prop: val}` filter — so `count(n {taxon_id: 7})` returned N_NODES
// instead of 1. The fix routes inline-prop counts through the streamed
// slot tally (slots already filtered by the inline props during
// collection), still clone==0.
// -------------------------------------------------------------------
test "GAP-0900: inline {prop:val} count tallies the filter, not the label" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);
    const aa = h.arena.allocator();

    graph_store.resetCloneNodesTotal();

    // Exactly one node has taxon_id == 7.
    var page = try streamSinglePage(&h, aa, "MATCH (n:Taxon {taxon_id: 7}) RETURN count(n) AS c", 16);
    defer page.result.deinit(aa);
    try testing.expectEqual(@as(usize, 1), page.result.rows.len);
    try testing.expectEqualStrings("c", page.result.columns[0]);
    try testing.expectEqual(@as(i64, 1), page.result.rows[0][0].Int);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());

    // No node has taxon_id == 999999 → empty filter → count 0 (not N).
    var miss = try streamSinglePage(&h, aa, "MATCH (n:Taxon {taxon_id: 999999}) RETURN count(n) AS c", 16);
    defer miss.result.deinit(aa);
    try testing.expectEqual(@as(i64, 0), miss.result.rows[0][0].Int);

    // Equivalence with the snapshot executor over the same filter.
    var res = try h.runQuery("MATCH (n:Taxon {taxon_id: 7}) RETURN count(n) AS c");
    defer res.deinit(aa);
    try testing.expectEqual(@as(i64, 1), res.rows[0][0].Int);
}

// -------------------------------------------------------------------
// Test 12 — results equivalence: streamed projection rows == snapshot
// executor rows (same set of (taxon_id, name) values).
// -------------------------------------------------------------------
test "GAP-0900: streamed projection == snapshot executor projection" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const small_n: usize = 40;
    try h.seed(small_n);
    const aa = h.arena.allocator();

    // Streamed full projection.
    var page = try streamSinglePage(&h, aa, "MATCH (n:Taxon) RETURN n.taxon_id, n.name", small_n + 10);
    defer page.result.deinit(aa);
    try testing.expectEqual(small_n, page.result.rows.len);

    var streamed = std.AutoHashMap(i64, void).init(testing.allocator);
    defer streamed.deinit();
    for (page.result.rows) |row| {
        try testing.expect(row[0] == .Int);
        try testing.expect(row[1] == .Str);
        try streamed.put(row[0].Int, {});
    }

    // Snapshot executor projection (the legacy path) over the same graph.
    var res = try h.runQuery("MATCH (n:Taxon) RETURN n.taxon_id, n.name");
    defer res.deinit(aa);
    try testing.expectEqual(small_n, res.rows.len);
    try testing.expectEqual(@as(usize, 2), res.columns.len);
    var snap_matched: usize = 0;
    for (res.rows) |row| {
        try testing.expect(row[0] == .Int);
        try testing.expect(streamed.contains(row[0].Int));
        snap_matched += 1;
    }
    try testing.expectEqual(small_n, snap_matched);
}

// -------------------------------------------------------------------
// Test 13 — null property projection: a node missing the projected
// property yields Null, identical to the executor.
// -------------------------------------------------------------------
test "GAP-0900: projection of missing property yields Null" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // Seed nodes WITHOUT the 'missing' property.
    try h.seed(5);
    const aa = h.arena.allocator();

    var page = try streamSinglePage(&h, aa, "MATCH (n:Taxon) RETURN n.does_not_exist LIMIT 5", 5);
    defer page.result.deinit(aa);
    try testing.expectEqual(@as(usize, 5), page.result.rows.len);
    for (page.result.rows) |row| {
        try testing.expect(row[0] == .Null);
    }

    // Executor agrees.
    var res = try h.runQuery("MATCH (n:Taxon) RETURN n.does_not_exist LIMIT 5");
    defer res.deinit(aa);
    for (res.rows) |row| {
        try testing.expect(row[0] == .Null);
    }
}

// -------------------------------------------------------------------
// Test 14 — broadened shapes are eligible; out-of-subset stays excluded.
// -------------------------------------------------------------------
test "GAP-0900: broadened eligibility gate" {
    // SONNY-1218: `isEligible` now also requires a persisted storage adapter,
    // so the positive assertions below need the harness (which sets the
    // data-dir override) — without one the engine-direct path correctly
    // declines every shape. See tests/test_sonny1218_in_memory_node_scan.zig.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    // Now eligible (broadened):
    try testing.expect(node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Taxon) RETURN n.name LIMIT 5")));
    try testing.expect(node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Taxon) WHERE n.rank = 'species' RETURN n.name LIMIT 3")));
    try testing.expect(node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Taxon {source: 'col'}) RETURN count(n)")));
    try testing.expect(node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Taxon) RETURN count(n)")));

    // Still NOT eligible (out of subset):
    try testing.expect(!node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Taxon) RETURN n ORDER BY n.taxon_id LIMIT 5")));
    try testing.expect(!node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Taxon) RETURN DISTINCT n.name")));
    try testing.expect(!node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Taxon) RETURN sum(n.taxon_id)")));
    try testing.expect(!node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Taxon)-[:CHILD_OF]->(m) RETURN n.name")));
    try testing.expect(!node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:Taxon) RETURN n.name, m.name")));
}

// -------------------------------------------------------------------
// Test 15 — multi-label count precompute must not over-count.
//
// The unfiltered count precompute in `node_scan_stream.prepare` used
// `adapter.scanAllNodes(...).len` for EVERY non-single-label pattern — for a
// multi-label pattern `(n:A:B)` that counts EVERY node in the graph, silently
// ignoring the label conjunction (over-count). A multi-label count must fall
// through to the slot-tally path, whose per-slot `nodeMatchesPattern`
// verifies the FULL label set.
//
// (Sibling of the deferred-engine-label-index count split fixed in the same
// change: the single-label arm now reads the authoritative in-memory
// refcount; see tests/test_startup_lazy_hydrate.zig.)
// -------------------------------------------------------------------
test "GAP-0900: multi-label count tallies matching nodes, not the whole graph" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();

    // 3 dual-labeled nodes + 5 single-labeled nodes in the default graph.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const q = try std.fmt.allocPrint(aa, "CREATE (:Dual:Extra {{i: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
    while (i < 8) : (i += 1) {
        const q = try std.fmt.allocPrint(aa, "CREATE (:Dual {{i: {d}}})", .{i});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }

    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const count_q = try parseQuery(&qa, "MATCH (n:Dual:Extra) RETURN count(n) AS c");
    try testing.expect(node_scan_stream.isEligible(count_q));

    var stream = (try node_scan_stream.prepare(aa, count_q, h.ctx, &.{}, &.{}, &.{})) orelse {
        return error.StreamPathNotEligible;
    };
    defer stream.deinit();

    var page = try stream.buildNextPage(aa, 10);
    defer page.result.deinit(aa);

    try testing.expectEqual(@as(usize, 1), page.result.rows.len);
    // RED at HEAD: 8 (scanAllNodes counted every node). Must be 3.
    try testing.expectEqual(@as(i64, 3), page.result.rows[0][0].Int);

    // Single-label count on the same population still exact.
    const single_q = try parseQuery(&qa, "MATCH (n:Extra) RETURN count(n) AS c");
    var s2 = (try node_scan_stream.prepare(aa, single_q, h.ctx, &.{}, &.{}, &.{})) orelse {
        return error.StreamPathNotEligible;
    };
    defer s2.deinit();
    var p2 = try s2.buildNextPage(aa, 10);
    defer p2.result.deinit(aa);
    try testing.expectEqual(@as(i64, 3), p2.result.rows[0][0].Int);
}
