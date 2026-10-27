// CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig:1; OWNER=index; UPDATED=2026-08-25
//
// ENG-3912 — the GAP-0918 vector-dimension guard had a broken LIFECYCLE.
//
//   (a) POISONING BY A REFUSED STATEMENT. `checkVectorDimensionForWrite`
//       ADOPTED the dimension it was merely validating. It is called from the
//       statement-level atomicity pre-pass, i.e. BEFORE the write is allowed,
//       so a statement that was then refused still pinned its first vector's
//       dimension — permanently, against a property holding ZERO rows, with no
//       statement able to clear it. Verified: a refused mixed-dimension CREATE
//       bricked an empty property.
//
//   (b) DROP INDEX DID NOT CLEAR THE PIN. The pin lived in a registry the DROP
//       path never touched, so the dimension stayed enforced with no index
//       present at all.
//
//       SUPERSEDED BY ENG-3922 (2026-08-29) — see the inverted assertion in
//       the (b) section below. (b)'s premise (the pin belongs to the index)
//       was wrong; the pin belongs to the (graph, label, property) and is
//       seeded from committed data, so DROP INDEX no longer releases it.
//
//   (d) THE GUARD VANISHED ACROSS A RESTART. Registration happened only in DDL
//       execution, never on catalog reload, so after a restart `SHOW INDEXES`
//       still listed the index while mixed dimensions were accepted silently.
//
// (c) in the triage — "scope the registry per graph" — is deliberately NOT
// done; see the cross-graph test at the bottom for why doing so would be a
// data-integrity regression, and what the real fix is.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

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
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
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
    }

    /// Tear the process-global engine state down and bring it back up against
    /// the SAME data dir — the closest a store-level test can get to a server
    /// restart. The catalog reloads from `geode_catalog.dat`, which is exactly
    /// the path ENG-3912(d) is about.
    pub fn restart(self: *Harness) !void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        _ = graph_store.getGlobalStore(self.allocator);
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

    pub fn countRows(self: *Harness, query: []const u8) !usize {
        const res = try self.exec(query);
        return res.rows.len;
    }
};

