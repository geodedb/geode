// geode#875 — the vector index is rebuilt from scratch on every single write,
// the brute-force knn re-scans once per candidate row, and the backfill reports
// nothing about what it indexed.
//
// VERIFIED READ-ONLY against this branch before the fix:
//
//   RC-1 (per-write full rebuild): every node write to an indexed (label, prop)
//     flows through property_mutation.zig:385 -> rebuildAdvancedIndexesForProperty
//     -> IndexManager.rebuildAdvancedIndex (src/index/index_manager.zig
//     :1862-1915), which DROPS the HNSW index, recreates it EMPTY, and re-scans
//     every node. There is no incremental insert. Inserting M nodes into a
//     K-node index is O((K+M)·M) — 133 s for a SINGLE write at 24 k. The
//     observable seam is `IndexManager.statistics.rebuild_count`: a full rebuild
//     bumps it once PER WRITE.
//
//   RC-6 (per-row knn re-eval): `knn(...)` inside a WHERE/WITH is a row
//     expression, so `MATCH (n:V) WHERE id(n) IN knn('emb', q, k, 'l2')` calls
//     the O(n) brute-force `scanVectorKnn` (src/eval.zig:2461) ONCE PER CANDIDATE
//     ROW — O(n²) overall, fatal at 2 000 rows. The subexpression is
//     row-invariant (its args reference no bound variable) and must be hoisted
//     and evaluated ONCE. `containsVariableReference`
//     (src/execution/match_operations.zig:4595) is the row-invariance predicate
//     the fix uses; the observable seam is a scan-invocation counter on
//     scanVectorKnn.
//
//   RC-5 (swallowed backfill): the backfill (`populateAdvancedIndex`,
//     index_manager.zig:1998-2019) returns void and reports no indexed count,
//     and its two call sites swallow errors
//     (`manager.rebuildAdvancedIndex(store, k.*) catch {};` —
//     quic_connection_handler.zig:428, grpc_server.zig:194). A backfill that
//     indexes zero rows (see the RC-2 cold-cache defect pinned in
//     tests/test_advanced_index_restart.zig) is indistinguishable from a healthy
//     one. The fix surfaces a count, mirroring `geode.fts.rebuild`'s
//     `nodes_indexed` YIELD.
//
// DETERMINISM: RC-1 is pinned on the exact `rebuild_count` counter (no timing).
// RC-6 and RC-5 need FIXER-PROVIDED instrumentation seams that do not exist yet,
// so they are written against the DESIRED seam with the repo's comptime
// `@hasDecl` guard-sentinel pattern (see tests/test_raft_rebuild_probation.zig):
// a clean named red now, the real behavioural assertion once the seam lands.
//
// CANARY: REQ=REQ-GEODE-875-INCREMENTAL-INSERT; FEATURE="VectorIndex"; ASPECT=WriteDoesNotFullRebuild; STATUS=TESTED; TEST=tests/test_geode875_incremental_index.zig; OWNER=index; UPDATED=2026-08-31
// CANARY: REQ=REQ-GEODE-875-KNN-HOISTED; FEATURE="VectorKnn"; ASPECT=RowInvariantKnnEvaluatedOnce; STATUS=TESTED; TEST=tests/test_geode875_incremental_index.zig; OWNER=eval; UPDATED=2026-08-31
// CANARY: REQ=REQ-GEODE-875-BACKFILL-REPORTS-COUNT; FEATURE="VectorIndex"; ASPECT=BackfillReturnsIndexedCount; STATUS=TESTED; TEST=tests/test_geode875_incremental_index.zig; OWNER=index; UPDATED=2026-08-31

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const eval = geode.eval;
const Value = geode.value_types.Value;

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

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn run(self: *Harness, query: []const u8) !void {
        _ = try self.exec(query);
    }

    pub fn nodeId(self: *Harness, query: []const u8) !i64 {
        const res = try self.exec(query);
        if (res.rows.len == 0 or res.rows[0].len == 0) return error.NoNodeId;
        return switch (res.rows[0][0]) {
            .Int => |i| i,
            .BigInt => |i| i,
            else => error.ExpectedNodeId,
        };
    }
};

fn mgr() *index_manager.IndexManager {
    return index_manager.getGlobalIndexManager().?;
}

fn knnIds(res: execution.ExecutionResult) ![]Value {
    if (res.rows.len == 0 or res.rows[0].len == 0) return &.{};
    return switch (res.rows[0][0]) {
        .List => |items| items,
        else => error.ExpectedKnnList,
    };
}

fn idsContain(ids: []Value, want: i64) bool {
    for (ids) |v| {
        const got: i64 = switch (v) {
            .Int => |i| i,
            .BigInt => |i| i,
            else => continue,
        };
        if (got == want) return true;
    }
    return false;
}

/// Seed `n` :IncV nodes emb = [i, 0] (all resident — no restart in this file).
fn seed(h: *Harness, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var buf: [128]u8 = undefined;
        try h.run(try std.fmt.bufPrint(
            &buf,
            "CREATE (:IncV {{i: {d}, emb: vectorf32([{d}.0, 0.0])}})",
            .{ i, i },
        ));
    }
}

