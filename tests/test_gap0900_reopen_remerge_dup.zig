// CANARY: REQ=REQ-PERF-LEAN-INDEX-0900; FEATURE="LeanMergeKeyIndexing"; ASPECT=ReopenReMergeDedup; STATUS=TESTED; TEST=tests/test_gap0900_reopen_remerge_dup.zig; OWNER=performance; UPDATED=2026-06-18
//
// GAP-0900 Layer-3: reopen re-MERGE dedup regression.
//
// Pre-fix bug: with GEODE_INDEX_MERGE_KEYS_ONLY=1 (lean indexing), the in-memory
// merge property index (graph_store.merge_prop_index) is populated only on the
// WRITE path (addToMergePropertyIndex). The adapter-backed hydration path
// (loadOneGraphFromAdapter) repopulates the per-node mirror, the label index,
// and the introspection counters for loaded nodes, but it NEVER repopulates the
// merge property index. So after shutdown+reopen, a re-MERGE of an existing
// node's merge key finds an EMPTY index (.not_found), takes the create branch,
// and produces a DUPLICATE node. This breaks resumable / idempotent seeding.
//
// This test drives the real planner + executor + engine-backed storage:
//   1. MERGE a Taxon (registers taxon_id as a merge key, indexes it).
//   2. Checkpoint + reopen the global store (loadFromFile -> loadFromAdapter).
//   3. Re-MERGE the SAME taxon_id.
//   4. Assert count(n) == 1 (no duplicate) and the re-MERGE resolved the
//      existing node (its SET property survives).
//
// The bug reproduces in BOTH lean-on and lean-off modes because neither rebuilds
// the merge index on reopen; lean-on is the resumable-seed scenario the fix is
// required for, lean-off is the default-server guard.

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

fn reopenReMergeDedup(lean: bool) !void {
    const allocator = std.testing.allocator;

    graph_store.setLeanIndexingForTest(lean);
    defer graph_store.setLeanIndexingForTest(false);

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // --- Phase 1: seed via MERGE+SET, then checkpoint. ---
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    var catalog = try execution.ensureCatalogInstance(allocator);
    var ctx = execution.ExecutionContext{ .catalog = catalog };

    {
        var r = try runQuery(&arena, ctx, "MERGE (n:Taxon {taxon_id: 'col:REOPENX'}) SET n.scientific_name = 'Reopenus testus'");
        r.deinit(arena.allocator());
    }
    try std.testing.expectEqual(@as(i64, 1), try countTaxon(&arena, ctx));

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try adapter.checkpointAll();

    // --- Phase 2: reopen (drop in-memory state, re-hydrate from the engine). ---
    try store.loadFromFile();

    // The node is still present and queryable by its merge key after reopen.
    {
        var r = try runQuery(&arena, ctx, "MATCH (n:Taxon {taxon_id: 'col:REOPENX'}) RETURN n.scientific_name AS s");
        defer r.deinit(arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
    }
    try std.testing.expectEqual(@as(i64, 1), try countTaxon(&arena, ctx));

    // --- Phase 3: re-MERGE the SAME key. Must dedup to the existing node. ---
    {
        var r = try runQuery(&arena, ctx, "MERGE (n:Taxon {taxon_id: 'col:REOPENX'}) SET n.rank = 'Species'");
        r.deinit(arena.allocator());
    }

    // DESIRED: still exactly one Taxon — the re-MERGE found the loaded node
    // through the (rebuilt) merge index instead of creating a duplicate.
    try std.testing.expectEqual(@as(i64, 1), try countTaxon(&arena, ctx));

    // The re-MERGE bound the EXISTING node: both the pre-reopen and post-reopen
    // SET properties live on the same node.
    {
        var r = try runQuery(&arena, ctx, "MATCH (n:Taxon {taxon_id: 'col:REOPENX'}) RETURN n.scientific_name AS s, n.rank AS r");
        defer r.deinit(arena.allocator());
        try std.testing.expectEqual(@as(usize, 1), r.rows.len);
    }

    _ = &catalog;
    _ = &ctx;
}

test "GAP-0900 reopen re-MERGE dedups (lean ON): no duplicate after reopen" {
    try reopenReMergeDedup(true);
}

test "GAP-0900 reopen re-MERGE dedups (lean OFF): no duplicate after reopen" {
    try reopenReMergeDedup(false);
}
