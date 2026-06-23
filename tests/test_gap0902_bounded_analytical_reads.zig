// GAP-0902 (bounded-cache analytical reads): the remaining "known limitations"
// in the bounded-node-cache read path.
//
// Three limitations are pinned here as wall-clock-INDEPENDENT regressions
// (assert against exact counters: `getCloneNodesTotal` for the whole-graph
// deep-clone, `residentCount`/`effectiveCap` for the bounded cache, row
// contents for correctness). All under a SMALL node-cache cap so eviction +
// engine-direct reads are genuinely exercised — the live 14.27M scale shape.
//
// 1. STRING ORDER BY correctness. `MATCH (n:Taxon) RETURN n.source_id
//    ORDER BY n.source_id LIMIT k` returned SILENTLY EMPTY: the top-K fast
//    path only handled NUMERIC order keys (`else => continue` skipped strings)
//    AND read the key from the resident cache (evicted nodes → skipped). Must
//    return the correct k rows, sorted, reading the order key engine-direct.
//
// 2. Full-clone elimination for ineligible shapes (ORDER BY / DISTINCT /
//    multi-aggregate / WHERE-count). Under a bounded cache the snapshot path
//    deep-cloned EVERY live node (resident + every evicted node rebuilt) into
//    an O(N)-resident snapshot — the RSS-balloon source. Must serve these
//    engine-direct: clone == 0, resident stays near cap.
//
// 3. Bounded-cache scan latency. A filtered scan must read ONLY the properties
//    the predicate/projection/order-key needs (engine-direct single-property
//    reads), not a full-node hydrate per node — so it is O(N) cheap reads, not
//    O(N) full materializes, and never balloons RSS.
//
// CANARY: REQ=REQ-PERF-BOUNDED-ANALYTICAL-0902; FEATURE="BoundedAnalyticalReads"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0902_bounded_analytical_reads.zig; OWNER=storage; UPDATED=2026-06-22

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const node_scan_stream = geode.node_scan_stream;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const CACHE_CAP: usize = 256;
const N_NODES: usize = 4000;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const BoundedHarness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    store: *graph_store.GraphStore,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !BoundedHarness {
        if (setenv("GEODE_NODE_CACHE_ENTRIES", "256", 1) != 0) return error.SetEnvFailed;

        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        const store = try graph_store.initGlobalStore(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .store = store,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *BoundedHarness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
    }

    // Parse with `geode.parse` (not parseGql) so ORDER BY over `n.<key>`
    // property access is accepted (parseGql enforces ident_order_only).
    pub fn runQuery(self: *BoundedHarness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parse(aa, query, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    // Seed nodes with a STRING source_id ('col:<NNNN>', zero-padded so string
    // order == numeric order) plus a numeric ordinal. Each node is write-
    // through to the engine + cache; the cache self-bounds, evicting cold nodes.
    fn seed(self: *BoundedHarness, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const aa = self.arena.allocator();
            const q = try std.fmt.allocPrint(
                aa,
                "CREATE (:Taxon {{source_id: 'col:{d:0>6}', ordinal: {d}}})",
                .{ i, i },
            );
            var r = try self.runQuery(q);
            r.deinit(aa);
            if (i % 512 == 0) self.store.nodes.reclaimRetired();
        }
        self.store.nodes.reclaimRetired();
    }
};

// ===================================================================
// Limitation 1 — STRING ORDER BY correctness under bounded cache.
// ===================================================================

test "GAP-0902: string ORDER BY ASC LIMIT k returns correct rows (not empty)" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    // Sanity: most of the graph is evicted, so this MUST read engine-direct.
    try testing.expect(h.store.nodes.residentCount() < N_NODES / 2);

    var res = try h.runQuery("MATCH (n:Taxon) RETURN n.source_id ORDER BY n.source_id ASC LIMIT 20");
    defer res.deinit(h.arena.allocator());

    // Pre-fix: SILENTLY EMPTY (string keys skipped by the top-K heap).
    try testing.expectEqual(@as(usize, 20), res.rows.len);
    // ASC string order: 'col:000000', 'col:000001', ... 'col:000019'.
    try testing.expect(res.rows[0][0] == .Str or res.rows[0][0] == .Text);
    const first = switch (res.rows[0][0]) {
        .Str => |s| s,
        .Text => |s| s,
        else => unreachable,
    };
    try testing.expectEqualStrings("col:000000", first);
    const last = switch (res.rows[19][0]) {
        .Str => |s| s,
        .Text => |s| s,
        else => unreachable,
    };
    try testing.expectEqualStrings("col:000019", last);
}

