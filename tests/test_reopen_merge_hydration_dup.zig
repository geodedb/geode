// GAP-0046 reopen re-MERGE duplicate under DEFERRED (lazy) hydration.
//
// Repro target (observed at scale 2026-07-05): an OOM-killed server restarted
// mid-ingest, reopened into the DEFERRED / lazy-hydration state (resident loop2
// products — including the in-memory merge_prop_index — not yet rebuilt), and
// the FIRST op on the reopened graph was `MERGE (n:Taxon {taxon_id}) SET ...`.
// Instead of matching the already-present node, the merge match phase saw an
// EMPTY merge index and fell to CREATE → ~3.2M duplicate nodes.
//
// The two existing sibling regressions (test_gap0900_reopen_remerge_dup,
// test_lean_merge_key_seek_reopen) reopen via a CLEAN loadFromFile and always
// issue a read (MATCH/count) BEFORE the re-MERGE, which hydrates the graph
// first. This suite closes the gap they leave: a CRASH reopen (engine advanced
// past the last snapshot — deinitGlobalStoreForTestCrash) whose VERY FIRST op
// is the re-MERGE, so the merge match itself must be what triggers/awaits
// hydration. Both the regular-executor MERGE and the server bulk fast path
// (adapter.bulkMergeNode) are exercised, lean-index ON and OFF.

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const gsa = geode.graph_storage_adapter;

const testing = std.testing;

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

fn countLabel(arena: *std.heap.ArenaAllocator, ctx: execution.ExecutionContext, label: []const u8) !i64 {
    const q = try std.fmt.allocPrint(arena.allocator(), "MATCH (n:{s}) RETURN count(n) AS c", .{label});
    var r = try runQuery(arena, ctx, q);
    defer r.deinit(arena.allocator());
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    return switch (r.rows[0][0]) {
        .Int => |c| c,
        else => error.UnexpectedValueTag,
    };
}

fn openStore(allocator: std.mem.Allocator, data_dir: []const u8) !execution.ExecutionContext {
    graph_store.setDataDirOverride(allocator, data_dir);
    _ = graph_store.getGlobalStore(allocator);
    const catalog = try execution.ensureCatalogInstance(allocator);
    return execution.ExecutionContext{ .catalog = catalog };
}

fn crashClose(allocator: std.mem.Allocator) void {
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStoreForTestCrash();
    graph_store.setDataDirOverride(allocator, null);
}

// ── Scenario 1: regular-executor MERGE, first op after a CRASH reopen. ──────
fn executorReopenReMerge(lean: bool) !void {
    const allocator = testing.allocator;

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

    // Seed one node, checkpoint (durable), then CRASH.
    {
        const ctx = try openStore(allocator, data_dir);
        var r = try runQuery(&arena, ctx, "MERGE (n:Taxon {taxon_id: 'col:X1'}) SET n.scientific_name = 'Alpha'");
        r.deinit(arena.allocator());
        try testing.expectEqual(@as(i64, 1), try countLabel(&arena, ctx, "Taxon"));
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        try adapter.checkpointAll();
    }
    crashClose(allocator);

    // Fresh-process registry (lean re-registers from the persisted sidecar).
    graph_store.setLeanIndexingForTest(lean);
    const ctx2 = try openStore(allocator, data_dir);

    // FIRST op after reopen is the re-MERGE — no prior read to hydrate.
    {
        var r = try runQuery(&arena, ctx2, "MERGE (n:Taxon {taxon_id: 'col:X1'}) SET n.rank = 'Species'");
        r.deinit(arena.allocator());
    }

    // Dedup: still exactly one Taxon (RED pre-fix: 2 — the re-MERGE created a
    // duplicate because the merge match probed an empty/deferred index).
    try testing.expectEqual(@as(i64, 1), try countLabel(&arena, ctx2, "Taxon"));

    // The re-MERGE bound the PRE-EXISTING node (not a fresh create): the seed's
    // scientific_name AND the re-MERGE's rank live on the same single node.
    {
        var r = try runQuery(&arena, ctx2, "MATCH (n:Taxon {taxon_id: 'col:X1'}) RETURN n.scientific_name AS s, n.rank AS r");
        defer r.deinit(arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        try testing.expect(r.rows[0][0] == .Str); // seed property survived reopen
        try testing.expect(r.rows[0][1] == .Str); // re-MERGE property applied
    }
}

test "reopen re-MERGE (executor, lean ON): first-op merge after crash dedups" {
    try executorReopenReMerge(true);
}

test "reopen re-MERGE (executor, lean OFF): first-op merge after crash dedups" {
    try executorReopenReMerge(false);
}

// ── Scenario 2: server bulk fast path (adapter.bulkMergeNode), first op. ────
fn bulkReopenReMerge(lean: bool) !void {
    const allocator = testing.allocator;

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

    const key = "taxon_id";
    const val = graph_store.PropertyValue{ .String = "col:B1" };

    // Seed via the bulk fast path, checkpoint, CRASH.
    {
        _ = try openStore(allocator, data_dir);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        const on_create = [_]gsa.StorageAdapter.PropKV{.{ .key = "scientific_name", .value = .{ .String = "Alpha" } }};
        _ = try adapter.bulkMergeNode("default", "Taxon", key, val, &on_create, null, true);
        const store = graph_store.getWritableGlobalStore(allocator);
        try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("default", "Taxon", null));
        try adapter.checkpointAll();
    }
    crashClose(allocator);

    graph_store.setLeanIndexingForTest(lean);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ctx2 = try openStore(allocator, data_dir);
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;

    // FIRST op after reopen: bulk re-MERGE the same key.
    {
        const on_create = [_]gsa.StorageAdapter.PropKV{.{ .key = "rank", .value = .{ .String = "Species" } }};
        _ = try adapter.bulkMergeNode("default", "Taxon", key, val, &on_create, null, true);
    }

    const store = graph_store.getWritableGlobalStore(allocator);
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("default", "Taxon", null));

    // The re-MERGE bound the pre-existing node: seed + re-MERGE props coexist.
    {
        var r = try runQuery(&arena, ctx2, "MATCH (n:Taxon {taxon_id: 'col:B1'}) RETURN n.scientific_name AS s, n.rank AS r");
        defer r.deinit(arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        try testing.expect(r.rows[0][0] == .Str); // seed property survived reopen
        try testing.expect(r.rows[0][1] == .Str); // re-MERGE property applied
    }
}

