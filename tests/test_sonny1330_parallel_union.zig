// CANARY: REQ=REQ-SONNY-1330-PARALLEL-UNION-ARM-SAFETY; FEATURE="ParallelUnionArms"; ASPECT=ReadOnlyArmHydration; STATUS=TESTED; TEST=tests/test_sonny1330_parallel_union.zig; OWNER=execution; UPDATED=2026-09-14
//
// SONNY-1330 — parallel UNION arm thread safety.
//
// `set_operations.tryParallelUnion` spawns one `std.Thread` per UNION arm and
// runs a FULL query on each. Every read those arms make lands on the four
// process-wide bounded caches (`GraphStore.nodes` / `.edges` /
// `.outgoing_edges` / `.incoming_edges`), and the hydrate-on-miss accessors
// (`BoundedNodeCache.getOrHydratePtr` / `.getOrHydrate`) MUTATE those caches:
// a miss INSERTS the rebuilt value into the shard's AutoHashMap and, past the
// cap, EVICTS (unlink + retire) cold entries from it.
//
// Per-shard locks make each map op atomic but cannot make it SAFE here: an
// insert that grows a shard rehashes it and MOVES every value slot, and an
// eviction unlinks a live entry. Sibling arms are simultaneously holding raw
// `*Node` / `*Edge` pointers handed out by earlier `getOrHydratePtr` calls
// (bindings, `base_nodes`, `Value{ .Node = ptr }` inside result rows) and keep
// dereferencing them for the whole arm. One arm's hydrate-on-miss therefore
// invalidates another arm's live pointers — a cross-thread use-after-move that
// the pointer escapes the lock to reach.
//
// THE FIX (approach 1 of the brief): an arm thread's hydration path is
// READ-ONLY. `ArmJob.runnerEntry` brackets the arm in
// `node_cache.beginReadOnlyHydration()`; a miss taken inside that scope never
// touches the map — it records the decline and returns
// `error.CacheHydrationSuppressed`. After the join, if ANY arm declined,
// `tryParallelUnion` drops every arm result and returns `null`, which sends
// the UNION down the SERIAL path on the connection thread where hydration is
// legal. Arm output is therefore either byte-identical to the serial path's or
// discarded; it is never merged half-hydrated.
//
// That fallback re-runs the arms, so `unionArmsAreParallelEligible` now admits
// only side-effect-free arms (`queryIsReadOnly`, every arm not just arm 0) —
// re-running a CREATE/MERGE/SET/DELETE/CALL arm would apply it twice. A write
// can hide BELOW the arm's own clauses in two places, each with its own
// regression below: a CTE body (test 5) and an `IN (…)` / `NOT IN (…)`
// expression subquery (test 6). `queryIsReadOnly` therefore walks `cte_list`,
// `next_query`, and every expression-bearing field through `exprIsReadOnly`,
// which switches exhaustively over `ast.Expr`.
//
// Harness: real store, real parser, real executor — no mocks (the
// `test_gap0814_union_parallelism.zig` pattern).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_cache = graph_store.node_cache_mod;

// SONNY-1330 review follow-up: reached as the NAMED build module (build.zig
// wires `logging` into this test module), which is the SAME `*Module` the
// geode root module imports — so this is the one, shared logger instance the
// engine itself logs through, not a second copy with its own globals.
const logging = @import("logging");

