// Covered bounded var-length traversal engine-direct regression tests.
//
// GOAL
// ====
// The covered bounded var-length shape
//   MATCH (p {bound})-[:R*a..b]->(c) RETURN c          (finite b, directed,
//   bare/acyclic pattern, RETURN endpoint, no edge/path binding, no WHERE/WITH)
// must be served ENGINE-DIRECT (storage-native planned-read path) via a
// depth-bounded acyclic per-path expand, WITHOUT the whole-graph deep clone the
// legacy var-length executor relies on in the transport path. Rows must be a
// byte-identical multiset to the clone-path oracle
// (match_operations.executeVariableLengthPathTraversal), which uses the same
// PathIterator BFS (acyclic, (node,depth) dedup, 10k-iter / 5k-queue caps).
//
// OBSERVABLES
// ===========
// - graph_store.getCloneNodesTotal() delta == 0 for the covered shape (no
//   whole-graph clone). In this in-process harness the legacy executor also
//   reads the live store directly (delta stays 0), so it is a guard, not the
//   RED discriminator.
// - planned_read_runtime.getPathRowsMaterialized() > 0 proves the engine-direct
//   path produced the rows. The legacy executor never increments this counter,
//   so it is the RED discriminator: 0 before the fix, > 0 after; and 0 for every
//   uncovered (fallback) shape.
//
// CORRECTNESS BAR
// ===============
// - bare pattern = ACYCLIC (no repeated node per path).
// - ONE ROW PER QUALIFYING PATH (duplicates allowed; downstream DISTINCT dedups).
// - min_len == 0 includes the seed (0-length path); max_len caps depth.
//
// CANARY: REQ=REQ-READ-VARLEN-ENDPOINT-ENGINE-DIRECT; FEATURE="VarLengthEndpointEngineDirect"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_varlength_engine_direct.zig; OWNER=execution; UPDATED=2026-06-29

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

// ---------------------------------------------------------------------------
// Harness (mirrors tests/test_optional_match_engine_direct.zig)
// ---------------------------------------------------------------------------

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
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
};

fn strEq(v: Value, expected: []const u8) bool {
    return switch (v) {
        .Str => |s| std.mem.eql(u8, s, expected),
        else => false,
    };
}

fn cellStr(v: Value) []const u8 {
    return switch (v) {
        .Str => |s| s,
        .Null => "<null>",
        else => "<other>",
    };
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

// Collect the first column of every row as a sorted string multiset.
fn collectSortedIds(allocator: std.mem.Allocator, r: execution.ExecutionResult) ![][]const u8 {
    var ids = try allocator.alloc([]const u8, r.rows.len);
    for (r.rows, 0..) |row, i| {
        ids[i] = cellStr(row[0]);
    }
    std.mem.sort([]const u8, ids, {}, lessStr);
    return ids;
}

fn expectSameIdMultiset(allocator: std.mem.Allocator, direct: execution.ExecutionResult, oracle: execution.ExecutionResult) !void {
    const dp = try collectSortedIds(allocator, direct);
    const op = try collectSortedIds(allocator, oracle);
    try testing.expectEqual(op.len, dp.len);
    for (dp, op) |x, y| {
        try testing.expect(std.mem.eql(u8, x, y));
    }
}

// ---------------------------------------------------------------------------
// Test 1: covered shape is engine-direct, no clone, correct acyclic rows.
//   p1 -> a -> b -> c (3-level chain) plus a branch p1 -> br, plus an
//   unrelated node u. *1..2 from p1 reaches {a, br} (depth 1) and {b}
//   (depth 2; br is childless) => 3 rows.
// ---------------------------------------------------------------------------
test "covered bounded var-length is engine-direct, no clone, acyclic rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.exec(
        "CREATE (p1:T {id:'p1'}), (a:T {id:'a'}), (b:T {id:'b'}), (c:T {id:'c'}), " ++
            "(br:T {id:'br'}), (u:T {id:'u'}), " ++
            "(p1)-[:R]->(a), (a)-[:R]->(b), (b)-[:R]->(c), (p1)-[:R]->(br)",
    );

    graph_store.resetCloneNodesTotal();
    planned_read_runtime.resetPathRowsMaterialized();

    var r = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..2]->(c:T) RETURN c.id");
    defer r.deinit(h.arena.allocator());

    try testing.expectEqual(@as(usize, 3), r.rows.len);

    var saw_a = false;
    var saw_b = false;
    var saw_br = false;
    for (r.rows) |row| {
        try testing.expect(row.len >= 1);
        if (strEq(row[0], "a")) saw_a = true;
        if (strEq(row[0], "b")) saw_b = true;
        if (strEq(row[0], "br")) saw_br = true;
    }
    try testing.expect(saw_a and saw_b and saw_br);

    try testing.expectEqual(@as(u64, 0), graph_store.getCloneNodesTotal());
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
}

