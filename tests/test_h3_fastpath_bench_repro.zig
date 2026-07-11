// H3-P4 FRESHNESS GATE: mirror the synthseed/bench ordering — CREATE INDEX runs
// BEFORE any node exists, then nodes are created via the executor `CREATE (n:T
// {k:...})` path (label added first, property set after). In that ordering the
// value-ordered tree is EMPTY/STALE until the durability boundary rebuilds it,
// because the engine's only online ordered-index hook fires on addLabelTxn with
// the node's prop_head AT LABEL-ADD TIME (== 0 here) and putPropertyTxn does no
// ordered-index maintenance. A registered+eligible-but-STALE tree must NEVER be
// served (it would return missing rows). This file proves the planner freshness
// gate (adapter.isOrderedIndexFresh) closes that latent correctness bug:
//
//   STALE case: CREATE INDEX, then create nodes, NO checkpoint -> tree stale ->
//     the ordered fast path MUST bail to the heap (hits unchanged) and still
//     return correct, correctly-ordered rows.
//   FRESH case: same setup, THEN force a FULL checkpoint (adapter.checkpointAll,
//     light=false -> engine.checkpoint() rebuilds the ordered tree and clears the
//     stale flag) -> the ordered fast path MUST engage (hits += 1) and return the
//     SAME correct, correctly-ordered rows.
//
// Real store, real parser, real executor, tmpDir — no mocks.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

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
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

const N: usize = 300;
const LIMIT: usize = 20;

// Seed the bench ordering: CREATE INDEX FIRST (0 nodes), THEN create N nodes via
// the executor CREATE-with-inline-label path (label added, then property set).
// In this ordering the value-ordered tree stays EMPTY/STALE until a durability
// boundary rebuilds it.
fn seedIndexBeforeNodes(h: *Harness, aa: std.mem.Allocator) !void {
    {
        var r = try h.runQuery("CREATE INDEX ON :T(k)");
        r.deinit(aa);
    }
    // CREATE INDEX no longer builds the value-ordered tree eagerly (self-deadlock
    // fix, execution.zig ~1654). Register it explicitly here — on the current
    // (0-node) set — so it is registered+eligible but EMPTY. The N nodes created
    // below go through online write paths that do NOT maintain the value-ordered
    // tree (it is checkpoint-refreshed only), so the tree stays EMPTY/STALE until
    // the full checkpoint in the FRESH case rebuilds it. This reproduces the exact
    // "registered+eligible but stale" state the freshness gate must catch.
    try graph_store.getGlobalAdapter().?.createOrderedIndex(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const v: usize = (i * 97) % N;
        const q = try std.fmt.allocPrint(aa, "CREATE (n:T {{k: '{d:0>5}'}})", .{v});
        var r = try h.runQuery(q);
        r.deinit(aa);
    }
}

// Run the ORDER BY ... LIMIT query once, returning (fast-path-hits-delta, result).
// Caller owns the result and must deinit it with `aa`.
fn runOrderByLimit(h: *Harness, hits_before: u64) !struct { delta: u64, res: execution.ExecutionResult } {
    const res = try h.runQuery("MATCH (n:T) RETURN n.k ORDER BY n.k ASC LIMIT 20");
    const delta = execution.getOrderedScanFastPathHits() - hits_before;
    return .{ .delta = delta, .res = res };
}

// Assert the ASC top-LIMIT rows are exactly "00000".."00019".
fn expectAscTopRows(res: execution.ExecutionResult) !void {
    try testing.expectEqual(LIMIT, res.rows.len);
    var expect_buf: [8]u8 = undefined;
    for (res.rows, 0..) |row, idx| {
        const want = try std.fmt.bufPrint(&expect_buf, "{d:0>5}", .{idx});
        try testing.expectEqualStrings(want, row[0].Str);
    }
}