// One harness for every phase: the hnsw library keeps a worker pool alive
// across index lifetimes, so per-test store re-init (which a real server never
// does) tears global state out from under parked pool threads. Same reason
// tests/test_gap0918_vector_validation.zig uses a single harness.
test "ENG-3912: vector dimension pin lifecycle (refusal, DROP, restart, cross-graph)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // ---- (a) a REFUSED statement must not pin anything ----
    _ = try h.exec("CREATE GRAPH eng3912");
    _ = try h.exec("USE GRAPH eng3912");
    _ = try h.exec("CREATE INDEX e12_poison ON P12A (emb) USING HNSW WITH (metric = 'l2')");

    // Internally inconsistent statement: dim 3 then dim 4 under one index. It
    // must be refused, and — this is the regression — refused ATOMICALLY,
    // leaving no rows AND no dimension pin.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P12A {id: 1, emb: vectorf32('[1.0, 2.0, 3.0]')}), (:P12A {id: 2, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})"),
    );
    try testing.expectEqual(@as(usize, 0), try h.countRows("MATCH (n:P12A) RETURN n"));

    // The property is still UNESTABLISHED, so a perfectly good dim-4 write is
    // accepted. Before the fix this raised VectorDimensionMismatch forever:
    // the refused statement had pinned dim 3 against an empty table.
    _ = try h.exec("CREATE (:P12A {id: 3, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})");
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:P12A) RETURN n"));

    // ---- positive guard: the pin is real once a write COMMITS ----
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P12A {id: 4, emb: vectorf32('[9.0, 9.0, 9.0]')})"),
    );
    // ...and the established dimension still works.
    _ = try h.exec("CREATE (:P12A {id: 5, emb: vectorf32('[4.0, 3.0, 2.0, 1.0]')})");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:P12A) RETURN n"));

    // ---- (b) DROP INDEX and the pin ----
    _ = try h.exec("CREATE INDEX e12_drop ON P12B (emb) USING HNSW WITH (metric = 'l2')");
    _ = try h.exec("CREATE (:P12B {id: 1, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})");
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P12B {id: 2, emb: vectorf32('[1.0, 2.0, 3.0]')})"),
    );

    _ = try h.exec("DROP INDEX e12_drop");

    // POLICY CHANGE — ENG-3922, 2026-08-29. THIS ASSERTION IS INVERTED.
    //
    // ENG-3912(b) originally read the pin as an artifact OF THE INDEX: no
    // index, nothing to keep homogeneous, so DROP INDEX released it and the
    // dim-3 write below was expected to SUCCEED. That premise is wrong, and
    // ENG-3922 is the bug report that shows why: the guard was never really
    // about the index. Mixed dimensions under one (label, property) are a
    // DATA-INTEGRITY defect in their own right — `vector_cosine` over a
    // dim-4/dim-3 pair silently yields NULL and a knn scan silently drops the
    // non-conforming rows, index or no index. ENG-3922(a) is precisely the
    // report that an UNINDEXED property accepts mixed dimensions; releasing
    // the pin on DROP INDEX is the same hole, reached by a different route.
    //
    // Under the ENG-3922 model the registry is re-keyed to
    // (graph, label, property) and seeded lazily from COMMITTED data, so DROP
    // INDEX no longer releases the pin: P12B.emb holds a committed dim-4
    // vector (id: 1), therefore dim-4 is what the property is, and a dim-3
    // write stays refused. To change a property's dimension you delete the
    // rows that establish it — not the index.
    //
    // RED UNTIL THE FIX LANDS. This is intended: `zig build test-eng3912` is
    // expected to fail on this line on the pre-fix tree, exactly like the new
    // tests/test_eng3922_dim_guard.zig. Pre-fix behaviour is that the dim-3
    // write SUCCEEDS (the pin is unregistered by the DROP path).
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P12B {id: 3, emb: vectorf32('[1.0, 2.0, 3.0]')})"),
    );
    // The committed dimension still writes, with no index present.
    _ = try h.exec("CREATE (:P12B {id: 4, emb: vectorf32('[4.0, 3.0, 2.0, 1.0]')})");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:P12B) RETURN n"));

    // ---- (c) cross-graph: the pin is INTENTIONALLY process-wide ----
    //
    // The triage recommended scoping the registry per graph because a write in
    // graph B is refused by a pin established in graph A. That refusal is
    // correct as the engine stands: the HNSW index is a PROCESS-GLOBAL object
    // keyed by index name, and both `populateAdvancedIndex` and the
    // incremental `rebuildAdvancedIndexesForProperty` path select nodes by
    // label+property with NO graph filter — so graph B's vectors land in graph
    // A's index. Scoping the validator alone would therefore re-admit
    // mixed-dimension vectors into one index, which is exactly the corruption
    // GAP-0918 closed. The real fix is to make vector indexes graph-scoped
    // (the way fulltext indexes already are, one engine per graph directory);
    // that is a design change, and the registry should be scoped in the same
    // change. This assertion pins the CURRENT, sound behaviour so the eventual
    // graph-scoping work has to update it deliberately.
    _ = try h.exec("CREATE GRAPH eng3912_other");
    _ = try h.exec("USE GRAPH eng3912_other");
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P12A {id: 100, emb: vectorf32('[5.0, 5.0, 5.0]')})"),
    );
    // The dimension graph A established is still writable from graph B.
    _ = try h.exec("CREATE (:P12A {id: 101, emb: vectorf32('[5.0, 5.0, 5.0, 5.0]')})");

    // ---- (d) restart parity ----
    _ = try h.exec("USE GRAPH eng3912");
    _ = try h.exec("CREATE INDEX e12_restart ON P12C (emb) USING HNSW WITH (metric = 'l2')");
    _ = try h.exec("CREATE (:P12C {id: 1, emb: vectorf32('[1.0, 2.0, 3.0, 4.0]')})");
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P12C {id: 2, emb: vectorf32('[1.0, 2.0, 3.0]')})"),
    );

    try h.restart();
    _ = try h.exec("USE GRAPH eng3912");

    // The index is still in the catalog...
    try testing.expect((try h.countRows("SHOW INDEXES")) > 0);
    // ...and so is the guard. Before the fix the pin was DDL-only process
    // state, so this dim-3 write was silently accepted into a dim-4 index.
    try testing.expectError(
        error.VectorDimensionMismatch,
        h.exec("CREATE (:P12C {id: 3, emb: vectorf32('[7.0, 8.0, 9.0]')})"),
    );
    // The stored dimension still writes.
    _ = try h.exec("CREATE (:P12C {id: 4, emb: vectorf32('[7.0, 8.0, 9.0, 10.0]')})");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:P12C) RETURN n"));
}