/// Why this test file silences the engine logger and the other `test-sonny*`
/// targets do not:
///
/// SONNY-1318 / SONNY-1326 open their store with the bare
/// `graph_store.getGlobalStore` — no data dir, no storage adapter, so nothing
/// under `geode.storage` ever logs. This suite deliberately uses the
/// PRODUCTION `initGlobalStore` path against a real data dir (that is what
/// installs the hydrate-on-miss hooks and activates the resident caps), which
/// brings the adapter — and with it a steady stream of INFO lines
/// ("loadFromAdapter complete", "full checkpoint: exact-index persist
/// decision", "graph hydration served from loop2 snapshots", …), roughly one
/// per Session.open/close and one per checkpoint, plus the once-per-process
/// `geode.tenancy` WARN.
///
/// Those go to the engine logger's stderr writer. The Zig 0.16 build runner
/// PIPES a `--listen=-` test child's stderr (`Step/Run.zig` `evalZigTest`,
/// which stores it as `step.result_stderr`), so the whole stream is echoed
/// back under the step banner together with a red `failed command:` line even
/// though every test passed and `zig build` exits 0. That is pure noise that
/// makes a green run read as a failure — and `test-sonny1330-parallel-union`
/// is sharded into the default `test_step`, so it polluted the aggregate run
/// too.
///
/// Level `.fatal` rather than `.err`: the `geode.tenancy` line above is a WARN
/// and the engine emits it on the very first tenant-scoped read here, so
/// anything looser still produces the banner. Nothing in this suite asserts on
/// log output.
fn silenceEngineLogs() void {
    // `init` latches on first call (level baked into the handler), `setLevel`
    // covers the case where something already forced a default `.info` logger
    // into existence before we got here. Both are idempotent and cheap.
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Store session bound to a caller-owned data dir, so a test can CLOSE the
/// store (persisting to the engine) and REOPEN it with the bounded caches
/// COLD — the only honest way to force hydrate-on-miss on a read path.
const Session = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    fn open(allocator: std.mem.Allocator, data_dir: []const u8) !Session {
        // Before ANY store/adapter work, so the first adapter INFO line never
        // reaches the piped stderr channel. See `silenceEngineLogs`.
        silenceEngineLogs();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        // `initGlobalStore` (not the bare `getGlobalStore` the GAP-0814 harness
        // uses) is the PRODUCTION open path: it is what installs the
        // hydrate-on-miss hooks and therefore what ACTIVATES the configured
        // resident caps. Without it the bounded caches stay unbounded, hold
        // nothing, and every read goes engine-direct — the arms would never
        // reach the hydrating accessors this ticket is about.
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        // COUNT{} / pattern-comprehension evaluation reaches the executor via
        // injected callbacks; without this the arm panics instead of running.
        execution.initEvaluator();
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn close(self: *Session) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
    }

    fn runQuery(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

/// Collect the first column of every row as an owned, SORTED list of ints, so
/// two results can be compared as multisets independently of arm interleaving.
fn sortedFirstColumnInts(allocator: std.mem.Allocator, result: execution.ExecutionResult) ![]i64 {
    var out = try allocator.alloc(i64, result.rows.len);
    errdefer allocator.free(out);
    for (result.rows, 0..) |row, i| {
        out[i] = switch (row[0]) {
            .Int => |v| @intCast(v),
            else => return error.UnexpectedValueKind,
        };
    }
    std.mem.sort(i64, out, {}, std.sort.asc(i64));
    return out;
}

// ---------------------------------------------------------------------------
// 1. The mechanism, in isolation.
// ---------------------------------------------------------------------------

test "SONNY-1330: a read-only-hydration scope declines a cache miss and mutates nothing" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var s = try Session.open(allocator, data_dir);
    defer s.close();

    const store = graph_store.getGlobalStore(allocator);

    // Baseline: no scope open on this thread.
    try testing.expect(!node_cache.readOnlyHydrationActive());

    const resident_before = store.nodes.residentCount();

    const scope = node_cache.beginReadOnlyHydration();
    try testing.expect(node_cache.readOnlyHydrationActive());
    try testing.expect(!node_cache.hydrationDeclined());

    // A miss inside the scope is REFUSED rather than served by mutating the
    // shard map. This is the whole fix in one assertion.
    try testing.expectError(
        error.CacheHydrationSuppressed,
        store.nodes.getOrHydratePtr(0xDEAD_BEEF_0000_0001),
    );
    // …and the by-value accessor takes the same rule (it inserts too).
    try testing.expectError(
        error.CacheHydrationSuppressed,
        store.edges.getOrHydrate(0xDEAD_BEEF_0000_0002),
    );
    try testing.expect(node_cache.hydrationDeclined());

    const declined = node_cache.endReadOnlyHydration(scope);
    try testing.expect(declined);
    try testing.expect(!node_cache.readOnlyHydrationActive());
    try testing.expect(!node_cache.hydrationDeclined());

    // Nothing was inserted; the cache is exactly as it was.
    try testing.expectEqual(resident_before, store.nodes.residentCount());
}

test "SONNY-1330: a resident hit is still served inside the scope (reads are not blocked)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var s = try Session.open(allocator, data_dir);
    defer s.close();

    const store = graph_store.getGlobalStore(allocator);
    const id = try store.createNodeWithGraph(&[_][]const u8{"S1330Resident"}, "default");

    const scope = node_cache.beginReadOnlyHydration();
    const hit = try store.nodes.getOrHydratePtr(id);
    const declined = node_cache.endReadOnlyHydration(scope);

    try testing.expect(hit != null);
    try testing.expectEqual(id, hit.?.id);
    // A hit is NOT a decline: a fully-resident UNION keeps its parallelism.
    try testing.expect(!declined);
}

