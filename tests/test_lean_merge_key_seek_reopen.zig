// CANARY: REQ=REQ-PERF-LEAN-INDEX-0900; FEATURE="LeanMergeKeyIndexing"; ASPECT=ReopenSeekCompleteness; STATUS=TESTED; TEST=tests/test_lean_merge_key_seek_reopen.zig; OWNER=performance; UPDATED=2026-06-20
//
// LEAN-MERGE-KEY-SEEK: lean reopen → inline merge-key SEEK returns the correct
// row (read-path completeness regression).
//
// Background. With GEODE_INDEX_MERGE_KEYS_ONLY=1 (lean indexing) the adapter's
// exact node-property index admits ONLY registered merge keys. The inline
// `{key: val}` point-read in node_scan_stream SEEKs that index (O(matching))
// instead of full-scanning the label (O(graph)) — required for the 14M-edge
// ingest whose every edge does MATCH (n:Taxon {source, source_id}).
//
// The hazard this test pins: on a REAL restart the adapter rebuilds the exact
// index from the durable pages (openGraphLocked → rebuildExactNodePropertyIndex),
// consulting `shouldIndexProperty`. If the merge keys are not registered yet when
// that rebuild runs, the rebuild SKIPS them and the exact index is INCOMPLETE for
// `source`/`source_id` — so a seek would WRONGLY return empty for existing nodes.
//
// The fix persists the registered merge-key set and re-registers it in
// StorageAdapter.init — BEFORE any graph opens and thus before the rebuild — so
// the rebuild indexes the merge keys' values for ALL existing nodes. After reopen
// the exact index is COMPLETE for the merge keys and the seek is correct.
//
// This test drives the REAL planner + executor + engine-backed storage and does
// a TRUE restart (full deinit of the global store + adapter, registry cleared to
// mimic a fresh process, then re-init pointing at the same data-dir). It then
// issues the inline-key MATCH BEFORE any MERGE — exactly the edge-ingest read
// pattern — and asserts present→1 (correct value), absent→empty.
//
// RED before the fix: the reopen rebuild leaves the merge keys unindexed, so the
// now-lean-enabled seek returns 0 rows for a present node.
// GREEN after the fix: persisted re-registration makes the rebuild complete.

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn runQuery(
    arena: *std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,
    query: []const u8,
) !execution.ExecutionResult {
    const aa = arena.allocator();
    var parsed = try geode.parseGql(query, aa);
    defer parsed.deinit();
    return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
}

fn countTaxon(arena: *std.heap.ArenaAllocator, ctx: execution.ExecutionContext) !i64 {
    var r = try runQuery(arena, ctx, "MATCH (n:Taxon) RETURN count(n) AS c");
    defer r.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), r.rows.len);
    return switch (r.rows[0][0]) {
        .Int => |c| c,
        else => error.UnexpectedValueTag,
    };
}

// Build the global store + catalog for the given data-dir, returning the ctx.
fn openStore(allocator: std.mem.Allocator, data_dir: []const u8) !execution.ExecutionContext {
    graph_store.setDataDirOverride(allocator, data_dir);
    _ = graph_store.getGlobalStore(allocator);
    const catalog = try execution.ensureCatalogInstance(allocator);
    return execution.ExecutionContext{ .catalog = catalog };
}

fn closeStore(allocator: std.mem.Allocator) void {
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
    graph_store.setDataDirOverride(allocator, null);
}