test "GAP-0902: string ORDER BY DESC LIMIT k returns correct rows" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    var res = try h.runQuery("MATCH (n:Taxon) RETURN n.source_id ORDER BY n.source_id DESC LIMIT 20");
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 20), res.rows.len);
    // DESC: highest first → 'col:003999', then 'col:003998', ...
    const first = switch (res.rows[0][0]) {
        .Str => |s| s,
        .Text => |s| s,
        else => unreachable,
    };
    try testing.expectEqualStrings("col:003999", first);
    const last = switch (res.rows[19][0]) {
        .Str => |s| s,
        .Text => |s| s,
        else => unreachable,
    };
    try testing.expectEqualStrings("col:003980", last);
}

test "GAP-0902: numeric ORDER BY still correct under bounded cache (regression)" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    // The numeric path must keep working AND see evicted nodes (engine-direct).
    var res = try h.runQuery("MATCH (n:Taxon) RETURN n.ordinal ORDER BY n.ordinal DESC LIMIT 10");
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 10), res.rows.len);
    try testing.expectEqual(@as(i64, 3999), res.rows[0][0].Int);
    try testing.expectEqual(@as(i64, 3990), res.rows[9][0].Int);
}

// ===================================================================
// Limitation 2 — full-clone elimination for ineligible shapes.
// Each analytical read must NOT deep-clone the whole graph (clone == 0)
// and the resident cache must stay bounded near the cap.
// ===================================================================

test "GAP-0902: ORDER BY does NOT deep-clone the whole graph" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    graph_store.resetCloneNodesTotal();
    var res = try h.runQuery("MATCH (n:Taxon) RETURN n.source_id ORDER BY n.source_id ASC LIMIT 20");
    defer res.deinit(h.arena.allocator());
    try testing.expectEqual(@as(usize, 20), res.rows.len);

    // The crux: NO whole-graph deep clone (was N_NODES via cloneNodesFrom).
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    // Cache stayed bounded — no O(N)-resident snapshot.
    try testing.expect(h.store.nodes.residentCount() <= CACHE_CAP);
}

test "GAP-0902: DISTINCT does NOT deep-clone the whole graph" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    graph_store.resetCloneNodesTotal();
    var res = try h.runQuery("MATCH (n:Taxon) RETURN DISTINCT n.source_id");
    defer res.deinit(h.arena.allocator());

    // All source_id are distinct → N rows.
    try testing.expectEqual(N_NODES, res.rows.len);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expect(h.store.nodes.residentCount() <= CACHE_CAP);
}

test "GAP-0902: multi-aggregate does NOT deep-clone the whole graph" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    graph_store.resetCloneNodesTotal();
    var res = try h.runQuery("MATCH (n:Taxon) RETURN min(n.ordinal) AS lo, max(n.ordinal) AS hi");
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 0), res.rows[0][0].Int);
    try testing.expectEqual(@as(i64, @intCast(N_NODES - 1)), res.rows[0][1].Int);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expect(h.store.nodes.residentCount() <= CACHE_CAP);
}

test "GAP-0902: single aggregate (sum/min/max) sees evicted nodes, clone 0" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    // sum/min/max over ALL nodes (incl. evicted) via the engine-direct
    // propertyAggregateFastPath. ordinal = 0..N-1.
    const expected_sum: i64 = @intCast(N_NODES * (N_NODES - 1) / 2);

    graph_store.resetCloneNodesTotal();
    var s = try h.runQuery("MATCH (n:Taxon) RETURN sum(n.ordinal) AS s");
    defer s.deinit(h.arena.allocator());
    try testing.expectEqual(expected_sum, s.rows[0][0].Int);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());

    var mn = try h.runQuery("MATCH (n:Taxon) RETURN min(n.ordinal) AS m");
    defer mn.deinit(h.arena.allocator());
    try testing.expectEqual(@as(i64, 0), mn.rows[0][0].Int);

    var mx = try h.runQuery("MATCH (n:Taxon) RETURN max(n.ordinal) AS m");
    defer mx.deinit(h.arena.allocator());
    try testing.expectEqual(@as(i64, @intCast(N_NODES - 1)), mx.rows[0][0].Int);

    // WHERE-filtered single aggregate also engine-direct + correct.
    var sf = try h.runQuery("MATCH (n:Taxon) WHERE n.ordinal < 10 RETURN sum(n.ordinal) AS s");
    defer sf.deinit(h.arena.allocator());
    try testing.expectEqual(@as(i64, 45), sf.rows[0][0].Int); // 0+1+..+9
    try testing.expect(h.store.nodes.residentCount() <= CACHE_CAP);
}