test "SONNY-1330: scopes nest and restore, and an inner decline propagates outward" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var s = try Session.open(allocator, data_dir);
    defer s.close();

    const store = graph_store.getGlobalStore(allocator);

    const outer = node_cache.beginReadOnlyHydration();
    {
        // An inner scope that declines NOTHING closes clean and leaves the
        // outer scope open and still undeclined.
        const clean = node_cache.beginReadOnlyHydration();
        try testing.expect(node_cache.readOnlyHydrationActive());
        try testing.expect(!node_cache.endReadOnlyHydration(clean));
        try testing.expect(node_cache.readOnlyHydrationActive());
        try testing.expect(!node_cache.hydrationDeclined());
    }
    {
        // An inner scope that DOES decline reports it to its own owner AND
        // poisons the enclosing scope: an arm cannot launder an unusable
        // nested read by closing the scope it happened in.
        const dirty = node_cache.beginReadOnlyHydration();
        try testing.expectError(
            error.CacheHydrationSuppressed,
            store.nodes.getOrHydratePtr(0xDEAD_BEEF_0000_0003),
        );
        try testing.expect(node_cache.endReadOnlyHydration(dirty));
        try testing.expect(node_cache.readOnlyHydrationActive()); // outer still open
        try testing.expect(node_cache.hydrationDeclined()); // …and now tainted
    }
    try testing.expect(node_cache.endReadOnlyHydration(outer));
    try testing.expect(!node_cache.readOnlyHydrationActive());
    try testing.expect(!node_cache.hydrationDeclined());
}

// ---------------------------------------------------------------------------
// 2. End to end: a UNION whose arms must read NON-RESIDENT nodes AND edges.
//
// Shape matters. A bare `MATCH (n:L) RETURN n.k` arm sources its rows through
// `GraphStore.getNodePtrForScan`, which is ALREADY detached (it boxes an engine
// rebuild instead of inserting) — it never reaches the hydrating accessors, so
// it proves nothing about this fix. A RELATIONSHIP arm does: the adjacency read
// (`outAdjItems` -> `AdjCache.getOrHydratePtr`) and the edge-body read
// (`getEdgeHydrated` -> `EdgeCache.getOrHydrate`) both hydrate-on-miss, and both
// are what `tenant_visibility.edgeTraversable` / `match_operations` call from an
// arm thread.
//
// The build step pins GEODE_{NODE,EDGE,ADJ}_CACHE_ENTRIES=64 (16 shards x 4)
// so the seeded rows genuinely fall out of residency — otherwise the reopen's
// lazy per-graph hydration leaves everything resident and no arm ever misses.
// ---------------------------------------------------------------------------

const PAIRS: usize = 300;

fn seedPairs(s: *Session, comptime from_label: []const u8, comptime to_label: []const u8, base: usize) !void {
    var i: usize = 0;
    while (i < PAIRS) : (i += 1) {
        const aa = s.arena.allocator();
        const q = try std.fmt.allocPrint(
            aa,
            "CREATE (:" ++ from_label ++ " {{k: {d}}})-[:S1330R]->(:" ++ to_label ++ " {{k: {d}}})",
            .{ base + i, base + i },
        );
        var r = try s.runQuery(q);
        r.deinit(aa);
    }
}