test "reopen re-MERGE (bulk fast path, lean ON): first-op merge after crash dedups" {
    try bulkReopenReMerge(true);
}

test "reopen re-MERGE (bulk fast path, lean OFF): first-op merge after crash dedups" {
    try bulkReopenReMerge(false);
}

// ── Scenario 3: COMPOSITE / multi-property bulk MERGE, first op. ────────────
// This is the real from-dump NODE-phase shape `MERGE (t:Taxon {source,
// source_id})`. Its match probe (adapter.findNodeMatchingMergeProps) resolves
// exact-index candidate slots through store.getIdMap + store.nodes.getPtr with
// NO ensureGraphHydrated chokepoint — so on a deferred reopen the probe sees an
// empty/deferred store and CREATEs a duplicate. (Single-key + edge-endpoint
// composite paths are both hydration-guarded; this one was the gap.)
fn compositeReopenReMerge(lean: bool) !void {
    const allocator = testing.allocator;

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

    const merge_props = [_]gsa.StorageAdapter.PropKV{
        .{ .key = "source", .value = .{ .String = "col" } },
        .{ .key = "source_id", .value = .{ .String = "BYZP2" } },
    };

    // Seed via the composite bulk path, checkpoint, CRASH.
    {
        _ = try openStore(allocator, data_dir);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        const store = graph_store.getWritableGlobalStore(allocator);
        const on_create = [_]gsa.StorageAdapter.PropKV{.{ .key = "scientific_name", .value = .{ .String = "Alpha" } }};
        _ = try adapter.bulkMergeNodeWithReservedIdMultiProp("default", store.reserveNodeId(), "Taxon", &merge_props, &on_create, true);
        try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("default", "Taxon", null));
        try adapter.checkpointAll();
    }
    crashClose(allocator);

    graph_store.setLeanIndexingForTest(lean);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ctx2 = try openStore(allocator, data_dir);
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getWritableGlobalStore(allocator);

    // FIRST op after reopen: composite re-MERGE on the same {source, source_id}.
    {
        const on_create = [_]gsa.StorageAdapter.PropKV{.{ .key = "rank", .value = .{ .String = "Species" } }};
        _ = try adapter.bulkMergeNodeWithReservedIdMultiProp("default", store.reserveNodeId(), "Taxon", &merge_props, &on_create, true);
    }

    // Dedup: still exactly one Taxon (RED pre-fix: 2).
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("default", "Taxon", null));

    // The re-MERGE bound the pre-existing node: seed + re-MERGE props coexist.
    {
        var r = try runQuery(&arena, ctx2, "MATCH (n:Taxon {source: 'col', source_id: 'BYZP2'}) RETURN n.scientific_name AS s, n.rank AS r");
        defer r.deinit(arena.allocator());
        try testing.expectEqual(@as(usize, 1), r.rows.len);
        try testing.expect(r.rows[0][0] == .Str); // seed property survived reopen
        try testing.expect(r.rows[0][1] == .Str); // re-MERGE property applied
    }
}

test "reopen re-MERGE (composite bulk path, lean ON): first-op merge after crash dedups" {
    try compositeReopenReMerge(true);
}

test "reopen re-MERGE (composite bulk path, lean OFF): first-op merge after crash dedups" {
    try compositeReopenReMerge(false);
}
