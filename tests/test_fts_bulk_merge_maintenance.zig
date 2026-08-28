// CANARY: REQ=REQ-FTS-BULK-MERGE-LIVE-001; FEATURE="FullText"; ASPECT=BulkMergeMaintenanceContract; STATUS=TESTED; TEST=tests/test_fts_bulk_merge_maintenance.zig; OWNER=fts; UPDATED=2026-08-28
//
// Spec geode-vectorization-and-reranking + A4b §6: the bulk-MERGE fast path
// (src/server/quic_connection_handler.zig executeBulkSimpleMerge /
// executeBatchSimpleMerge) runs ON the connection thread, so it is safe (and
// now required) to run live FTS maintenance right after the apply completes
// and all locks are released — closing the documented blind spot in
// fts_index_ops.zig:267-271 ("callers on worker threads ... reindex post-bulk
// on the connection thread instead").
//
// This unit test drives the REAL store + REAL adapter + REAL fts_index_ops
// primitives (no mocks), mirroring the harness in tests/test_fts_rebuild.zig.
// It pins the CONTRACT the handler hook relies on:
//   1. adapter.bulkMergeNodeWithReservedId (the bulk fast-path writer) alone
//      does NOT make a node searchable — it bypasses maintainFulltextOnWrite
//      by design (single-writer-thread contract; see the doc comment on
//      maintainFulltextOnWrite).
//   2. Calling fts_index_ops.maintainFulltextOnWrite(..., .create) right
//      after the bulk-merge write — exactly the sequence the handler hook
//      now performs — makes the node searchable immediately, no rebuild
//      required.
//
// The real end-to-end proof (driving the actual QUIC wire path through
// executeBulkSimpleMerge) lives in the harness spec:
// ../geode-test-harness/geodetestlab-cli/specs/fts_bulk_merge_visibility.yml

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

/// Harness mirrors tests/test_fts_rebuild.zig / tests/test_fts_e2e.zig.
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
};

test "bulk-merged nodes become searchable without rebuild (maintenance contract)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    // 1. Bootstrap the fulltext index on an empty label (no nodes exist yet).
    try execution.fts_index_ops.createFulltextIndex(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        "bulk_doc_idx",
        "BulkDoc",
        &.{"body"},
    );

    const adapter = graph_store.getGlobalAdapter() orelse return error.TestUnexpectedResult;
    const store = graph_store.getGlobalStore(h.allocator);

    // 2. Simulate the handler's post-apply hook: bulkMergeNode via the
    //    reserved-id writer (the bulk fast-path primitive), THEN call
    //    maintainFulltextOnWrite — the call the fix adds on the connection
    //    thread, right after the apply and lock release.
    const reserved1 = store.reserveNodeId();
    const props1 = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "body", .value = .{ .String = "searchable widget text one" } },
    };
    const id1 = (try adapter.bulkMergeNodeWithReservedId(
        graph_store.DEFAULT_GRAPH_NAME,
        reserved1,
        "BulkDoc",
        "doc_key",
        .{ .Int = 1 },
        &props1,
        false, // apply_on_match — fresh insert, irrelevant here
    )).id;
    try execution.fts_index_ops.maintainFulltextOnWrite(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        id1,
        &.{"BulkDoc"},
        .create,
    );

    // 3. Search -> the maintained node is found.
    {
        var res = try h.runQuery("CALL geode.fts.search('bulk_doc_idx', 'widget')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
    }

    // 4. Negative control: a second bulkMergeNode WITHOUT the maintenance
    //    call stays invisible — pins that the primitive alone still skips
    //    FTS, so the handler hook added in this task is load-bearing.
    const reserved2 = store.reserveNodeId();
    const props2 = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "body", .value = .{ .String = "searchable widget text two" } },
    };
    _ = try adapter.bulkMergeNodeWithReservedId(
        graph_store.DEFAULT_GRAPH_NAME,
        reserved2,
        "BulkDoc",
        "doc_key",
        .{ .Int = 2 },
        &props2,
        false,
    );

    {
        var res = try h.runQuery("CALL geode.fts.search('bulk_doc_idx', 'widget')");
        defer res.deinit(aa);
        // Still only the maintained node — the un-maintained second node
        // (id2) is invisible until a maintenance call or rebuild runs.
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expect(res.rows[0][0] == .Int);
        try testing.expectEqual(@as(i64, @intCast(id1)), res.rows[0][0].Int);
    }
}