// ===========================================================================
// RC-1 — a single node write into an existing index is an INCREMENTAL insert,
// NOT a full drop+rebuild. Pinned on the exact rebuild_count counter.
// ===========================================================================
test "geode#875 RC-1: writes into an indexed label do not each trigger a full index rebuild" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH inc_rebuild");
    try h.run("USE GRAPH inc_rebuild");

    try seed(&h, 10);
    try h.run("CREATE INDEX inc_idx ON IncV (emb) USING vector WITH (metric = 'l2')");

    // Snapshot AFTER the DDL build so the CREATE INDEX's own rebuild is excluded.
    const rebuilds_before = mgr().statistics.rebuild_count;

    // Five additional single-node writes into the SAME indexed (label, prop).
    const extra = 5;
    var j: usize = 10;
    while (j < 10 + extra) : (j += 1) {
        var buf: [128]u8 = undefined;
        try h.run(try std.fmt.bufPrint(
            &buf,
            "CREATE (:IncV {{i: {d}, emb: vectorf32([{d}.0, 0.0])}})",
            .{ j, j },
        ));
    }

    const rebuilds_after = mgr().statistics.rebuild_count;
    const delta = rebuilds_after - rebuilds_before;

    // KEY ASSERTION. RED: rebuildAdvancedIndex fires once PER write -> delta == 5
    // (a full O(K+M) drop+recreate+re-scan each time). GREEN: an incremental
    // insert path takes each write -> delta == 0.
    if (delta != 0) {
        std.debug.print(
            "\n[geode#875 RC-1] {d} single-node writes triggered {d} FULL index rebuild(s) — each write drops and re-scans the whole index (O(N^2) ingest) instead of an incremental insert\n",
            .{ extra, delta },
        );
        return error.WriteTriggeredFullIndexRebuild;
    }

    // Necessary-but-not-sufficient: the newly written nodes are knn-findable.
    const want = try h.nodeId("MATCH (n:IncV {i: 12}) RETURN id(n)");
    const res = try h.exec("RETURN knn('emb', vectorf32([12.0, 0.0]), 1, 'l2') AS ids");
    try testing.expect(idsContain(try knnIds(res), want));
}

// ===========================================================================
// RC-6 — a row-invariant knn() in WHERE/WITH is evaluated ONCE, not per row.
//
// Needs a fixer-provided scan-invocation counter on scanVectorKnn. Desired seam:
//   eval.resetKnnScanInvocations() void
//   eval.knnScanInvocationCount() u64
// ===========================================================================
test "geode#875 RC-6: a row-invariant knn() in WHERE is evaluated once, not once per candidate row" {
    if (comptime @hasDecl(eval, "knnScanInvocationCount") and @hasDecl(eval, "resetKnnScanInvocations")) {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();

        try h.run("CREATE GRAPH knn_hoist");
        try h.run("USE GRAPH knn_hoist");
        try seed(&h, 50);

        eval.resetKnnScanInvocations();

        // The knn(...) subexpression references NO bound variable, so it is
        // constant across the 50 candidate rows and must be hoisted + evaluated
        // exactly once. RED (pre-hoist): scanVectorKnn runs per row (50 times).
        var res = try h.exec("MATCH (n:IncV) WHERE id(n) IN knn('emb', vectorf32([1.0, 0.0]), 5, 'l2') RETURN id(n) AS id");
        _ = &res;

        const invocations = eval.knnScanInvocationCount();
        if (invocations != 1) {
            std.debug.print(
                "\n[geode#875 RC-6] scanVectorKnn ran {d} time(s) for a single row-invariant knn() over 50 rows — expected exactly 1 (O(N^2) per-row re-evaluation)\n",
                .{invocations},
            );
            return error.RowInvariantKnnReEvaluatedPerRow;
        }
    } else {
        // FIXER SEAM REQUIRED: add a test-only scan-invocation counter to
        // src/eval.zig (incremented at the top of scanVectorKnn) exposed as
        // eval.resetKnnScanInvocations()/eval.knnScanInvocationCount(), so the
        // per-row-vs-once contract is deterministic without wall-clock timing.
        return error.KnnScanInvocationCounterSeamMissing;
    }
}

// ===========================================================================
// RC-5 — the backfill REPORTS how many nodes it indexed (it must not silently
// index zero). Needs a fixer-provided counted rebuild seam. Desired seam:
//   IndexManager.rebuildAdvancedIndexCounted(store, index_name) !usize
// returning the number of ENTITIES inserted by the backfill.
// ===========================================================================
test "geode#875 RC-5: the backfill reports the number of nodes it indexed" {
    if (comptime @hasDecl(index_manager.IndexManager, "rebuildAdvancedIndexCounted")) {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();

        try h.run("CREATE GRAPH backfill_count");
        try h.run("USE GRAPH backfill_count");
        try seed(&h, 12);
        try h.run("CREATE INDEX bc_idx ON IncV (emb) USING vector WITH (metric = 'l2')");

        const store = graph_store.getGlobalStore(testing.allocator);
        // RED (pre-seam): does not compile-exist; GREEN: a fresh backfill of the
        // 12-node index reports exactly 12 indexed entities, so a call site can
        // no longer swallow a zero-indexed backfill as success.
        const indexed = try mgr().rebuildAdvancedIndexCounted(store, "bc_idx");
        if (indexed != 12) {
            std.debug.print(
                "\n[geode#875 RC-5] backfill reported {d} indexed nodes, expected 12\n",
                .{indexed},
            );
            return error.BackfillReportedWrongCount;
        }
    } else {
        // FIXER SEAM REQUIRED: give the backfill a counted variant
        // (populateAdvancedIndex returning usize, surfaced as
        // IndexManager.rebuildAdvancedIndexCounted) so CREATE INDEX / the
        // quic+grpc rebuild call sites can YIELD/log a real nodes_indexed count
        // instead of `catch {}`-swallowing a silent zero-indexed backfill.
        return error.BackfillCountReportingSeamMissing;
    }
}
