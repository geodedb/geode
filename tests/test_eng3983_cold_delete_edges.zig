// ENG-3983 — relationship DELETE / DETACH DELETE against a COLD (just-reopened)
// store silently deleted NOTHING and orphaned incident edges.
//
// ROOT CAUSE (adapter, not the executor): the engine's per-shard `edge_index` is
// a DEFERRED derived index — after a reopen it stays empty until
// `GraphEngine.ensureDerivedHydrated()` materializes it. The engine's own
// `GraphEngine.getEdge` hydrates before every `edge_index.get`, and geode's
// typed-edge scan (`StorageAdapter.collectEdgePublicIdsByType`) hydrates too —
// which is why a cold `MATCH ()-[r:T]->() RETURN r` resolved fine. But
// `StorageAdapter.getEdgeRecordBySlot` — the ONLY route geode's bounded
// edge-body cache has to rehydrate an evicted/never-resident `Edge` — reached
// into `edge_index` WITHOUT hydrating. Cold, it therefore returned `null` for
// every live edge, so `GraphStore.getEdgePtr` returned null and:
//
//   * `executeDelete`'s relationship loop hit `if (getEdgePtr == null) continue`
//     and deleted NOTHING (the MATCH had resolved the edge id correctly), and
//   * `DETACH DELETE`'s incident-edge loop hit the same guard and left every
//     incident edge behind while the node itself was deleted — DANGLING EDGES,
//     i.e. durable corruption that made a later whole-pattern MATCH fail with
//     `NodeNotFound`.
//
// These tests are restart-shaped: seed through the real executor, tear the
// process-global store down, bring it back up against the SAME data dir (so
// every derived index is genuinely cold), and only THEN mutate.
//
// CANARY: REQ=REQ-DELETE-COLD-STORE-EDGES-001; FEATURE="RelationshipDelete"; ASPECT=ColdStoreResolution; STATUS=TESTED; TEST=tests/test_eng3983_cold_delete_edges.zig; OWNER=execution; UPDATED=2026-08-30

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Same shape as `tests/test_eng3912_dim_pinning.zig`'s harness: a real
/// executor over a real engine-backed data dir, with a `restart` that is the
/// closest a store-level test can get to a server restart.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        // A BOUNDED edge-body cache is the production configuration (a graph with
        // millions of edges cannot pin an `Edge` per edge in RAM), and it is what
        // forces the reads below down the hydrate-on-miss route this bug lives
        // on. With an unbounded cache the reopen leaves every body resident and
        // `getEdgePtr` never consults the adapter at all — the defect is real but
        // invisible. Cap 1 makes at most one body resident, so every DELETE below
        // must rehydrate. Same knob `tests/test_edge_engine_direct_bounded.zig`
        // uses for the same reason.
        if (setenv("GEODE_EDGE_CACHE_ENTRIES", "1", 1) != 0) return error.SetEnvFailed;

        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        // `initGlobalStore` (NOT bare `getGlobalStore`) is the production entry
        // point: it is what installs the node/adjacency/edge hydrate-on-miss
        // hooks and activates their configured caps. A harness that skips it
        // leaves every cache unbounded with no hydrate hook, so the adapter read
        // this bug lives in is never reached.
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
        _ = unsetenv("GEODE_EDGE_CACHE_ENTRIES");
    }

    /// Drop every process-global engine/store/catalog handle and reopen against
    /// the SAME data dir. After this the per-shard `edge_index` (and every other
    /// deferred derived index) is COLD — which is exactly the state ENG-3983 is
    /// about.
    pub fn restart(self: *Harness) !void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        _ = try graph_store.initGlobalStore(self.allocator, self.data_dir);
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        self.session = execution.SessionState.init(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = catalog };
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// `MATCH ()-[r:TYPE]->() RETURN count(r)` through the real executor.
    pub fn typedEdgeCount(self: *Harness, rel_type: []const u8) !i64 {
        const aa = self.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "MATCH ()-[r:{s}]->() RETURN count(r)", .{rel_type});
        const res = try self.exec(q);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        return res.rows[0][0].Int;
    }

    pub fn countRows(self: *Harness, query: []const u8) !usize {
        const res = try self.exec(query);
        return res.rows.len;
    }
};