test "GAP-0902: WHERE-count (count_filtered) does NOT deep-clone the whole graph" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try h.seed(N_NODES);

    graph_store.resetCloneNodesTotal();
    // Predicate that needs a non-indexed property read per node.
    var res = try h.runQuery("MATCH (n:Taxon) WHERE n.ordinal < 100 RETURN count(n) AS c");
    defer res.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, 100), res.rows[0][0].Int);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expect(h.store.nodes.residentCount() <= CACHE_CAP);
}

// ===================================================================
// Correctness equivalence: the analytical results under a bounded cache
// must match the full population (every node, incl. evicted ones).
// ===================================================================

test "GAP-0902: ORDER BY full population correctness (covers evicted nodes)" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    const small_n: usize = 500; // > cap so eviction happens, small enough to LIMIT-all
    try h.seed(small_n);

    // LIMIT covering all → the sorted projection must contain every ordinal.
    var res = try h.runQuery("MATCH (n:Taxon) RETURN n.ordinal ORDER BY n.ordinal ASC LIMIT 500");
    defer res.deinit(h.arena.allocator());
    try testing.expectEqual(small_n, res.rows.len);
    // Strictly ascending, complete 0..499.
    for (res.rows, 0..) |row, idx| {
        try testing.expectEqual(@as(i64, @intCast(idx)), row[0].Int);
    }
}

// ===================================================================
// Limitation 2 — the transport handler skip predicate. The analytical
// shapes must be recognized as "served engine-direct" so the handler
// skips the O(all-nodes) snapshot clone; shapes that need the snapshot
// (RLS / traversal / multi-chain) must NOT be.
// ===================================================================

fn isEngineDirectShape(aa: std.mem.Allocator, src: []const u8) !bool {
    var parsed = try geode.parse(aa, src, .{});
    defer parsed.deinit();
    return geode.planned_read_runtime.isStorageNativeReadShape(&parsed.program.statements[0].Query);
}

test "GAP-0902: analytical shapes are recognized as engine-direct (skip snapshot)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Engine-direct (single-chain reads — handler skips the snapshot clone):
    try testing.expect(try isEngineDirectShape(aa, "MATCH (n:Taxon) RETURN n.source_id ORDER BY n.source_id LIMIT 20"));
    try testing.expect(try isEngineDirectShape(aa, "MATCH (n:Taxon) RETURN DISTINCT n.source_id"));
    try testing.expect(try isEngineDirectShape(aa, "MATCH (n:Taxon) RETURN min(n.ordinal), max(n.ordinal)"));
    try testing.expect(try isEngineDirectShape(aa, "MATCH (n:Taxon) RETURN sum(n.ordinal)"));
    try testing.expect(try isEngineDirectShape(aa, "MATCH (n:Taxon) WHERE n.ordinal < 100 RETURN count(n)"));
    try testing.expect(try isEngineDirectShape(aa, "MATCH (n:Taxon) RETURN n.source_id"));

    // A single-chain traversal IS storage-native (planned-read materializes
    // path rows engine-direct), so it is ALSO engine-direct — no clone.
    try testing.expect(try isEngineDirectShape(aa, "MATCH (n:Taxon)-[:CHILD_OF]->(m:Taxon) RETURN n.source_id"));

    // NOT engine-direct (must KEEP the snapshot clone / full executor):
    //   - mutation embedded in the read program (SET) → not a pure read shape
    try testing.expect(!try isEngineDirectShape(aa, "MATCH (n:Taxon) SET n.x = 1 RETURN n.source_id"));
    //   - multi-chain (comma-separated patterns) → planned-read declines
    try testing.expect(!try isEngineDirectShape(aa, "MATCH (n:Taxon), (m:Taxon) RETURN n.source_id"));
    //   - OPTIONAL MATCH → planned-read declines
    try testing.expect(!try isEngineDirectShape(aa, "OPTIONAL MATCH (n:Taxon) RETURN n.source_id"));
}

