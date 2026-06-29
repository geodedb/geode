// Covered OPTIONAL MATCH left-outer engine-direct regression tests.
//
// GOAL
// ====
// The common single-chain shape
//   MATCH (p {bound}) OPTIONAL MATCH (p)-[:R]->(c) RETURN ...
// must be served ENGINE-DIRECT (storage-native planned-read path) with correct
// openCypher left-outer semantics, WITHOUT the whole-graph deep clone the
// legacy optional executor relies on in the transport path.
//
// OBSERVABLES
// ===========
// - graph_store.getCloneNodesTotal() delta == 0 for the covered shape (no
//   whole-graph clone). It also stays 0 in this in-process harness for the
//   legacy fallback (the legacy executor reads the live store directly), so it
//   acts as a guard, not the RED discriminator.
// - planned_read_runtime.getPathRowsMaterialized() > 0 proves the storage-native
//   (engine-direct) path produced the rows. The legacy executor never
//   increments this counter, so it is the RED discriminator: 0 before the fix,
//   > 0 after.
//
// LEFT-OUTER CORRECTNESS BAR
// ==========================
// - parent with N children -> N rows (one per optional match)
// - parent with 0 children -> exactly ONE row, optional bindings NULL.
//
// CANARY: REQ=REQ-READ-OPTIONAL-LEFTOUTER-ENGINE-DIRECT; FEATURE="OptionalMatchEngineDirect"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_optional_match_engine_direct.zig; OWNER=execution; UPDATED=2026-06-29

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

// ---------------------------------------------------------------------------
// Harness (mirrors tests/test_multichain_hashjoin.zig)
// ---------------------------------------------------------------------------

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
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn exec(self: *Harness, query: []const u8) !void {
        var r = try self.runQuery(query);
        r.deinit(self.arena.allocator());
    }

    // p1 -> {c1, c2}; p2 -> {} (childless). All :T nodes carry a `k` string key.
    pub fn seed(self: *Harness) !void {
        try self.exec(
            "CREATE (p1:T {k:'p1'}), (c1:T {k:'c1'}), (c2:T {k:'c2'}), (p2:T {k:'p2'}), " ++
                "(p1)-[:R]->(c1), (p1)-[:R]->(c2)",
        );
    }
};

fn strEq(v: Value, expected: []const u8) bool {
    return switch (v) {
        .Str => |s| std.mem.eql(u8, s, expected),
        else => false,
    };
}

fn isNull(v: Value) bool {
    return switch (v) {
        .Null => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Test 1: parent WITH children -> N rows, engine-direct, no clone.
// ---------------------------------------------------------------------------
test "covered OPTIONAL MATCH (parent with children) is engine-direct, N rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    graph_store.resetCloneNodesTotal();
    planned_read_runtime.resetPathRowsMaterialized();

    var r = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R]->(c:T) RETURN p.k, c.k");
    defer r.deinit(h.arena.allocator());

    // p1 has two children -> two rows.
    try testing.expectEqual(@as(usize, 2), r.rows.len);

    // Both rows are (p1, c?) with c in {c1, c2}, no duplicates.
    var saw_c1 = false;
    var saw_c2 = false;
    for (r.rows) |row| {
        try testing.expect(row.len >= 2);
        try testing.expect(strEq(row[0], "p1"));
        if (strEq(row[1], "c1")) saw_c1 = true;
        if (strEq(row[1], "c2")) saw_c2 = true;
    }
    try testing.expect(saw_c1 and saw_c2);

    // No whole-graph clone.
    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    // Engine-direct path produced the rows (RED before fix: 0).
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
}

// ---------------------------------------------------------------------------
// Test 2: parent WITHOUT children -> exactly ONE row, optional bindings NULL.
// ---------------------------------------------------------------------------
test "covered OPTIONAL MATCH (childless parent) emits one NULL-filled row" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    graph_store.resetCloneNodesTotal();
    planned_read_runtime.resetPathRowsMaterialized();

    var r = try h.runQuery("MATCH (p:T {k:'p2'}) OPTIONAL MATCH (p)-[:R]->(c:T) RETURN p.k, c.k");
    defer r.deinit(h.arena.allocator());

    // Exactly one row, with c.k NULL.
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expect(r.rows[0].len >= 2);
    try testing.expect(strEq(r.rows[0][0], "p2"));
    try testing.expect(isNull(r.rows[0][1]));

    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
}