/// Seed a 5-node path `1->2->3->4->5` of `E83_KNOWS` plus one `E83_LIKES`
/// (a second type, so type-scoped assertions are meaningful).
fn seed(h: *Harness) !void {
    _ = try h.exec(
        "CREATE (:E83_Person {id: 1}), (:E83_Person {id: 2}), (:E83_Person {id: 3}), (:E83_Person {id: 4}), (:E83_Person {id: 5})",
    );
    _ = try h.exec("MATCH (a:E83_Person {id: 1}), (b:E83_Person {id: 2}) CREATE (a)-[:E83_KNOWS]->(b)");
    _ = try h.exec("MATCH (a:E83_Person {id: 2}), (b:E83_Person {id: 3}) CREATE (a)-[:E83_KNOWS]->(b)");
    _ = try h.exec("MATCH (a:E83_Person {id: 3}), (b:E83_Person {id: 4}) CREATE (a)-[:E83_KNOWS]->(b)");
    _ = try h.exec("MATCH (a:E83_Person {id: 4}), (b:E83_Person {id: 5}) CREATE (a)-[:E83_KNOWS]->(b)");
    _ = try h.exec("MATCH (a:E83_Person {id: 1}), (b:E83_Person {id: 3}) CREATE (a)-[:E83_LIKES]->(b)");
}

// ===================================================================
// (1) THE HEADLINE — a cold relationship DELETE must actually delete.
// ===================================================================

test "ENG-3983: cold-store relationship DELETE removes the matched edge (all four bound/unbound shapes)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seed(&h);
    try testing.expectEqual(@as(i64, 4), try h.typedEdgeCount("E83_KNOWS"));
    try testing.expectEqual(@as(i64, 1), try h.typedEdgeCount("E83_LIKES"));

    // COLD: every derived index (incl. the per-shard edge_index) is unmaterialized.
    try h.restart();
    try testing.expectEqual(@as(i64, 4), try h.typedEdgeCount("E83_KNOWS"));

    // Shape (a): BOTH endpoints bound. Pre-fix this returned 00000 and deleted
    // nothing — the MATCH resolved the edge id, but the edge BODY could not be
    // rehydrated so `executeDelete` skipped it.
    _ = try h.exec("MATCH (a:E83_Person {id: 1})-[r:E83_KNOWS]->(b:E83_Person {id: 2}) DELETE r");
    try testing.expectEqual(@as(i64, 3), try h.typedEdgeCount("E83_KNOWS"));

    // Shape (b): LEFT endpoint bound only.
    _ = try h.exec("MATCH (a:E83_Person {id: 2})-[r:E83_KNOWS]->() DELETE r");
    try testing.expectEqual(@as(i64, 2), try h.typedEdgeCount("E83_KNOWS"));

    // Shape (c): RIGHT endpoint bound only.
    _ = try h.exec("MATCH ()-[r:E83_KNOWS]->(b:E83_Person {id: 4}) DELETE r");
    try testing.expectEqual(@as(i64, 1), try h.typedEdgeCount("E83_KNOWS"));

    // Shape (d): FULLY UNBOUND.
    _ = try h.exec("MATCH ()-[r:E83_KNOWS]->() DELETE r");
    try testing.expectEqual(@as(i64, 0), try h.typedEdgeCount("E83_KNOWS"));

    // Type isolation: the other type is untouched by any of the above.
    try testing.expectEqual(@as(i64, 1), try h.typedEdgeCount("E83_LIKES"));
}

// ===================================================================
// (2) An honestly-empty MATCH still deletes nothing and does NOT error.
// ===================================================================