// ---------------------------------------------------------------------------
// Test 2: DIFFERENTIAL *1..1 vs the clone-path oracle.
// The oracle is the SAME query with an edge-list binding -[r:R*1..1]->, which
// the gate EXCLUDES (rel.name != null) -> legacy clone-path executor. r is not
// returned, so the (c.id) row multiset must be identical.
// ---------------------------------------------------------------------------
test "differential *1..1 equals clone-path oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    try h.exec(
        "CREATE (p1:T {id:'p1'}), (a:T {id:'a'}), (b:T {id:'b'}), (cc:T {id:'cc'}), " ++
            "(p1)-[:R]->(a), (p1)-[:R]->(b), (a)-[:R]->(cc)",
    );

    planned_read_runtime.resetPathRowsMaterialized();
    var direct = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..1]->(c:T) RETURN c.id");
    defer direct.deinit(aa);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    planned_read_runtime.resetPathRowsMaterialized();
    var oracle = try h.runQuery("MATCH (p:T {id:'p1'})-[r:R*1..1]->(c:T) RETURN c.id");
    defer oracle.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    try expectSameIdMultiset(aa, direct, oracle);
    // sanity: *1..1 reaches exactly the direct children {a, b}.
    try testing.expectEqual(@as(usize, 2), direct.rows.len);
}

// ---------------------------------------------------------------------------
// Test 3: DIFFERENTIAL *1..3 over a tree (order-invariant; no reconvergence).
//   p1 -> a -> b -> c -> d  and  p1 -> x -> y
//   *1..3 reaches {a,x} (1), {b,y} (2), {c} (3) => 5 rows.
// ---------------------------------------------------------------------------
test "differential *1..3 tree equals clone-path oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    try h.exec(
        "CREATE (p1:T {id:'p1'}), (a:T {id:'a'}), (b:T {id:'b'}), (c:T {id:'c'}), (d:T {id:'d'}), " ++
            "(x:T {id:'x'}), (y:T {id:'y'}), " ++
            "(p1)-[:R]->(a), (a)-[:R]->(b), (b)-[:R]->(c), (c)-[:R]->(d), " ++
            "(p1)-[:R]->(x), (x)-[:R]->(y)",
    );

    planned_read_runtime.resetPathRowsMaterialized();
    var direct = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..3]->(c:T) RETURN c.id");
    defer direct.deinit(aa);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    planned_read_runtime.resetPathRowsMaterialized();
    var oracle = try h.runQuery("MATCH (p:T {id:'p1'})-[r:R*1..3]->(c:T) RETURN c.id");
    defer oracle.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    try expectSameIdMultiset(aa, direct, oracle);
    try testing.expectEqual(@as(usize, 5), direct.rows.len);
}

