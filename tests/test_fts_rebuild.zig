// CANARY: REQ=REQ-FTS-REBUILD-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=RebuildBackfill; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=index; UPDATED=2026-08-28
//
// Spec geode-vectorization-and-reranking ingestion invariant: "On deployed
// versions where bulk-MERGE bypasses FTS maintenance, rebuild/backfill the
// affected index before marking ingestion ready." This test drives the real
// store + real adapter + real parser + real executor (no mocks), mirroring
// tests/test_fts_e2e.zig for the store/adapter/index bootstrap.
//
// 1. Bootstrap an empty-label fulltext index via fts_index_ops.createFulltextIndex.
// 2. Insert 3 nodes via the bulk-MERGE fast path (adapter.bulkMergeNodeWithReservedId)
//    directly — the documented blind spot: this write path does NOT run the
//    FTS maintenance hook (see CLAUDE.md "Full-text search bulk-MERGE
//    auto-indexing (Open)").
// 3. CALL geode.fts.search finds nothing — the pre-rebuild blind spot.
// 4. CALL geode.fts.rebuild reindexes from current store contents and reports
//    nodes_indexed == 3.
// 5. CALL geode.fts.search now finds all 3.

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

/// Harness mirrors tests/test_fts_e2e.zig.
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

test "geode.fts.rebuild reindexes nodes missed by out-of-band writes" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    // 1. Bootstrap the fulltext index on an empty label (no nodes exist yet).
    try execution.fts_index_ops.createFulltextIndex(
        h.allocator,
        graph_store.DEFAULT_GRAPH_NAME,
        "rebuild_doc_idx",
        "RebuildDoc",
        &.{"body"},
    );

    // 2. Insert 3 :RebuildDoc nodes via the bulk-MERGE fast-path writer,
    //    BYPASSING the FTS maintenance hook (adapter.bulkMergeNodeWithReservedId
    //    is the documented blind spot — see graph_storage_adapter.zig:4227).
    const adapter = graph_store.getGlobalAdapter() orelse return error.TestUnexpectedResult;
    const store = graph_store.getGlobalStore(h.allocator);
    const bodies = [_][]const u8{
        "widget alpha description",
        "widget beta notes",
        "widget gamma summary",
    };
    for (bodies, 0..) |body, i| {
        const reserved = store.reserveNodeId();
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = "body", .value = .{ .String = body } },
        };
        _ = try adapter.bulkMergeNodeWithReservedId(
            graph_store.DEFAULT_GRAPH_NAME,
            reserved,
            "RebuildDoc",
            "doc_key",
            .{ .Int = @intCast(i) },
            &props,
            false, // apply_on_match — irrelevant, each doc_key is unique
        );
    }

    // 3. Search BEFORE rebuild: the blind spot — 0 rows.
    {
        var res = try h.runQuery("CALL geode.fts.search('rebuild_doc_idx', 'widget')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 0), res.rows.len);
    }

    // 4. Rebuild: one row, columns [index, nodes_indexed], nodes_indexed == 3.
    {
        var res = try h.runQuery("CALL geode.fts.rebuild('rebuild_doc_idx')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
        try testing.expectEqual(@as(usize, 2), res.columns.len);
        try testing.expectEqualStrings("index", res.columns[0]);
        try testing.expectEqualStrings("nodes_indexed", res.columns[1]);
        try testing.expect(res.rows[0][0] == .Str);
        try testing.expectEqualStrings("rebuild_doc_idx", res.rows[0][0].Str);
        try testing.expect(res.rows[0][1] == .Int);
        try testing.expectEqual(@as(i64, 3), res.rows[0][1].Int);
    }

    // 5. Search again: all 3 nodes are now indexed.
    {
        var res = try h.runQuery("CALL geode.fts.search('rebuild_doc_idx', 'widget')");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 3), res.rows.len);
    }
}

test "geode.fts.rebuild on unknown index errors" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const result = h.runQuery("CALL geode.fts.rebuild('nonexistent_idx')");
    try testing.expectError(error.IndexNotFound, result);
}
