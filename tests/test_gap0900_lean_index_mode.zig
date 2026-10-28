// CANARY: REQ=REQ-PERF-LEAN-INDEX-0900; FEATURE="LeanMergeKeyIndexing"; ASPECT=IndexKeyGate; STATUS=TESTED; TEST=tests/test_gap0900_lean_index_mode.zig; OWNER=performance; UPDATED=2026-06-18
//
// GAP-0900 Layer-3 (Fix 2): opt-in lean indexing. When
// GEODE_INDEX_MERGE_KEYS_ONLY=1 the exact node-property index and the merge
// property index admit ONLY MERGE/declared keys; the other ~19 SET props per
// Taxon node (which are never looked up by key) are skipped, removing ~1 KB of
// dead index entries per node. Default OFF keeps every property indexed so a
// plain server's point-read fast path is unchanged.
//
// These tests pin the gate (`shouldIndexProperty`) — the single predicate both
// index-add sites consult:
//   1. Lean OFF (default): every key is indexable.
//   2. Lean ON: only registered MERGE keys are indexable; non-merge keys are
//      skipped — but the merge key (used for dedup + edge-endpoint resolution)
//      stays indexable, so MERGE/MATCH-by-key still work.
//   3. Registration is idempotent and order-independent (a key registered after
//      the flag is honored).

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;

test "lean OFF (default): all property keys are indexable" {
    graph_store.setLeanIndexingForTest(false);
    defer graph_store.setLeanIndexingForTest(false);

    try std.testing.expect(!graph_store.leanIndexingEnabled());
    // Every key — merge key or arbitrary SET prop — is indexed.
    try std.testing.expect(graph_store.shouldIndexProperty("taxon_id"));
    try std.testing.expect(graph_store.shouldIndexProperty("scientific_name"));
    try std.testing.expect(graph_store.shouldIndexProperty("is_marine"));
    try std.testing.expect(graph_store.shouldIndexProperty("anything_at_all"));
}

test "lean ON: only registered MERGE keys are indexable" {
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    try std.testing.expect(graph_store.leanIndexingEnabled());

    // Before any merge key is registered, nothing is indexable (the first
    // node's own merge key is registered by the merge fast path BEFORE its
    // properties are indexed — see bulkMergeNode* in graph_storage_adapter).
    try std.testing.expect(!graph_store.shouldIndexProperty("taxon_id"));
    try std.testing.expect(!graph_store.shouldIndexProperty("scientific_name"));

    // Register the MERGE pattern key, as the bulk merge path does.
    graph_store.registerMergeIndexKey("taxon_id");

    // The merge key is now indexable (dedup + MATCH (a {taxon_id: ?}) work);
    // the 19 never-queried SET props are NOT indexed.
    try std.testing.expect(graph_store.shouldIndexProperty("taxon_id"));
    try std.testing.expect(!graph_store.shouldIndexProperty("scientific_name"));
    try std.testing.expect(!graph_store.shouldIndexProperty("is_marine"));
    try std.testing.expect(!graph_store.shouldIndexProperty("authority"));
    try std.testing.expect(!graph_store.shouldIndexProperty("run_id"));
}

test "lean ON: registration is idempotent and supports multiple merge keys" {
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    graph_store.registerMergeIndexKey("taxon_id");
    graph_store.registerMergeIndexKey("taxon_id"); // idempotent
    graph_store.registerMergeIndexKey("sha256"); // a second merge key (e.g. SourceAsset)

    try std.testing.expect(graph_store.shouldIndexProperty("taxon_id"));
    try std.testing.expect(graph_store.shouldIndexProperty("sha256"));
    try std.testing.expect(!graph_store.shouldIndexProperty("scientific_name"));
}

test "lean OFF: registerMergeIndexKey is a no-op (nothing pinned, all indexable)" {
    // When lean mode is off, registration does nothing because every key is
    // already indexable. Toggling on afterward must start from an empty set.
    graph_store.setLeanIndexingForTest(false);
    graph_store.registerMergeIndexKey("taxon_id"); // no-op while off
    try std.testing.expect(graph_store.shouldIndexProperty("scientific_name"));

    // Now flip on (resets the set): nothing is pinned yet.
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);
    try std.testing.expect(!graph_store.shouldIndexProperty("taxon_id"));
}