// ARM SHAPE — chosen by MEASUREMENT, not by reading the code. Each candidate
// below was run twice against the same COLD store (caps pinned to 64): once
// normally, once wrapped in `beginReadOnlyHydration` (what an arm thread now
// sees). `declines` is `node_cache.declined_hydrations_total`.
//
//   | arm shape                                   | serial | read-only | declines |
//   |---------------------------------------------|--------|-----------|----------|
//   | MATCH (a:A)-[:R]->(b:B) RETURN b.k           | 300    | 300       | 0        |
//   | MATCH (a:A)-[r:R]->(b:B) RETURN r.k          | 300    | 300       | 0        |
//   | RETURN COUNT { (a:A)-[:R]->(b:B) } AS c      | 1 row  | 1 row     | 0        |
//   | MATCH (a:A) RETURN [ (a)-[:R]->(b:B) | b.k ] | 300    | 300       | 300      |
//   | MATCH (a:A) WHERE EXISTS { (a)-[:R]->(:B) }  | 300    | **0**     | 300      |
//
// Only the last row is a usable regression:
//
//   * The plain MATCH/edge-property arms take ZERO declines. Their node reads
//     go through `getNodePtrForScan`, which is ALREADY detached (it boxes an
//     engine rebuild instead of inserting), and their adjacency/edge reads are
//     served without a miss. They would prove nothing.
//   * `COUNT {}` also takes zero declines, but for a worse reason:
//     `graph_algorithms.countPatternMatches` scans `store.nodes.iterator()`,
//     which is RESIDENT-ONLY, so over a cold store it counts 0 on the SERIAL
//     path too. It never reaches a hydrating accessor because it never sees a
//     node. That is a real pre-existing residency-dependent-correctness bug,
//     recorded in the SONNY-1330 report for SONNY-1562; it is NOT this
//     ticket's race and cannot serve as its oracle (0 == 0 proves nothing).
//   * The pattern-comprehension arm declines, but still returns all 300 rows
//     (the refusal only empties the per-row list), so serial and arm output
//     agree by luck and the fallback is not load-bearing.
//   * `WHERE EXISTS { <hop> }` is the honest case: the anchor `MATCH (a:A)`
//     is engine-backed and correct cold, while the per-row `EXISTS{}` gate
//     expands through `graph_algorithms.countPatternMatches` ->
//     `store.nodes.getOrHydratePtr` (`graph_algorithms.zig:304/366`) — the
//     exact accessor the SONNY-1326 note in `tenant_visibility.zig` names as
//     the arm-thread hazard. Refused that hydration, the gate goes false for
//     EVERY row and the arm yields 0 rows instead of 300. Merging that arm
//     output would SILENTLY DROP 300 rows; the fallback is what prevents it.
//
// The cost model keeps these arms parallel for free: `predictArmRowCount`
// bails to null on any arm with a WHERE clause, and null means
// "unknown -> expensive -> parallel".
const ARM_AB = "MATCH (a:S1330A) WHERE EXISTS { (a)-[:S1330R]->(:S1330B) } RETURN a.k";
const ARM_CD = "MATCH (c:S1330C) WHERE EXISTS { (c)-[:S1330R]->(:S1330D) } RETURN c.k";