// ---------------------------------------------------------------------------
// Test 4: DIFFERENTIAL *0..2 (min_len 0 includes the seed as a 0-length path).
//   p1 -> a -> b  and  p1 -> e
//   *0..2 reaches {p1} (0), {a,e} (1), {b} (2) => 4 rows.
// ---------------------------------------------------------------------------
test "differential *0..2 includes seed equals clone-path oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    try h.exec(
        "CREATE (p1:T {id:'p1'}), (a:T {id:'a'}), (b:T {id:'b'}), (e:T {id:'e'}), " ++
            "(p1)-[:R]->(a), (a)-[:R]->(b), (p1)-[:R]->(e)",
    );

    planned_read_runtime.resetPathRowsMaterialized();
    var direct = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*0..2]->(c:T) RETURN c.id");
    defer direct.deinit(aa);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    planned_read_runtime.resetPathRowsMaterialized();
    var oracle = try h.runQuery("MATCH (p:T {id:'p1'})-[r:R*0..2]->(c:T) RETURN c.id");
    defer oracle.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    try expectSameIdMultiset(aa, direct, oracle);
    try testing.expectEqual(@as(usize, 4), direct.rows.len);

    var saw_seed = false;
    for (direct.rows) |row| if (strEq(row[0], "p1")) {
        saw_seed = true;
    };
    try testing.expect(saw_seed); // 0-length path emits the seed
}

// ---------------------------------------------------------------------------
// Test 5: DIFFERENTIAL branchy graph with multiple paths to the same endpoint
// => DUPLICATE rows (one row per qualifying PATH, not per distinct endpoint).
//   p1 -> a -> t  and  p1 -> b -> t   (t reached by two length-2 paths)
//   *1..2 reaches {a,b} (1) and {t,t} (2) => 4 rows, t appears TWICE.
// Reconvergence at depth 2 == max_len, so no further expansion -> the result
// is independent of edge iteration order.
// ---------------------------------------------------------------------------
test "differential branchy duplicate endpoint equals clone-path oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    try h.exec(
        "CREATE (p1:T {id:'p1'}), (a:T {id:'a'}), (b:T {id:'b'}), (t:T {id:'t'}), " ++
            "(p1)-[:R]->(a), (p1)-[:R]->(b), (a)-[:R]->(t), (b)-[:R]->(t)",
    );

    planned_read_runtime.resetPathRowsMaterialized();
    var direct = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..2]->(c:T) RETURN c.id");
    defer direct.deinit(aa);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    planned_read_runtime.resetPathRowsMaterialized();
    var oracle = try h.runQuery("MATCH (p:T {id:'p1'})-[r:R*1..2]->(c:T) RETURN c.id");
    defer oracle.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    try expectSameIdMultiset(aa, direct, oracle);
    try testing.expectEqual(@as(usize, 4), direct.rows.len);

    var t_count: usize = 0;
    for (direct.rows) |row| if (strEq(row[0], "t")) {
        t_count += 1;
    };
    try testing.expectEqual(@as(usize, 2), t_count); // one row per path
}

// ---------------------------------------------------------------------------
// Test 6: endpoint inline label/prop filter restricts emitted rows but NOT
// expansion. {id:'b'} keeps only the depth-2 endpoint b.
// ---------------------------------------------------------------------------
test "covered var-length honors endpoint inline prop filter" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    try h.exec(
        "CREATE (p1:T {id:'p1'}), (a:T {id:'a'}), (b:T {id:'b'}), " ++
            "(p1)-[:R]->(a), (a)-[:R]->(b)",
    );

    planned_read_runtime.resetPathRowsMaterialized();
    var direct = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..2]->(c:T {id:'b'}) RETURN c.id");
    defer direct.deinit(aa);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    planned_read_runtime.resetPathRowsMaterialized();
    var oracle = try h.runQuery("MATCH (p:T {id:'p1'})-[r:R*1..2]->(c:T {id:'b'}) RETURN c.id");
    defer oracle.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    try expectSameIdMultiset(aa, direct, oracle);
    try testing.expectEqual(@as(usize, 1), direct.rows.len);
    try testing.expect(strEq(direct.rows[0][0], "b"));
}

