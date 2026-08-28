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
    const id1 = try adapter.bulkMergeNodeWithReservedId(
        graph_store.DEFAULT_GRAPH_NAME,
        reserved1,
        "BulkDoc",
        "doc_key",
        .{ .Int = 1 },
        &props1,
        false, // apply_on_match — fresh insert, irrelevant here
    );
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