// ---------------------------------------------------------------------------
// Test 3: optional-endpoint inline prop filters an edge.
//   {k:'c1'} keeps only the c1 edge -> exactly one (p1, c1) row.
//   {k:'nope'} filters every edge -> exactly one (p1, NULL) row.
// ---------------------------------------------------------------------------
test "covered OPTIONAL MATCH honors inline prop on optional endpoint" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R]->(c:T {k:'c1'}) RETURN p.k, c.k");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        try testing.expect(strEq(r.rows[0][0], "p1"));
        try testing.expect(strEq(r.rows[0][1], "c1"));
        try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
    }
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R]->(c:T {k:'nope'}) RETURN p.k, c.k");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        try testing.expect(strEq(r.rows[0][0], "p1"));
        try testing.expect(isNull(r.rows[0][1]));
        try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
    }
}

// ---------------------------------------------------------------------------
// Test 4: undirected optional hop. c1 has an INCOMING :R from p1; an
// undirected optional hop must reach p1.
// ---------------------------------------------------------------------------
test "covered OPTIONAL MATCH undirected hop reaches the incoming neighbor" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    graph_store.resetCloneNodesTotal();
    planned_read_runtime.resetPathRowsMaterialized();

    var r = try h.runQuery("MATCH (c:T {k:'c1'}) OPTIONAL MATCH (c)-[:R]-(x:T) RETURN c.k, x.k");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expect(strEq(r.rows[0][0], "c1"));
    try testing.expect(strEq(r.rows[0][1], "p1"));

    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
}

// ---------------------------------------------------------------------------
// Test 5: LIMIT over the covered shape returns the right window (one row),
// still engine-direct.
// ---------------------------------------------------------------------------
test "covered OPTIONAL MATCH respects LIMIT window" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R]->(c:T) RETURN p.k, c.k LIMIT 1");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expect(strEq(r.rows[0][0], "p1"));
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
}

// ---------------------------------------------------------------------------
// Test 6: DIFFERENTIAL vs the clone-path oracle.
// A covered query and a semantically identical query that the gate EXCLUDES
// (a WHERE on the main var forces the legacy executor =
// executeMatchWithOptionalPatterns) must return identical (p.k, c.k) rows.
// The covered query is engine-direct (path-rows > 0); the WHERE variant is
// legacy (path-rows == 0). Both must agree on the row multiset.
// ---------------------------------------------------------------------------
const Pair = struct { a: []const u8, b: []const u8 };

fn cellStr(v: Value) []const u8 {
    return switch (v) {
        .Str => |s| s,
        .Null => "<null>",
        else => "<other>",
    };
}

fn lessPair(_: void, x: Pair, y: Pair) bool {
    const c0 = std.mem.order(u8, x.a, y.a);
    if (c0 != .eq) return c0 == .lt;
    return std.mem.order(u8, x.b, y.b) == .lt;
}

fn collectSortedPairs(allocator: std.mem.Allocator, r: execution.ExecutionResult) ![]Pair {
    var pairs = try allocator.alloc(Pair, r.rows.len);
    for (r.rows, 0..) |row, i| {
        pairs[i] = .{ .a = cellStr(row[0]), .b = cellStr(row[1]) };
    }
    std.mem.sort(Pair, pairs, {}, lessPair);
    return pairs;
}

test "engine-direct OPTIONAL MATCH equals clone-path oracle (differential)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();
    const aa = h.arena.allocator();

    // Engine-direct covered shape.
    planned_read_runtime.resetPathRowsMaterialized();
    var direct = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R]->(c:T) RETURN p.k, c.k");
    defer direct.deinit(aa);
    const direct_rows_materialized = planned_read_runtime.getPathRowsMaterialized();
    try testing.expect(direct_rows_materialized > 0); // engine-direct

    // Oracle: WHERE on the main var forces the legacy clone-path executor.
    planned_read_runtime.resetPathRowsMaterialized();
    var oracle = try h.runQuery("MATCH (p:T) OPTIONAL MATCH (p)-[:R]->(c:T) WHERE p.k = 'p1' RETURN p.k, c.k");
    defer oracle.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized()); // legacy path

    const dp = try collectSortedPairs(aa, direct);
    const op = try collectSortedPairs(aa, oracle);
    try testing.expectEqual(op.len, dp.len);
    for (dp, op) |x, y| {
        try testing.expect(std.mem.eql(u8, x.a, y.a));
        try testing.expect(std.mem.eql(u8, x.b, y.b));
    }
}