test "LEAN-MERGE-KEY-SEEK: lean reopen seek on {source, source_id} returns the correct row" {
    const allocator = std.testing.allocator;

    // Lean indexing ON for the whole test; reset the (process-global) merge-key
    // registry to empty so the reopen path must re-register from the persisted
    // sidecar — exactly what a fresh server process does.
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    // Start from a clean global state.
    closeStore(allocator);
    defer closeStore(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // ---- Phase 1: seed three Taxon nodes via MERGE on {source, source_id}. ----
    {
        const ctx = try openStore(allocator, data_dir);

        {
            var r = try runQuery(&arena, ctx, "MERGE (n:Taxon {source: 'col', source_id: 'BYZP2'}) SET n.scientific_name = 'Alpha'");
            r.deinit(arena.allocator());
        }
        {
            var r = try runQuery(&arena, ctx, "MERGE (n:Taxon {source: 'col', source_id: 'C2D3E'}) SET n.scientific_name = 'Beta'");
            r.deinit(arena.allocator());
        }
        {
            var r = try runQuery(&arena, ctx, "MERGE (n:Taxon {source: 'col', source_id: 'F4G5H'}) SET n.scientific_name = 'Gamma'");
            r.deinit(arena.allocator());
        }
        try std.testing.expectEqual(@as(i64, 3), try countTaxon(&arena, ctx));

        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        try adapter.checkpointAll();
    }

    // ---- Phase 2: TRUE restart — drop the in-memory store AND the adapter, and
    // clear the merge-key registry so it must be reloaded from the sidecar. ----
    closeStore(allocator);
    graph_store.setLeanIndexingForTest(true); // re-arm lean; registry now EMPTY
    try std.testing.expect(!graph_store.shouldIndexProperty("source"));
    try std.testing.expect(!graph_store.shouldIndexProperty("source_id"));

    // Re-open the SAME data-dir. StorageAdapter.init loads the persisted merge
    // keys BEFORE any graph opens, so the exact-index rebuild indexes them.
    const ctx2 = try openStore(allocator, data_dir);

    // The persisted re-registration must have happened during adapter init.
    try std.testing.expect(graph_store.shouldIndexProperty("source"));
    try std.testing.expect(graph_store.shouldIndexProperty("source_id"));

    // Force the graph to actually open + rebuild its exact index (count touches
    // the adapter). This runs BEFORE any MERGE re-registers the keys.
    try std.testing.expectEqual(@as(i64, 3), try countTaxon(&arena, ctx2));

    // ---- Phase 3 (the critical case): inline-key SEEK on a PRESENT node, BEFORE
    // any MERGE. Must return exactly 1 with the correct value — proving the
    // reopen rebuild made the exact index COMPLETE for the merge keys and the
    // seek is trustworthy in lean mode. (RED pre-fix: incomplete index → 0 rows.)
    {
        var r = try runQuery(&arena, ctx2, "MATCH (n:Taxon {source: 'col', source_id: 'BYZP2'}) RETURN n.scientific_name AS s");
        defer r.deinit(arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        switch (r.rows[0][0]) {
            .Str => |s| try std.testing.expectEqualStrings("Alpha", s),
            else => return error.UnexpectedValueTag,
        }
    }

    // A different present node, still via seek (no MERGE in between).
    {
        var r = try runQuery(&arena, ctx2, "MATCH (n:Taxon {source: 'col', source_id: 'F4G5H'}) RETURN n.scientific_name AS s");
        defer r.deinit(arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        switch (r.rows[0][0]) {
            .Str => |s| try std.testing.expectEqualStrings("Gamma", s),
            else => return error.UnexpectedValueTag,
        }
    }

    // ---- Phase 4: ABSENT source_id → empty (no false positives from the seek). ----
    {
        var r = try runQuery(&arena, ctx2, "MATCH (n:Taxon {source: 'col', source_id: 'NOPE0'}) RETURN n.scientific_name AS s");
        defer r.deinit(arena.allocator());
        try std.testing.expectEqual(@as(usize, 0), r.rows.len);
    }

    // ---- Phase 5: a seek result must equal the full-scan baseline (correctness
    // gate). The label scan path (MATCH (n:Taxon) WHERE ... post-filter) is the
    // ground truth; the inline-key seek above must agree with it. ----
    {
        var r = try runQuery(&arena, ctx2, "MATCH (n:Taxon) WHERE n.source_id = 'BYZP2' RETURN n.scientific_name AS s");
        defer r.deinit(arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        switch (r.rows[0][0]) {
            .Str => |s| try std.testing.expectEqualStrings("Alpha", s),
            else => return error.UnexpectedValueTag,
        }
    }
}

// Second reopen cycle: the persisted sidecar must keep working across REPEATED
// restarts (it is append-only; load de-dups). Mirrors the prompt's "run this
// several times" requirement in one deterministic in-process test.
test "LEAN-MERGE-KEY-SEEK: seek stays correct across a SECOND lean reopen" {
    const allocator = std.testing.allocator;

    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);

    closeStore(allocator);
    defer closeStore(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Seed once.
    {
        const ctx = try openStore(allocator, data_dir);
        var r = try runQuery(&arena, ctx, "MERGE (n:Taxon {source: 'wrms', source_id: 'X9'}) SET n.scientific_name = 'Repeatus'");
        r.deinit(arena.allocator());
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        try adapter.checkpointAll();
    }

    // Reopen twice in a row; assert the seek returns the correct row each time.
    var cycle: usize = 0;
    while (cycle < 2) : (cycle += 1) {
        closeStore(allocator);
        graph_store.setLeanIndexingForTest(true);
        const ctx = try openStore(allocator, data_dir);
        try std.testing.expect(graph_store.shouldIndexProperty("source_id"));

        var r = try runQuery(&arena, ctx, "MATCH (n:Taxon {source: 'wrms', source_id: 'X9'}) RETURN n.scientific_name AS s");
        defer r.deinit(arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
        switch (r.rows[0][0]) {
            .Str => |s| try std.testing.expectEqualStrings("Repeatus", s),
            else => return error.UnexpectedValueTag,
        }
    }
}