// ---------------------------------------------------------------------------
// Test 7: FALLBACK shapes must NOT take the engine-direct path
// (getPathRowsMaterialized stays 0 -> legacy clone-path executor).
// ---------------------------------------------------------------------------
test "uncovered var-length shapes fall back to the clone path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.exec(
        "CREATE (p1:T {id:'p1'}), (a:T {id:'a'}), (b:T {id:'b'}), " ++
            "(p1)-[:R]->(a), (a)-[:R]->(b)",
    );

    // (a) Unbounded *1.. (no finite max) -> fallback.
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..]->(c:T) RETURN c.id");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    }

    // (b) Path variable -> fallback.
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH pp=(p:T {id:'p1'})-[:R*1..2]->(c:T) RETURN c.id");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    }

    // (c) Edge-list binding -> fallback.
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {id:'p1'})-[r:R*1..2]->(c:T) RETURN c.id");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    }

    // (d) Undirected -> fallback (directed only v1).
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..2]-(c:T) RETURN c.id");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    }

    // (e) WHERE clause -> fallback (v1 rejects any WHERE).
    {
        planned_read_runtime.resetPathRowsMaterialized();
        var r = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..2]->(c:T) WHERE c.id <> 'zzz' RETURN c.id");
        defer r.deinit(h.arena.allocator());
        try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    }
}

// ---------------------------------------------------------------------------
// Test 8: FALLBACK correctness — an excluded shape (edge-list) over the same
// graph must produce the SAME endpoint rows as the covered shape (the legacy
// path is the correctness oracle; this guards that fallback is not just "0
// engine rows" but also right).
// ---------------------------------------------------------------------------
test "fallback edge-list returns same rows as covered shape" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    try h.exec(
        "CREATE (p1:T {id:'p1'}), (a:T {id:'a'}), (b:T {id:'b'}), (br:T {id:'br'}), " ++
            "(p1)-[:R]->(a), (a)-[:R]->(b), (p1)-[:R]->(br)",
    );

    planned_read_runtime.resetPathRowsMaterialized();
    var direct = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..2]->(c:T) RETURN c.id");
    defer direct.deinit(aa);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);

    planned_read_runtime.resetPathRowsMaterialized();
    var oracle = try h.runQuery("MATCH (p:T {id:'p1'})-[r:R*1..2]->(c:T) RETURN c.id");
    defer oracle.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());

    try expectSameIdMultiset(aa, direct, oracle);
}

// ---------------------------------------------------------------------------
// Test 9: DIFFERENTIAL on an ORDER-SENSITIVE re-convergent-then-diverge graph.
// This is the worst case for byte-identity: two distinct prefixes reach the
// same node `m` at the same depth, so the (node,depth) expansion-dedup WINNER
// (which depends on edge iteration order) decides whether depth-3 yields {z}
// or {a,z}. Equality here proves the engine-direct adapter iterates edges in
// the SAME order as the clone-path oracle's store, so the faithful BFS port is
// byte-identical even when re-convergence drives the result.
//   p1->a, p1->b, a->m, b->m, m->a (back-edge), m->z ; *1..3 acyclic.
// ---------------------------------------------------------------------------
test "differential reconvergent-then-diverge equals clone-path oracle" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();
    try h.exec(
        "CREATE (p1:T {id:'p1'}), (a:T {id:'a'}), (b:T {id:'b'}), (m:T {id:'m'}), (z:T {id:'z'}), " ++
            "(p1)-[:R]->(a), (p1)-[:R]->(b), (a)-[:R]->(m), (b)-[:R]->(m), (m)-[:R]->(a), (m)-[:R]->(z)",
    );
    planned_read_runtime.resetPathRowsMaterialized();
    var direct = try h.runQuery("MATCH (p:T {id:'p1'})-[:R*1..3]->(c:T) RETURN c.id");
    defer direct.deinit(aa);
    try testing.expect(planned_read_runtime.getPathRowsMaterialized() > 0);
    planned_read_runtime.resetPathRowsMaterialized();
    var oracle = try h.runQuery("MATCH (p:T {id:'p1'})-[r:R*1..3]->(c:T) RETURN c.id");
    defer oracle.deinit(aa);
    try testing.expectEqual(@as(u64, 0), planned_read_runtime.getPathRowsMaterialized());
    try expectSameIdMultiset(aa, direct, oracle);
}