test "SONNY-1330: UNION whose arms must hydrate equals the serial path, and the fallback fires" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    // --- Phase 1: seed and checkpoint, then CLOSE the store. ---------------
    {
        var s = try Session.open(allocator, data_dir);
        defer s.close();
        try seedPairs(&s, "S1330A", "S1330B", 0);
        try seedPairs(&s, "S1330C", "S1330D", PAIRS);
    }

    // --- Phase 2: reopen COLD and take the SERIAL per-arm baseline. --------
    var expected: []i64 = undefined;
    {
        var s = try Session.open(allocator, data_dir);
        defer s.close();
        const aa = s.arena.allocator();

        var ra = try s.runQuery(ARM_AB);
        defer ra.deinit(aa);
        var rb = try s.runQuery(ARM_CD);
        defer rb.deinit(aa);

        const ka = try sortedFirstColumnInts(allocator, ra);
        defer allocator.free(ka);
        const kb = try sortedFirstColumnInts(allocator, rb);
        defer allocator.free(kb);

        // The SERIAL path hydrates freely, so every anchor's EXISTS{} gate
        // sees its non-resident endpoint and passes: all PAIRS rows survive.
        // (An arm refused that hydration yields ZERO rows — see the table
        // above. That gap is what the fallback has to close.)
        try testing.expectEqual(PAIRS, ka.len);
        try testing.expectEqual(PAIRS, kb.len);

        expected = try allocator.alloc(i64, ka.len + kb.len);
        @memcpy(expected[0..ka.len], ka);
        @memcpy(expected[ka.len..], kb);
        std.mem.sort(i64, expected, {}, std.sort.asc(i64));
    }
    defer allocator.free(expected);

    // --- Phase 3: reopen COLD again and run the same thing as ONE UNION. ---
    {
        var s = try Session.open(allocator, data_dir);
        defer s.close();
        const aa = s.arena.allocator();

        const invocations_before = execution.parallelUnionInvocations();
        const fallbacks_before = execution.parallelUnionSerialFallbacks();

        // HARNESS PRECONDITION, asserted rather than hoped for. The whole
        // regression is meaningless if the caches are unbounded (nothing is
        // ever non-resident, so no arm ever misses and the test goes green for
        // the wrong reason). Pin the caps the build step sets via
        // GEODE_{NODE,EDGE,ADJ}_CACHE_ENTRIES: if that wiring is ever dropped,
        // this fails loudly instead of silently passing.
        {
            const st = graph_store.getGlobalStore(allocator);
            try testing.expectEqual(@as(usize, 64), st.nodes.effectiveCap());
            try testing.expectEqual(@as(usize, 64), st.edges.effectiveCap());
            try testing.expectEqual(@as(usize, 64), st.outgoing_edges.effectiveCap());
            // …and the reopen really is COLD: far fewer resident rows than the
            // 2 * PAIRS anchors the arms are about to read.
            try testing.expect(st.nodes.residentCount() < PAIRS);
        }

        const declines_before = node_cache.declined_hydrations_total.load(.monotonic);

        var r = try s.runQuery(ARM_AB ++ " UNION ALL " ++ ARM_CD);
        defer r.deinit(aa);

        const declines = node_cache.declined_hydrations_total.load(.monotonic) - declines_before;
        const invocations = execution.parallelUnionInvocations() - invocations_before;
        const fallbacks = execution.parallelUnionSerialFallbacks() - fallbacks_before;

        // The parallel path was entered (the arms are hop patterns, so the
        // GAP-0814 cost model cannot predict them and keeps them parallel)…
        try testing.expect(invocations >= 1);
        // …and, because the store is cold, at least one arm was refused its
        // hydrate-on-miss and the whole UNION re-ran serially. This is the
        // assertion that FAILS on the pre-fix tree, where the arm hydrated
        // into the shared cache instead.
        try testing.expect(fallbacks >= 1);
        // The fallback fired for the RIGHT reason: an arm was actually refused
        // a cache-mutating hydration, not merely errored out.
        try testing.expect(declines >= 1);

        const got = try sortedFirstColumnInts(allocator, r);
        defer allocator.free(got);

        // THE correctness assertion: whichever path ran, the rows are the
        // serial path's rows.
        try testing.expectEqualSlices(i64, expected, got);
    }
}

// ---------------------------------------------------------------------------
// 2b. The serial re-run makes WRITE-FREEDOM a correctness precondition, and a
//     write can hide inside a CTE body.
//
// `unionArmsAreParallelEligible` -> `queryIsReadOnly` originally inspected only
// an arm's OWN clauses plus its `next_query` chain. It did not look at
// `cte_list`, and a CTE body is a FULL `*Query`
// (`ast.CommonTableExpression.CTEBody.simple`, and both halves of
// `.recursive`), parsed by `parser.parseQueryForCTE` — which delegates
// straight to `parseQuery` — and executed by
// `query_execution.executeCTE` -> `executeQueryWithContext`. So
//
//   WITH w AS (MATCH (n:T) SET n.c = n.c + 1 RETURN n) MATCH … UNION ALL …
//
// passed the read-only gate with a live SET on the arm.
//
// It was worse than merely eligible. `predictArmRowCount` bails to `null` the
// instant it sees `cte_list`, and the cost model reads `null` as
// "unknown -> expensive -> KEEP PARALLEL" — so this shape was the parallel
// path's PREFERRED input. One declined hydration anywhere in the UNION then
// discarded every arm result and re-ran the whole thing serially, applying the
// SET a SECOND time.
// ---------------------------------------------------------------------------

const CTE_ROWS: usize = 5;

fn seedCounters(s: *Session, comptime label: []const u8) !void {
    var i: usize = 0;
    while (i < CTE_ROWS) : (i += 1) {
        const aa = s.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "CREATE (:" ++ label ++ " {{k: {d}, c: 0}})", .{i});
        var r = try s.runQuery(q);
        r.deinit(aa);
    }
}