// ===========================================================================
// Executor-level correctness under lean mode. These run the REAL planner +
// executor + storage so they catch the read-path hazard lean mode introduces:
// the point-read fast path treats an empty exact-index result as authoritative,
// which is WRONG for a key that was never indexed (lean skips non-merge keys).
// The fix (planned_read_runtime fp:) skips the fast path for non-indexed keys
// and falls back to a label scan, so a MATCH filtering on a non-merge property
// still returns the node. Without the fix these tests fail (0 rows).
// ===========================================================================

const execution = geode.execution;
const Value = geode.value_types.Value;

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
};

fn firstStr(res: execution.ExecutionResult) ?[]const u8 {
    if (res.rows.len == 0) return null;
    return switch (res.rows[0][0]) {
        .Str => |s| s,
        else => null,
    };
}

test "lean ON executor: MERGE dedup + point-read by merge AND non-merge key + count" {
    const allocator = std.testing.allocator;
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    var h = try Harness.init(allocator);
    defer h.deinit();

    // Create a Taxon via the MERGE+SET path (registers taxon_id as a merge key).
    {
        var r = try h.runQuery(
            "MERGE (n:Taxon {taxon_id: 'col:LEANX'}) SET n.scientific_name = 'Leanus testus', n.rank = 'Species'",
        );
        r.deinit(h.arena.allocator());
    }

    // (1) Point-read by the MERGE key returns the node (merge key stays indexed).
    {
        var r = try h.runQuery("MATCH (n:Taxon {taxon_id: 'col:LEANX'}) RETURN n.scientific_name AS s");
        defer r.deinit(h.arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expect(firstStr(r) != null);
        try std.testing.expectEqualStrings("Leanus testus", firstStr(r).?);
    }

    // (2) Point-read by a NON-merge key (scientific_name) must STILL return the
    // node. This is the lean-mode read-path hazard: scientific_name is not in
    // the exact index, so the fast path must fall back to a label scan instead
    // of trusting an empty index result. (Pre-fix this returned 0 rows.)
    {
        var r = try h.runQuery("MATCH (n:Taxon {scientific_name: 'Leanus testus'}) RETURN n.taxon_id AS t");
        defer r.deinit(h.arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expect(firstStr(r) != null);
        try std.testing.expectEqualStrings("col:LEANX", firstStr(r).?);
    }

    // (3) Re-MERGE the same taxon_id: must NOT create a duplicate.
    {
        var r = try h.runQuery("MERGE (n:Taxon {taxon_id: 'col:LEANX'}) RETURN n.taxon_id AS t");
        r.deinit(h.arena.allocator());
    }
    {
        var r = try h.runQuery("MATCH (n:Taxon) RETURN count(n) AS c");
        defer r.deinit(h.arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        switch (r.rows[0][0]) {
            .Int => |c| try std.testing.expectEqual(@as(i64, 1), c),
            else => return error.UnexpectedValueTag,
        }
    }
}

test "lean OFF executor: point-read by non-merge key works via fast path (regression)" {
    const allocator = std.testing.allocator;
    graph_store.setLeanIndexingForTest(false);
    defer graph_store.setLeanIndexingForTest(false);

    var h = try Harness.init(allocator);
    defer h.deinit();

    {
        var r = try h.runQuery(
            "MERGE (n:Taxon {taxon_id: 'col:DEFX'}) SET n.scientific_name = 'Defaultus', n.rank = 'Species'",
        );
        r.deinit(h.arena.allocator());
    }
    // With every key indexed, the point-read fast path serves this directly.
    {
        var r = try h.runQuery("MATCH (n:Taxon {scientific_name: 'Defaultus'}) RETURN n.taxon_id AS t");
        defer r.deinit(h.arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        try std.testing.expectEqualStrings("col:DEFX", firstStr(r).?);
    }
}