// ---------------------------------------------------------------------------
// Test 7: FALLBACK shapes must NOT take the engine-direct path
// (getPathRowsMaterialized stays 0 -> legacy clone-path executor), and must
// still return correct rows.
// ---------------------------------------------------------------------------
test "uncovered OPTIONAL MATCH shapes fall back to the clone path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();

    // (a) WHERE references the optional var -> fallback.
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R]->(c:T) WHERE c.k = 'c1' RETURN p.k, c.k");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    }

    // (b) Two OPTIONAL clauses (3 chains) -> fallback.
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R]->(c:T) OPTIONAL MATCH (p)-[:R]->(d:T) RETURN p.k, c.k, d.k");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    }

    // (c) Optional with two hops -> fallback.
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R]->(c:T)-[:R]->(g:T) RETURN p.k, g.k");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    }

    // (d) Optional var-length hop -> fallback.
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {k:'p1'}) OPTIONAL MATCH (p)-[:R*1..2]->(c:T) RETURN p.k, c.k");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    }
}

// ---------------------------------------------------------------------------
// Test 8 (gate-tightening FIX 1): a CORRELATED inline prop on the optional
// endpoint ({k: p.k}) must NOT take the engine-direct path. propsMatch
// evaluates inline values with an EMPTY binding Env, so the correlated value
// silently drops the candidate -> engine-direct would emit a NULL row even
// when a child actually matches. The gate must fall back to the clone-path
// oracle (path-rows == 0) AND return the correct row.
// ---------------------------------------------------------------------------
test "correlated optional inline prop falls back to clone path and rows correct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.seed();
    // Parent selected by a UNIQUE `id` (so only px matches the main pattern),
    // with a child cx whose `k` equals px.k -> the correlated prop {k: p.k}
    // matches cx. cx carries no `id`, so it is NOT matched by the main pattern.
    try h.exec("CREATE (px:T {id:'P1', k:'KK'}), (cx:T {k:'KK'}), (px)-[:R]->(cx)");

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery("MATCH (p:T {id:'P1'}) OPTIONAL MATCH (p)-[:R]->(c:T {k: p.k}) RETURN p.k, c.k");
    defer r.deinit(h.arena.allocator());

    // NOT engine-direct: correlated inline prop is unsafe for empty-Env propsMatch.
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    // Correct left-outer rows: cx.k == px.k -> exactly one (KK, KK) row.
    // (The buggy engine-direct path would drop cx and emit (KK, NULL).)
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expect(strEq(r.rows[0][0], "KK"));
    try testing.expect(strEq(r.rows[0][1], "KK"));
}