/// How many `label` nodes currently have `c == want`.
fn countersEqualTo(s: *Session, comptime label: []const u8, comptime want: []const u8) !usize {
    const aa = s.arena.allocator();
    var r = try s.runQuery("MATCH (n:" ++ label ++ ") WHERE n.c = " ++ want ++ " RETURN n.k");
    defer r.deinit(aa);
    return r.rows.len;
}

test "SONNY-1330: a UNION arm whose CTE body WRITES is never run in parallel, and is refused before it writes (SONNY-3182)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var s = try Session.open(allocator, data_dir);
    defer s.close();

    try seedCounters(&s, "S1330CteArm");
    try seedCounters(&s, "S1330CteOther");

    const invocations_before = execution.parallelUnionInvocations();

    // SONNY-3182: a write inside a CTE body or an IN / NOT IN subquery is
    // refused (0A000) before anything runs; nothing is written.
    try testing.expectError(error.WriteClauseNotApplied, s.runQuery(
        "WITH w AS (MATCH (n:S1330CteArm) SET n.c = n.c + 1 RETURN n)" ++
            " MATCH (m:S1330CteArm) RETURN m.k" ++
            " UNION ALL MATCH (o:S1330CteOther) RETURN o.k",
    ));

    // THE gate assertion, and the one that is RED on the pre-fix tree: the
    // parallel fork-join was never even ATTEMPTED for this UNION, because
    // `queryIsReadOnly` now descends into `cte_list` and finds the SET.
    //
    // NOT VACUOUS — this really is a UNION that the pre-fix gate admitted, and
    // every step of that is pinned by the parser/eligibility source rather than
    // assumed:
    //   * `parser.parseProgram` recognises the leading `WITH w AS (…)` as a CTE
    //     list, then `parseStatement` -> `handleQueryResult` folds the trailing
    //     `UNION ALL` into an `ast.Union`, and the `.Union` branch attaches the
    //     CTE list to `union_query.first` — so arm 0 carries `cte_list`.
    //   * `unionArmsAreParallelEligible` clears every earlier gate for this
    //     shape: one `union_op` tail, no `create_pattern`/`merge_statement` on
    //     arm 0, and no enclosing read-only scope.
    //   * pre-fix `queryIsReadOnly` then returned true (the arm's OWN
    //     `set_clauses` are empty; the SET lives one level down in the CTE
    //     body), and `predictArmRowCount` returned null on `cte_list`, which
    //     the cost model reads as "expensive -> parallel".
    // Since SONNY-3182 the write-shape validator refuses the statement
    // before any arm runs, so the counters must all still read 0.
    try testing.expectEqual(
        @as(u64, 0),
        execution.parallelUnionInvocations() - invocations_before,
    );

    // …and the consequence that actually matters to a client: nothing of the
    // refused statement was written (no 1s, and no 2s from a discarded
    // parallel attempt followed by a serial re-run).
    try testing.expectEqual(CTE_ROWS, try countersEqualTo(&s, "S1330CteArm", "0"));
    try testing.expectEqual(@as(usize, 0), try countersEqualTo(&s, "S1330CteArm", "2"));
    // The read-only sibling arm is untouched, so a stray write cannot be
    // mistaken for the CTE's.
    try testing.expectEqual(CTE_ROWS, try countersEqualTo(&s, "S1330CteOther", "0"));
}