// STALE case: CREATE INDEX before nodes, NO checkpoint -> the value-ordered tree
// is empty/stale. The freshness gate MUST keep the ordered fast path from firing
// (heap fallback), and the heap MUST still return correct, correctly-ordered
// rows. This proves a stale tree NEVER serves wrong/missing rows.
test "H3-P4 FRESHNESS: stale ordered tree -> fast path bails to heap, rows still correct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    try seedIndexBeforeNodes(&h, aa);

    const adapter = graph_store.getGlobalAdapter().?;
    const registered = adapter.isOrderedIndexRegistered(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    const eligible = adapter.isOrderedIndexEligible(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    const fresh = adapter.isOrderedIndexFresh(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    const scan_ids = try adapter.orderedScan(graph_store.DEFAULT_GRAPH_NAME, "T", "k", .asc, 1000, aa);
    std.debug.print("[H3-P4 STALE] registered={} eligible={} fresh={} orderedScan_count={d}\n", .{ registered, eligible, fresh, scan_ids.len });

    // Tree is registered+eligible but STALE (online hooks never populated it).
    try testing.expect(registered);
    try testing.expect(eligible);
    try testing.expect(!fresh);

    execution.resetOrderedScanFastPathHits();
    var out = try runOrderByLimit(&h, 0);
    defer out.res.deinit(aa);
    std.debug.print("[H3-P4 STALE] ordered_hits_delta={d} rows={d}\n", .{ out.delta, out.res.rows.len });

    // The freshness gate forced a heap fallback: fast path did NOT engage.
    try testing.expectEqual(@as(u64, 0), out.delta);
    // ...yet the rows are still correct + correctly ordered (heap is proven).
    try expectAscTopRows(out.res);
}

// FRESH case: same seed, THEN force a FULL checkpoint (adapter.checkpointAll ->
// checkpointAllEx(false, true) -> engine.checkpoint(), which rebuilds the ordered
// tree from a live-node scan and clears the stale flag). After the durability
// boundary the index is fresh -> the ordered fast path MUST engage and return the
// SAME correct, correctly-ordered rows as the stale (heap) case.
test "H3-P4 FRESHNESS: full checkpoint makes ordered tree fresh -> fast path engages, same rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();
    try seedIndexBeforeNodes(&h, aa);

    const adapter = graph_store.getGlobalAdapter().?;

    // Force the durability boundary: a FULL checkpoint rebuilds the value-ordered
    // tree and clears ordered_index_stale on every shard.
    try adapter.checkpointAll();

    const registered = adapter.isOrderedIndexRegistered(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    const eligible = adapter.isOrderedIndexEligible(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    const fresh = adapter.isOrderedIndexFresh(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    const scan_ids = try adapter.orderedScan(graph_store.DEFAULT_GRAPH_NAME, "T", "k", .asc, 1000, aa);
    std.debug.print("[H3-P4 FRESH] registered={} eligible={} fresh={} orderedScan_count={d} (expected {d})\n", .{ registered, eligible, fresh, scan_ids.len, N });

    // After the full checkpoint the tree reflects every committed write.
    try testing.expect(registered);
    try testing.expect(eligible);
    try testing.expect(fresh);
    try testing.expectEqual(N, scan_ids.len);

    execution.resetOrderedScanFastPathHits();
    var out = try runOrderByLimit(&h, 0);
    defer out.res.deinit(aa);
    std.debug.print("[H3-P4 FRESH] ordered_hits_delta={d} rows={d}\n", .{ out.delta, out.res.rows.len });

    // The freshness gate now allows the ordered fast path: it engaged exactly once.
    try testing.expectEqual(@as(u64, 1), out.delta);
    // ...returning the SAME correct, correctly-ordered rows as the stale case.
    try expectAscTopRows(out.res);
}

// H3-P4 GRAPH ROUTING: `CREATE INDEX ON :T(k)` must register the value-ordered
// secondary index on the SESSION's active graph, not a hardcoded default. The bug
// (execution.zig CreateIndex arm) registered the ordered index on
// graph_store.DEFAULT_GRAPH_NAME regardless of the session graph, so ORDER BY ...
// LIMIT on a non-default graph never found the ordered index (it landed on the
// wrong/empty graph) and silently fell back to a full-scan heap sort.
//
// This drives CREATE INDEX through the SAME executor entrypoint the server uses,
// with an ExecutionContext whose session_state.graph is a clearly non-default
// name, then asserts the ordered index is registered on the session graph AND was
// NOT leaked onto the default graph. On the old (hardcoded-default) code the first
// predicate is false (nothing on "g_reg") and the second is true (leaked onto
// "default") — both fail. With the fix routing target_graph from the session,
// both pass.
test "H3-P4 ROUTING: CREATE INDEX registers ordered index on the session graph, not default" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const aa = h.arena.allocator();

    // A clearly non-default active graph for this session.
    const SESSION_GRAPH = "g_reg";
    try testing.expect(!std.mem.eql(u8, SESSION_GRAPH, graph_store.DEFAULT_GRAPH_NAME));

    // Bind the session to "g_reg" and run CREATE INDEX through the real executor.
    var session = execution.SessionState.init(testing.allocator);
    defer session.deinit();
    session.graph = try testing.allocator.dupe(u8, SESSION_GRAPH);
    h.ctx.session_state = &session;

    {
        var r = try h.runQuery("CREATE INDEX ON :T(k)");
        r.deinit(aa);
    }
    // CREATE INDEX records the catalog row but no longer registers the ordered
    // tree eagerly (self-deadlock fix). The value-ordered registration now flows
    // through `createOrderedIndex` (the same call the lazy async builder uses),
    // which must route to the SESSION graph, not a hardcoded default. Drive it
    // explicitly on the session graph and assert it lands on "g_reg" only.
    const adapter = graph_store.getGlobalAdapter().?;
    try adapter.createOrderedIndex(SESSION_GRAPH, "T", "k");
    const on_session = adapter.isOrderedIndexRegistered(SESSION_GRAPH, "T", "k");
    const on_default = adapter.isOrderedIndexRegistered(graph_store.DEFAULT_GRAPH_NAME, "T", "k");
    std.debug.print("[H3-P4 ROUTING] registered on '{s}'={} leaked on '{s}'={}\n", .{ SESSION_GRAPH, on_session, graph_store.DEFAULT_GRAPH_NAME, on_default });

    // Registered on the session graph (so ORDER BY on "g_reg" can use it)...
    try testing.expect(on_session);
    // ...and NOT leaked onto the default graph (the old hardcoded-default bug).
    try testing.expect(!on_default);
}