// ---------------------------------------------------------------------------
// Test 9 (GAP fix): a MULTI-HOP main chain OPTIONAL MATCH is served
// ENGINE-DIRECT with CORRECT left-outer semantics. The legacy clone-path
// executor (executeMatchWithOptionalPatterns) only bound hops[0] of the main
// chain -> NULLs for hops[1+] = a real bug. The engine-direct
// exploreMainHopsForOptional traverses ALL main hops correctly; widening the
// gate routes this shape to it.
//
// HAND-VALIDATED graph (expectations computed by hand, NOT vs the buggy oracle):
//   a1{id:1} -[:R]-> b1{id:11} -[:R]-> c1{id:21}   (c1 has 2 children d1,d2)
//   a1{id:1} -[:R]-> b1{id:11} -[:R]-> c2{id:22}   (c2 has 0 children)
//   a1{id:1} -[:R]-> b2{id:12} -[:R]-> c3{id:23}   (c3 has 1 child d3)
//   c1 -[:R]-> d1{id:31}, c1 -[:R]-> d2{id:32}, c3 -[:R]-> d3{id:33}
//
// MATCH (a:T{id:1})-[:R]->(b)-[:R]->(c) OPTIONAL MATCH (c)-[:R]->(d)
//   RETURN a.id, b.id, c.id, d.id
//
// Three main (a,b,c) paths; left-outer expands optional from c:
//   (1,11,21,31)  (1,11,21,32)        c1 with 2 children -> 2 rows
//   (1,11,22,NULL)                    c2 childless       -> 1 NULL row
//   (1,12,23,33)                      c3 with 1 child    -> 1 row
// = 4 rows total. a,b,c always bound (NEVER NULL); d per left-outer match.
// ---------------------------------------------------------------------------
test "multi-hop main chain OPTIONAL MATCH is engine-direct with correct left-outer rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.exec(
        "CREATE (a1:T {id:1}), (b1:T {id:11}), (b2:T {id:12}), " ++
            "(c1:T {id:21}), (c2:T {id:22}), (c3:T {id:23}), " ++
            "(d1:T {id:31}), (d2:T {id:32}), (d3:T {id:33}), " ++
            "(a1)-[:R]->(b1), (a1)-[:R]->(b2), " ++
            "(b1)-[:R]->(c1), (b1)-[:R]->(c2), (b2)-[:R]->(c3), " ++
            "(c1)-[:R]->(d1), (c1)-[:R]->(d2), (c3)-[:R]->(d3)",
    );

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery(
        "MATCH (a:T {id:1})-[:R]->(b)-[:R]->(c) OPTIONAL MATCH (c)-[:R]->(d) RETURN a.id, b.id, c.id, d.id",
    );
    defer r.deinit(h.arena.allocator());

    // Load-bearing: engine-direct served it (legacy never increments this).
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    // Correct left-outer cardinality: 4 rows.
    try testing.expectEqual(@as(usize, 4), r.rows.len);

    // Hand-computed expected multiset (a.id, b.id, c.id, d.id; d null sentinel).
    const Exp = struct { a: i64, b: i64, c: i64, d: ?i64 };
    const expected = [_]Exp{
        .{ .a = 1, .b = 11, .c = 21, .d = 31 },
        .{ .a = 1, .b = 11, .c = 21, .d = 32 },
        .{ .a = 1, .b = 11, .c = 22, .d = null },
        .{ .a = 1, .b = 12, .c = 23, .d = 33 },
    };
    var matched = [_]bool{false} ** expected.len;
    for (r.rows) |row| {
        // a, b, c must ALWAYS be bound (the legacy bug left them NULL).
        try testing.expect(!isNull(row[0]));
        try testing.expect(!isNull(row[1]));
        try testing.expect(!isNull(row[2]));
        const a = row[0].Int;
        const b = row[1].Int;
        const c = row[2].Int;
        const d: ?i64 = if (isNull(row[3])) null else row[3].Int;
        var found = false;
        for (&matched, 0..) |*used, i| {
            if (used.*) continue;
            const e = expected[i];
            const d_eq = (e.d == null and d == null) or
                (e.d != null and d != null and e.d.? == d.?);
            if (e.a == a and e.b == b and e.c == c and d_eq) {
                used.* = true;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
    for (matched) |used| try testing.expect(used);
}

// ---------------------------------------------------------------------------
// Test 10 (FIX 2 guard against over-narrowing): a SINGLE-HOP main chain with a
// literal-prop / bare optional endpoint stays engine-direct. The gate narrows
// to <=1 hop, so single-hop main is still covered (path-rows > 0).
// ---------------------------------------------------------------------------
test "single-hop main chain stays engine-direct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    // a -> b -> c linear chain.
    try h.exec(
        "CREATE (a:T {k:'a'}), (b:T {k:'b'}), (c:T {k:'c'}), " ++
            "(a)-[:R]->(b), (b)-[:R]->(c)",
    );

    planned_read_runtime.resetPathRowsMaterialized();
    var r = try h.runQuery(
        "MATCH (a:T {k:'a'})-[:R]->(b:T) OPTIONAL MATCH (b)-[:R]->(c:T) RETURN a.k, b.k, c.k",
    );
    defer r.deinit(h.arena.allocator());

    // Engine-direct: single-hop main is covered.
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    // Correct rows: a->b then b->c -> exactly one (a, b, c) row.
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expect(strEq(r.rows[0][0], "a"));
    try testing.expect(strEq(r.rows[0][1], "b"));
    try testing.expect(strEq(r.rows[0][2], "c"));
}