test "ENG-3983: cold-store DELETE over a MATCH that binds no rows stays a successful no-op" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seed(&h);
    try h.restart();

    // No such node id, and no such relationship type: both are legitimately
    // empty matches, NOT unreadable state. They must succeed with zero rows and
    // leave the graph intact (the fail-closed guard must not fire here).
    _ = try h.exec("MATCH (a:E83_Person {id: 999})-[r:E83_KNOWS]->(b:E83_Person {id: 998}) DELETE r");
    _ = try h.exec("MATCH ()-[r:E83_NOSUCH]->() DELETE r");

    try testing.expectEqual(@as(i64, 4), try h.typedEdgeCount("E83_KNOWS"));
    try testing.expectEqual(@as(i64, 1), try h.typedEdgeCount("E83_LIKES"));
}

// ===================================================================
// (3) COLLATERAL — cold DETACH DELETE must not orphan incident edges.
// ===================================================================

test "ENG-3983: cold-store DETACH DELETE removes every incident edge (no dangling edges)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seed(&h);
    try testing.expectEqual(@as(i64, 4), try h.typedEdgeCount("E83_KNOWS"));

    try h.restart();

    // Node 4 has exactly two incident E83_KNOWS edges (3->4 in, 4->5 out).
    // Pre-fix BOTH survived the node's deletion as dangling edges.
    _ = try h.exec("MATCH (n:E83_Person {id: 4}) DETACH DELETE n");
    try testing.expectEqual(@as(i64, 2), try h.typedEdgeCount("E83_KNOWS"));

    // The tooth: with a dangling edge present this whole-pattern MATCH failed
    // with error.NodeNotFound (the edge referenced a node that no longer
    // exists). It must now enumerate exactly the two surviving edges.
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (a:E83_Person)-[r:E83_KNOWS]->(b:E83_Person) RETURN a.id, b.id"));

    // And the corruption must not be durable either: reopen and re-check.
    try h.restart();
    try testing.expectEqual(@as(i64, 2), try h.typedEdgeCount("E83_KNOWS"));
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (a:E83_Person)-[r:E83_KNOWS]->(b:E83_Person) RETURN a.id, b.id"));
}

// ===================================================================
// (4) The adapter-level unit tooth: a cold `getEdgeRecordBySlot` must
//     resolve a live edge without any prior warming read.
// ===================================================================

test "ENG-3983: getEdgePtr rehydrates an edge body on a cold store (adapter edge_index hydration)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try seed(&h);

    // Capture a real, live edge id BEFORE the restart.
    const edge_id = blk: {
        const res = try h.exec("MATCH (a:E83_Person {id: 1})-[r:E83_KNOWS]->(b:E83_Person {id: 2}) RETURN r");
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        break :blk res.rows[0][0].Edge.id;
    };

    try h.restart();

    // One O(1) typed count. It brings the store's per-graph IdMaps up (the
    // public-id -> engine-slot map `getEdgePtr` reverse-maps through) but is
    // served by the exact per-(graph, type) counter, so it makes NO edge body
    // resident — the same discriminator the field repro used.
    try testing.expectEqual(@as(i64, 4), try h.typedEdgeCount("E83_KNOWS"));

    const store = graph_store.getGlobalStore(testing.allocator);
    // The bounded cap really is active (a harness that skipped `initGlobalStore`
    // would report 0 = unbounded here and never exercise hydrate-on-miss).
    try testing.expectEqual(@as(usize, 1), store.edges.effectiveCap());
    // Cap 1: this edge's body cannot be resident alongside the other four.
    try testing.expect(store.edges.residentCount() <= 1);
    store.edges.remove(edge_id);

    // The tooth: the FIRST edge-body read after the reopen must rehydrate from
    // the engine. Pre-fix `getEdgeRecordBySlot` read the unmaterialized
    // per-shard `edge_index` and returned null, so this was null for every
    // live edge — which is precisely what made cold DELETE a silent no-op.
    const edge = store.getEdgePtr(edge_id) orelse return error.ColdEdgeBodyUnresolvable;
    try testing.expectEqualStrings("E83_KNOWS", edge.label);
}