// ---------------------------------------------------------------------------
// 2c. …and a write can hide inside an EXPRESSION, not just a clause or a CTE.
//
// `queryIsReadOnly` inspected only CLAUSE fields. But `ast.Expr` has two
// variants that each carry a FULL `*Query`:
//
//   InSubquery    { value: *Expr, subquery: *Query }   (ast.zig)
//   NotInSubquery { value: *Expr, subquery: *Query }
//
// Both are built by the `IN (` / `NOT IN (` branches of the parser's
// comparison tail (`parser.zig`), which call the ordinary `parseQuery` — so
// the subquery can carry `set_clauses`, `create_pattern`, `merge_statement`,
// `delete_items`, `remove_clauses`, `call_clause`, `cte_list` and
// `next_query` of its own. `eval.evalExpr`'s `.InSubquery` arm runs it via
// `getExecutionCallbacks().executeQueryWithEnv` ->
// `evaluator_adapter.executeQueryWithContext`, i.e. the real executor, writes
// included. Hence
//
//   MATCH (n:T) WHERE n.k IN (MATCH (m:U) SET m.c = m.c + 1 RETURN m.k)
//     RETURN n.k  UNION ALL  MATCH (o:V) RETURN o.k
//
// passed the gate with a LIVE SET on the arm — the same defect class as the
// `cte_list` hole above, and just as parallel-PREFERRED: `predictArmRowCount`
// bails to `null` the instant it sees `where_clause`, and the cost model reads
// `null` as "unknown -> expensive -> KEEP PARALLEL". One declined hydration
// then discarded every arm and re-ran the UNION serially, applying the SET a
// SECOND time.
//
// RED against 1a2e2e18 by construction (reasoned from source, not assumed):
//   * `unionArmsAreParallelEligible` clears every earlier gate — one
//     `union_op` tail, no `create_pattern` / `merge_statement` on arm 0, no
//     enclosing read-only scope.
//   * pre-fix `queryIsReadOnly(arm0)` returned TRUE: the arm's own
//     `set_clauses` / `remove_clauses` / `delete_items` are EMPTY and its
//     `cte_list` is null — the SET lives inside an expression, which the
//     pre-fix walk never opened.
//   * `predictArmRowCount(arm0)` returned null (`where_clause != null`, and
//     for the RETURN-expression variant below the same `where_clause` bail),
//     so `all_small` is false and the UNION stays on the parallel path.
// Therefore `parallelUnionInvocations()` MOVED on 1a2e2e18 and the
// `expectEqual(0, …)` below FAILED there; post-fix the gate rejects the arm
// before any fork-join.
//
// Each anchor label holds exactly ONE node, so the predicate — and with it the
// subquery — is evaluated exactly once per serial execution of the UNION. A
// discarded parallel attempt followed by a serial re-run would therefore leave
// every counter at c == 2 rather than c == 1.
// ---------------------------------------------------------------------------

/// Create the single anchor row whose WHERE / RETURN expression hosts the
/// mutating subquery.
fn seedSingleAnchor(s: *Session, comptime label: []const u8) !void {
    const aa = s.arena.allocator();
    var r = try s.runQuery("CREATE (:" ++ label ++ " {k: 0})");
    r.deinit(aa);
}