// ===================================================================
// Limitation 3 — selective per-key reads. A filtered/projected scan over
// WIDE nodes must read ONLY the referenced keys (correct results), not
// every persisted property. Validated via the node_scan_stream path.
// ===================================================================

// Seed WIDE Taxon nodes (8 string properties each) so a full materialize is
// markedly more work than a 1-2 key selective read.
fn seedWide(h: *BoundedHarness, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const aa = h.arena.allocator();
        const q = try std.fmt.allocPrint(
            aa,
            "CREATE (:Wide {{ordinal: {d}, rank: 'species', " ++
                "p1: 'aaaaaaaaaaaaaaaaaaaa{d}', p2: 'bbbbbbbbbbbbbbbbbbbb{d}', " ++
                "p3: 'cccccccccccccccccccc{d}', p4: 'dddddddddddddddddddd{d}', " ++
                "p5: 'eeeeeeeeeeeeeeeeeeee{d}', p6: 'ffffffffffffffffffff{d}'}})",
            .{ i, i, i, i, i, i, i },
        );
        var r = try h.runQuery(q);
        r.deinit(aa);
        if (i % 512 == 0) h.store.nodes.reclaimRetired();
    }
    h.store.nodes.reclaimRetired();
}

fn parseQueryAst(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

test "GAP-0902: selective per-key read — WHERE+projection on wide nodes is correct" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try seedWide(&h, N_NODES);
    const aa = h.arena.allocator();

    // WHERE on `ordinal`, project `p3` — only {ordinal, p3} are referenced.
    // The selective read must fetch just those keys and still return correct
    // values for the matched (engine-direct, incl. evicted) nodes.
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();
    const q = try parseQueryAst(&qa, "MATCH (n:Wide) WHERE n.ordinal < 5 RETURN n.p3, n.ordinal");
    try testing.expect(node_scan_stream.isEligible(q));

    var stream = (try node_scan_stream.prepare(aa, q, h.ctx, &.{}, &.{}, &.{})) orelse return error.NotEligible;
    defer stream.deinit();
    var page = try stream.buildNextPage(aa, 64);
    defer page.result.deinit(aa);

    // 5 matches (ordinal 0..4), each with the correct p3 + ordinal values.
    try testing.expectEqual(@as(usize, 5), page.result.rows.len);
    var seen = std.AutoHashMap(i64, void).init(testing.allocator);
    defer seen.deinit();
    for (page.result.rows) |row| {
        try testing.expectEqual(@as(usize, 2), row.len);
        const ord = row[1].Int;
        try testing.expect(ord >= 0 and ord < 5);
        const expect_p3 = try std.fmt.allocPrint(aa, "cccccccccccccccccccc{d}", .{ord});
        const got_p3 = switch (row[0]) {
            .Str => |s| s,
            .Text => |s| s,
            else => return error.WrongType,
        };
        try testing.expectEqualStrings(expect_p3, got_p3);
        try seen.put(ord, {});
    }
    try testing.expectEqual(@as(usize, 5), seen.count());

    // Equivalence with the snapshot executor over the same filter+projection.
    var res = try h.runQuery("MATCH (n:Wide) WHERE n.ordinal < 5 RETURN n.p3, n.ordinal");
    defer res.deinit(aa);
    try testing.expectEqual(@as(usize, 5), res.rows.len);
}

test "GAP-0902: selective per-key read — filtered count on wide nodes is correct" {
    var h = try BoundedHarness.init(testing.allocator);
    defer h.deinit();
    try seedWide(&h, N_NODES);
    const aa = h.arena.allocator();

    // count with a WHERE on `rank` — only {rank} is referenced. Engine-direct
    // selective read; correct tally over ALL nodes (incl. evicted).
    graph_store.resetCloneNodesTotal();
    var res = try h.runQuery("MATCH (n:Wide) WHERE n.rank = 'species' RETURN count(n) AS c");
    defer res.deinit(aa);
    try testing.expectEqual(@as(i64, @intCast(N_NODES)), res.rows[0][0].Int);
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expect(h.store.nodes.residentCount() <= CACHE_CAP);
}