// CANARY: REQ=REQ-FTS-BULK-MERGE-LIVE-001; FEATURE="FullText"; ASPECT=IdempotentReMergeNoDuplicateAppend; STATUS=TESTED; TEST=tests/test_fts_bulk_merge_maintenance.zig; OWNER=fts; UPDATED=2026-08-28
//
// Review Finding 1 (Task 4, geode-vectorization-and-reranking A4b §6): before
// this fix, TWO shapes of the bulk-MERGE fast path had NO gate on live FTS
// maintenance at all — the multi-property MERGE shape (`merge_kvs.len > 1`,
// handled by `bulkMergeNodeWithReservedIdMultiProp[ForTenant]`) and the
// concurrent-batch shape (`executeBatchSimpleMerge`, which shares the same
// primitives via the group-commit coordinator). Both set
// `fts_should_maintain = true` unconditionally, so an idempotent re-MERGE of
// an already-indexed node (a pure hit, `apply_on_match = false`, no property
// write) re-ran `maintainFulltextOnWrite(..., .create)` — and since the
// fts-storage engine is append-only, that DOUBLE-APPENDED postings for the
// same doc_id on every re-run.
//
// The fix threads a `wrote: bool` signal out of the `bulkMergeNode*`
// primitive family (`StorageAdapter.MergeResult`) so callers can gate
// maintenance on "did this call actually change data" instead of "did this
// call succeed". This test pins that contract directly against the
// multi-property primitive (the shape with no prior gating at all) and
// proves — via a REAL BM25 score comparison against an identically-worded
// reference document indexed exactly once — that the gated re-merge does NOT
// duplicate postings.
test "idempotent multi-prop MERGE re-merge reports wrote=false and does not duplicate FTS postings (review Finding 1)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    try execution.fts_index_ops.createFulltextIndex(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        "idem_doc_idx",
        "IdemDoc",
        &.{"body"},
    );

    const adapter = graph_store.getGlobalAdapter() orelse return error.TestUnexpectedResult;
    const store = graph_store.getGlobalStore(h.allocator);

    const body_text = "duplicate append canary text alpha";

    // Node A: fresh multi-prop MERGE create (2 merge props — the shape that
    // had NO Phase-1 read probe / gating before this fix). `wrote` must be
    // true on the fresh insert; maintain it once, exactly like the fixed
    // handler does.
    const merge_props_a = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "tenant_key", .value = .{ .Int = 1 } },
        .{ .key = "region_key", .value = .{ .Int = 100 } },
    };
    const on_create_a = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "body", .value = .{ .String = body_text } },
    };
    const create_res = try adapter.bulkMergeNodeWithReservedIdMultiProp(
        graph_store.DEFAULT_GRAPH_NAME,
        store.reserveNodeId(),
        "IdemDoc",
        &merge_props_a,
        &on_create_a,
        false, // apply_on_match
    );
    try testing.expect(create_res.wrote);
    try execution.fts_index_ops.maintainFulltextOnWrite(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        create_res.id,
        &.{"IdemDoc"},
        .create,
    );

    // Idempotent re-MERGE of the SAME composite key against the
    // already-indexed node above: a pure hit, no property write. The
    // primitive MUST report wrote=false (this is the exact assertion that
    // reproduces the bug pre-fix — see RED evidence in the task report).
    const rehit_res = try adapter.bulkMergeNodeWithReservedIdMultiProp(
        graph_store.DEFAULT_GRAPH_NAME,
        store.reserveNodeId(), // fresh reserved id, abandoned on hit (matches production)
        "IdemDoc",
        &merge_props_a,
        &on_create_a,
        false,
    );
    try testing.expectEqual(create_res.id, rehit_res.id);
    try testing.expect(!rehit_res.wrote);

    // Handler-equivalent gate: only maintain when the primitive reports a
    // real write. Mirrors the fixed executeBulkSimpleMerge /
    // executeBatchSimpleMerge call sites in quic_connection_handler.zig.
    if (rehit_res.wrote) {
        try execution.fts_index_ops.maintainFulltextOnWrite(
            h.allocator,
            graph_store.DEFAULT_GRAPH_NAME,
            rehit_res.id,
            &.{"IdemDoc"},
            .create,
        );
    }

    // Reference node B: byte-identical body text, indexed exactly once, never
    // re-merged. Same index, same corpus, so IDF/avgdl context is shared —
    // the only variable is whether A's postings got duplicated.
    const merge_props_b = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "tenant_key", .value = .{ .Int = 2 } },
        .{ .key = "region_key", .value = .{ .Int = 200 } },
    };
    const on_create_b = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = "body", .value = .{ .String = body_text } },
    };
    const b_res = try adapter.bulkMergeNodeWithReservedIdMultiProp(
        graph_store.DEFAULT_GRAPH_NAME,
        store.reserveNodeId(),
        "IdemDoc",
        &merge_props_b,
        &on_create_b,
        false,
    );
    try testing.expect(b_res.wrote);
    try execution.fts_index_ops.maintainFulltextOnWrite(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        b_res.id,
        &.{"IdemDoc"},
        .create,
    );

    // Search: exactly 2 rows (A, B) — not more (a duplicate-append does not
    // fabricate a phantom third doc_id, but it WOULD skew A's term
    // frequency/score relative to B's identical content).
    var res = try h.runQuery("CALL geode.fts.search('idem_doc_idx', 'canary', 10)");
    defer res.deinit(aa);
    try testing.expectEqual(@as(usize, 2), res.rows.len);

    var score_a: ?f64 = null;
    var score_b: ?f64 = null;
    for (res.rows) |row| {
        try testing.expect(row[0] == .Int);
        try testing.expect(row[1] == .Double);
        const node_id = row[0].Int;
        const score = row[1].Double;
        if (node_id == @as(i64, @intCast(create_res.id))) score_a = score;
        if (node_id == @as(i64, @intCast(b_res.id))) score_b = score;
    }
    try testing.expect(score_a != null);
    try testing.expect(score_b != null);
    // The load-bearing assertion: A (gated, correctly-not-re-maintained) and
    // B (indexed exactly once) MUST carry the identical BM25 score. Pre-fix,
    // with the gate absent, A's postings would be double-appended by the
    // second (wrongly unconditional) maintain call and this equality would
    // fail — that failure IS the duplicate-append reproduction.
    try testing.expectEqual(score_b.?, score_a.?);
}