test "SONNY-1330: a UNION arm whose IN/NOT IN subquery WRITES is never run in parallel, and is refused before it writes (SONNY-3182)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var s = try Session.open(allocator, data_dir);
    defer s.close();

    // Three independent (anchor, mutation target, sibling arm) triples so the
    // three shapes cannot contaminate each other's counters.
    try seedSingleAnchor(&s, "S1330InAnchor");
    try seedCounters(&s, "S1330InSub");
    try seedCounters(&s, "S1330InOther");

    try seedSingleAnchor(&s, "S1330NotInAnchor");
    try seedCounters(&s, "S1330NotInSub");
    try seedCounters(&s, "S1330NotInOther");

    try seedSingleAnchor(&s, "S1330RetAnchor");
    try seedCounters(&s, "S1330RetSub");
    try seedCounters(&s, "S1330RetOther");

    // --- (a) the mutating subquery sits in WHERE, behind IN ----------------
    {
        const invocations_before = execution.parallelUnionInvocations();
        // SONNY-3182: a write inside a CTE body or an IN / NOT IN subquery is
        // refused (0A000) before anything runs; nothing is written.
        try testing.expectError(error.WriteClauseNotApplied, s.runQuery(
            "MATCH (a:S1330InAnchor)" ++
                " WHERE a.k IN (MATCH (m:S1330InSub) SET m.c = m.c + 1 RETURN m.k)" ++
                " RETURN a.k" ++
                " UNION ALL MATCH (o:S1330InOther) RETURN o.k",
        ));

        try testing.expectEqual(
            @as(u64, 0),
            execution.parallelUnionInvocations() - invocations_before,
        );
        // Refused before it ran (SONNY-3182): nothing written…
        try testing.expectEqual(CTE_ROWS, try countersEqualTo(&s, "S1330InSub", "0"));
        // …and nothing reached 2 (a discarded parallel attempt plus a serial
        // re-run).
        try testing.expectEqual(@as(usize, 0), try countersEqualTo(&s, "S1330InSub", "2"));
        // The read-only sibling arm is untouched.
        try testing.expectEqual(CTE_ROWS, try countersEqualTo(&s, "S1330InOther", "0"));
    }

    // --- (b) the NOT IN variant -------------------------------------------
    {
        const invocations_before = execution.parallelUnionInvocations();
        // SONNY-3182: a write inside a CTE body or an IN / NOT IN subquery is
        // refused (0A000) before anything runs; nothing is written.
        try testing.expectError(error.WriteClauseNotApplied, s.runQuery(
            "MATCH (a:S1330NotInAnchor)" ++
                " WHERE a.k NOT IN (MATCH (m:S1330NotInSub) SET m.c = m.c + 1 RETURN m.k)" ++
                " RETURN a.k" ++
                " UNION ALL MATCH (o:S1330NotInOther) RETURN o.k",
        ));

        try testing.expectEqual(
            @as(u64, 0),
            execution.parallelUnionInvocations() - invocations_before,
        );
        try testing.expectEqual(CTE_ROWS, try countersEqualTo(&s, "S1330NotInSub", "0"));
        try testing.expectEqual(@as(usize, 0), try countersEqualTo(&s, "S1330NotInSub", "2"));
        try testing.expectEqual(CTE_ROWS, try countersEqualTo(&s, "S1330NotInOther", "0"));
    }

    // --- (c) the mutating subquery sits in a RETURN expression -------------
    // Not a WHERE predicate this time: `ret.items[].expr` is an expression
    // carrier too, and the pre-fix walk did not look at it either. The
    // `a.k >= 0` WHERE is there only to make `predictArmRowCount` bail, so the
    // shape stays on the parallel path the way the other two do.
    {
        const invocations_before = execution.parallelUnionInvocations();
        // SONNY-3182: a write inside a CTE body or an IN / NOT IN subquery is
        // refused (0A000) before anything runs; nothing is written.
        try testing.expectError(error.WriteClauseNotApplied, s.runQuery(
            "MATCH (a:S1330RetAnchor) WHERE a.k >= 0" ++
                " RETURN a.k IN (MATCH (m:S1330RetSub) SET m.c = m.c + 1 RETURN m.k) AS hit" ++
                " UNION ALL MATCH (o:S1330RetOther) RETURN o.k",
        ));

        try testing.expectEqual(
            @as(u64, 0),
            execution.parallelUnionInvocations() - invocations_before,
        );
        try testing.expectEqual(CTE_ROWS, try countersEqualTo(&s, "S1330RetSub", "0"));
        try testing.expectEqual(@as(usize, 0), try countersEqualTo(&s, "S1330RetSub", "2"));
        try testing.expectEqual(CTE_ROWS, try countersEqualTo(&s, "S1330RetOther", "0"));
    }
}

// ---------------------------------------------------------------------------
// 3. Concurrency: hammer the fork-join on a cold store. Compiled with
//    -fsanitize-thread by `zig build test-sonny1330-parallel-union-tsan`,
//    where an arm that mutated a shard map under a sibling's live pointer is
//    reported as a data race instead of being merely wrong.
// ---------------------------------------------------------------------------

test "SONNY-1330: repeated cold three-arm UNION is stable and race-free" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    {
        var s = try Session.open(allocator, data_dir);
        defer s.close();
        try seedPairs(&s, "S1330X", "S1330P", 0);
        try seedPairs(&s, "S1330Y", "S1330Q", PAIRS);
        try seedPairs(&s, "S1330Z", "S1330W", 2 * PAIRS);
    }

    const query =
        "MATCH (x:S1330X)-[:S1330R]->(p:S1330P) RETURN p.k" ++
        " UNION ALL MATCH (y:S1330Y)-[:S1330R]->(q:S1330Q) RETURN q.k" ++
        " UNION ALL MATCH (z:S1330Z)-[:S1330R]->(w:S1330W) RETURN w.k";

    var round: usize = 0;
    while (round < 3) : (round += 1) {
        var s = try Session.open(allocator, data_dir);
        defer s.close();
        const aa = s.arena.allocator();
        var r = try s.runQuery(query);
        defer r.deinit(aa);
        try testing.expectEqual(3 * PAIRS, r.rows.len);

        const got = try sortedFirstColumnInts(allocator, r);
        defer allocator.free(got);
        // Dense 0..3*PAIRS-1 by construction: a row dropped or duplicated by a
        // half-hydrated arm shows up here immediately.
        for (got, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(i)), v);
    }
}
