// GAP-ENT-0048 crash-reopen reconcile (Phase E) — the CORRECTNESS-CRITICAL gate.
//
// After a crash (committed WAL tail past the last checkpoint), geode's reopen
// RECONCILES the persisted `prop_exact.idx` in O(tail) — evicting each
// tail-changed node's OLD postings via the persisted node→postings reverse map
// (`prop_rev.idx`, Phase E1) and re-deriving its CURRENT postings from the
// engine (Phase E2) — instead of the O(graph) full rebuild.
//
// A WRONG reconcile = silently-wrong WHERE/GROUP-BY/DISTINCT/count. So the gate
// here is: the RECONCILED index is KEY-FOR-KEY *and* COUNT-FOR-COUNT identical
// to a full rebuild over the crash-recovered state, for a committed tail that
// contains an INSERT, an in-place indexed-value CHANGE, and a DELETE. Plus:
//   * a clean reopen RELOADS (never wrongly reconciles),
//   * the ungated multi-crash path (covered_lsn != pre-recovery) REBUILDS,
//   * a missing reverse map REBUILDS (safe fallback),
//   * the reconciled index serves DISTINCT / GROUP BY / filtered-count
//     identically to a fresh rebuild (GAP-ENT-0055 shapes).

const std = @import("std");
const exact_index_read = @import("exact_index_read.zig");
const testing = std.testing;
const geode = @import("geode");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const PropertyValue = geode.graph_store.PropertyValue;
const gs = @import("graph_storage");

const SHARD_COUNT: usize = gs.sharded_engine.SHARD_COUNT;

fn testConfig() gs.GraphConfig {
    return .{ .page_size = 4096, .buffer_pool_pages = 64 };
}

const Dump = []adapter_mod.StorageAdapter.ExactIndexPostingDump;

fn freeDump(allocator: std.mem.Allocator, d: Dump) void {
    for (d) |e| {
        allocator.free(e.key);
        allocator.free(e.nodes);
    }
    allocator.free(d);
}

/// The exact "reconcile == full rebuild" comparison: same set of encoded keys,
/// and for each key the SAME sorted node list (its length == the posting count).
fn expectDumpsEqual(a: Dump, b: Dump) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |ea, eb| {
        try testing.expectEqualSlices(u8, ea.key, eb.key);
        try testing.expectEqualSlices(u64, ea.nodes, eb.nodes);
    }
}

fn querySorted(
    allocator: std.mem.Allocator,
    adapter: *StorageAdapter,
    graph: []const u8,
    key: []const u8,
    value: PropertyValue,
) ![]u64 {
    // SONNY-6827: may meet a reopen's background rebuild (ExactIndexBusy).
    const got = try exact_index_read.candidates(adapter, graph, label, key, value, allocator);
    std.mem.sort(u64, got, {}, std.sort.asc(u64));
    return got;
}

// ---------------------------------------------------------------------------
// Shared seed + tail construction.
// ---------------------------------------------------------------------------

const Seed = struct {
    node_ids: []u64,
    changed_node: u64, // existing node whose "grp" is changed in the tail
    deleted_node: u64, // existing node deleted in the tail
    deleted_uid: i64, // the deleted node's "uid" (its seed index)
    inserted_node: u64, // new node created in the tail
    old_changed_grp: i64,
    new_changed_grp: i64,
    deleted_grp: i64,
    inserted_grp: i64,
};

const label = "Item";
const N: usize = 256;
const GROUPS: i64 = 4;

/// Session 1: seed N nodes across shards, FULL-checkpoint (stamps prop_exact.idx
/// + prop_rev.idx at (epoch, covered=F_A)), then apply a committed WAL tail
/// (insert + in-place value change + delete) that is NOT checkpointed. Returns
/// the seed metadata; the caller then CRASHES (simulateCrashForTesting) so the
/// tail survives for the reopen reconcile.
fn seedAndApplyTail(allocator: std.mem.Allocator, adapter: *StorageAdapter, graph: []const u8) !Seed {
    var node_ids = try allocator.alloc(u64, N);
    errdefer allocator.free(node_ids);

    var i: usize = 0;
    while (i < N) : (i += 1) {
        const node_id = try adapter.createNode(graph, &[_][]const u8{label});
        node_ids[i] = node_id;
        try adapter.setNodeProperty(graph, node_id, "uid", .{ .Int = @intCast(i) });
        try adapter.setNodeProperty(graph, node_id, "grp", .{ .Int = @mod(@as(i64, @intCast(i)), GROUPS) });
    }

    // FULL checkpoint: durable pages + prop_exact.idx + prop_rev.idx at F_A.
    try adapter.checkpointAll();

    // ---- committed WAL tail (NOT checkpointed) ----
    const changed_node = node_ids[10];
    const old_changed_grp: i64 = @mod(@as(i64, 10), GROUPS);
    const new_changed_grp: i64 = 5; // a brand-new group value
    try adapter.setNodeProperty(graph, changed_node, "grp", .{ .Int = new_changed_grp });

    const deleted_node = node_ids[20];
    const deleted_grp: i64 = @mod(@as(i64, 20), GROUPS);
    try adapter.deleteNode(graph, deleted_node);

    const inserted_node = try adapter.createNode(graph, &[_][]const u8{label});
    const inserted_grp: i64 = 6;
    try adapter.setNodeProperty(graph, inserted_node, "uid", .{ .Int = 999_999 });
    try adapter.setNodeProperty(graph, inserted_node, "grp", .{ .Int = inserted_grp });

    return .{
        .node_ids = node_ids,
        .changed_node = changed_node,
        .deleted_node = deleted_node,
        .deleted_uid = 20,
        .inserted_node = inserted_node,
        .old_changed_grp = old_changed_grp,
        .new_changed_grp = new_changed_grp,
        .deleted_grp = deleted_grp,
        .inserted_grp = inserted_grp,
    };
}

// ===========================================================================
// E1 — reverse map: persisted, reload round-trip, bounded size.
// ===========================================================================

test "E1: prop_rev.idx round-trips and is the exact inversion of the forward index" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "rev_roundtrip";

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const node_id = try adapter.createNode(graph, &[_][]const u8{label});
        try adapter.setNodeProperty(graph, node_id, "uid", .{ .Int = @intCast(i) });
        try adapter.setNodeProperty(graph, node_id, "grp", .{ .Int = @mod(@as(i64, @intCast(i)), GROUPS) });
    }
    try adapter.checkpointAll();

    const gate = adapter.reconcileGateStateForTesting(graph).?;

    // The reverse map file exists and loads under the CURRENT stamp.
    const rev_pairs = (try adapter.dumpReverseMapForTesting(graph, gate.epoch, gate.covered_lsn, allocator)) orelse
        return error.ReverseMapMissing;
    defer {
        for (rev_pairs) |p| allocator.free(p.key);
        allocator.free(rev_pairs);
    }

    // Inversion equality: build (node_id, key) pairs from the FORWARD index and
    // assert the reverse map contains exactly the same set.
    const fwd = try adapter.dumpExactIndexPostingsForTesting(graph, allocator);
    defer freeDump(allocator, fwd);

    var expected = std.ArrayList(adapter_mod.StorageAdapter.ReverseMapPairDump).empty;
    defer {
        for (expected.items) |p| allocator.free(p.key);
        expected.deinit(allocator);
    }
    for (fwd) |e| {
        for (e.nodes) |nid| {
            try expected.append(allocator, .{ .node_id = nid, .key = try allocator.dupe(u8, e.key) });
        }
    }
    std.mem.sort(adapter_mod.StorageAdapter.ReverseMapPairDump, expected.items, {}, struct {
        fn lt(_: void, a: adapter_mod.StorageAdapter.ReverseMapPairDump, b: adapter_mod.StorageAdapter.ReverseMapPairDump) bool {
            if (a.node_id != b.node_id) return a.node_id < b.node_id;
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lt);

    try testing.expectEqual(expected.items.len, rev_pairs.len);
    for (expected.items, rev_pairs) |ep, rp| {
        try testing.expectEqual(ep.node_id, rp.node_id);
        try testing.expectEqualSlices(u8, ep.key, rp.key);
    }

    // A wrong stamp does NOT load (the reconcile load gate).
    try testing.expect((try adapter.dumpReverseMapForTesting(graph, gate.epoch + 1, gate.covered_lsn, allocator)) == null);
}

test "E1: reverse map size is BOUNDED — independent of property VALUE length" {
    const allocator = testing.allocator;

    const short_size = try revSizeForValueLen(allocator, 4);
    const long_size = try revSizeForValueLen(allocator, 512);

    // Only the 8-byte value_hash is stored, so a 128x longer VALUE must not
    // grow the reverse map (identical node/key structure → identical file size).
    try testing.expectEqual(short_size, long_size);
}

fn revSizeForValueLen(allocator: std.mem.Allocator, value_len: usize) !u64 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "rev_bounded";
    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const val = try allocator.alloc(u8, value_len);
    defer allocator.free(val);
    @memset(val, 'x');

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const node_id = try adapter.createNode(graph, &[_][]const u8{label});
        try adapter.setNodeProperty(graph, node_id, "name", .{ .String = val });
    }
    try adapter.checkpointAll();
    return adapter.reverseMapFileSizeForTesting(graph) orelse error.ReverseMapMissing;
}

// ===========================================================================
// E2 — the reconcile == full-rebuild gate (crash tail: insert/change/delete).
// ===========================================================================

test "E2 GATE: crash-tail reconcile == full rebuild (keys+counts), reconciled==1 rebuilds==0" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "crash_reconcile";

    var seed: Seed = undefined;
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        seed = try seedAndApplyTail(allocator, adapter, graph);
        // CRASH (kill-9 sim): committed WAL tail survives, NOT checkpointed.
        adapter.simulateCrashForTesting();
    }
    defer allocator.free(seed.node_ids);

    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    adapter_mod.resetExactIndexReconcileCountersForTesting();

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    // Reopen → the crash tail is RECONCILED (not rebuilt, not reloaded-clean).
    _ = try adapter.getOrCreateGraph(graph);
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReconciledForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReloadedForTesting());

    // Capture the reconciled index + serving shapes.
    const dump_reconciled = try adapter.dumpExactIndexPostingsForTesting(graph, allocator);
    defer freeDump(allocator, dump_reconciled);

    // Point lookups: changed node moved values; deleted node gone; inserted present.
    try expectLookup(allocator, adapter, graph, "grp", seed.new_changed_grp, &.{seed.changed_node});
    try expectAbsent(allocator, adapter, graph, "grp", seed.old_changed_grp, seed.changed_node);
    try expectAbsent(allocator, adapter, graph, "uid", @intCast(seed.deleted_uid), seed.deleted_node);
    try expectLookup(allocator, adapter, graph, "grp", seed.inserted_grp, &.{seed.inserted_node});

    // Filtered count (GAP-ENT-0055) served from the reconciled postings.
    const cnt_new = try adapter.countCandidateNodesByLabelAndProperty(graph, label, "grp", .{ .Int = seed.new_changed_grp });
    try testing.expectEqual(@as(usize, 1), cnt_new);

    // Now FORCE a full rebuild over the SAME crash-recovered pages and assert the
    // reconciled index is byte-identical to it — the KEY-FOR-KEY + COUNT-FOR-COUNT
    // release gate.
    try adapter.rebuildExactPropertyIndexForTesting(graph);
    const dump_rebuilt = try adapter.dumpExactIndexPostingsForTesting(graph, allocator);
    defer freeDump(allocator, dump_rebuilt);
    try expectDumpsEqual(dump_reconciled, dump_rebuilt);
}

test "E2 GATE (clean-shutdown leg): reconciled state survives a clean checkpoint + reopen, reload == rebuild" {
    // The reconcile-eligible state (epoch-match + committed tail + single
    // recovery) only arises from a CRASH — a clean shutdown checkpoints, which
    // bumps the epoch (→ clean RELOAD or a safe rebuild, never a stale serve).
    // This test proves the crash-RECONCILED index is DURABLE + correct across a
    // subsequent CLEAN shutdown: after reconcile we clean-checkpoint + reopen,
    // the snapshot RELOADS (covered==frontier, no tail), and the reloaded index
    // is KEY-FOR-KEY + COUNT-FOR-COUNT equal to a fresh full rebuild — the
    // clean-shutdown-tail leg of the gate.
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "reconcile_then_clean";

    var seed: Seed = undefined;
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        seed = try seedAndApplyTail(allocator, adapter, graph);
        adapter.simulateCrashForTesting();
    }
    defer allocator.free(seed.node_ids);

    // Reopen #1 → RECONCILE the crash tail, then CLEAN checkpoint + clean close.
    {
        adapter_mod.resetExactIndexReconcileCountersForTesting();
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        _ = try adapter.getOrCreateGraph(graph);
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReconciledForTesting());
        try adapter.checkpointAll(); // re-stamps prop_exact.idx at covered==frontier
        adapter.deinit(); // clean shutdown
    }

    // Reopen #2 → clean RELOAD (no tail), and the reloaded index == fresh rebuild.
    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    adapter_mod.resetExactIndexReconcileCountersForTesting();
    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph(graph);
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReconciledForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());

    const dump_reloaded = try adapter.dumpExactIndexPostingsForTesting(graph, allocator);
    defer freeDump(allocator, dump_reloaded);
    try adapter.rebuildExactPropertyIndexForTesting(graph);
    const dump_rebuilt = try adapter.dumpExactIndexPostingsForTesting(graph, allocator);
    defer freeDump(allocator, dump_rebuilt);
    try expectDumpsEqual(dump_reloaded, dump_rebuilt);
}

test "E2: DISTINCT + GROUP BY posting summaries match a full rebuild after reconcile" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "reconcile_groupby";

    var seed: Seed = undefined;
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        seed = try seedAndApplyTail(allocator, adapter, graph);
        adapter.simulateCrashForTesting();
    }
    defer allocator.free(seed.node_ids);

    adapter_mod.resetExactIndexReconcileCountersForTesting();
    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph(graph);
    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReconciledForTesting());

    // GROUP BY grp / DISTINCT grp summaries (value_hash -> count) after reconcile.
    const sum_reconciled = try adapter.collectPropertyPostingSummaries(graph, label, "grp", allocator);
    defer allocator.free(sum_reconciled);
    const grp_summary_reconciled = try summaryMap(allocator, sum_reconciled);
    defer allocator.free(grp_summary_reconciled);

    try adapter.rebuildExactPropertyIndexForTesting(graph);
    const sum_rebuilt = try adapter.collectPropertyPostingSummaries(graph, label, "grp", allocator);
    defer allocator.free(sum_rebuilt);
    const grp_summary_rebuilt = try summaryMap(allocator, sum_rebuilt);
    defer allocator.free(grp_summary_rebuilt);

    // Same number of DISTINCT values and same per-group COUNTs.
    try testing.expectEqual(grp_summary_reconciled.len, grp_summary_rebuilt.len);
    for (grp_summary_reconciled, grp_summary_rebuilt) |a, b| {
        try testing.expectEqual(a.value_hash, b.value_hash);
        try testing.expectEqual(a.count, b.count);
    }
}

// ===========================================================================
// E2 — the NEGATIVE gates: never wrongly reconcile.
// ===========================================================================

test "E2: clean reopen RELOADS (no wrongful reconcile)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "clean_reload";
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit(); // CLEAN close → final checkpoint absorbs everything (no tail)
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const node_id = try adapter.createNode(graph, &[_][]const u8{label});
            try adapter.setNodeProperty(graph, node_id, "grp", .{ .Int = @mod(@as(i64, @intCast(i)), GROUPS) });
        }
        try adapter.checkpointAll();
    }

    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReloadCountersForTesting();
    adapter_mod.resetExactIndexReconcileCountersForTesting();

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph(graph);

    try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReloadedForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReconciledForTesting());
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactRebuildRunsForTesting());
}

test "E2: multi-crash (covered != pre-recovery) does NOT reconcile — safe rebuild" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "multi_crash";

    var seed: Seed = undefined;
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        seed = try seedAndApplyTail(allocator, adapter, graph);
        adapter.simulateCrashForTesting(); // crash #1
    }
    defer allocator.free(seed.node_ids);

    // Reopen #1 reconciles the F_A→F_B tail (recovery PERSISTS the advanced
    // frontier to F_B), then apply MORE committed writes and crash AGAIN without
    // a checkpoint. On reopen #2 the snapshot still stamps covered=F_A but the
    // pre-recovery frontier is now F_B → gate fails → REBUILD.
    {
        adapter_mod.resetExactIndexReconcileCountersForTesting();
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        _ = try adapter.getOrCreateGraph(graph);
        try testing.expectEqual(@as(u64, 1), adapter_mod.getExactIndexReconciledForTesting());
        // second committed tail, no checkpoint
        const extra = try adapter.createNode(graph, &[_][]const u8{label});
        try adapter.setNodeProperty(graph, extra, "grp", .{ .Int = 7 });
        adapter.simulateCrashForTesting(); // crash #2
    }

    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReconcileCountersForTesting();
    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph(graph);

    // Ungated: no reconcile. (A background rebuild is spawned; the results are
    // proven correct below regardless of whether it or the lazy build ran.)
    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReconciledForTesting());

    // Correctness after the safe rebuild path: the changed value is present, the
    // deleted node is gone, both inserted nodes are present.
    try expectLookup(allocator, adapter, graph, "grp", seed.new_changed_grp, &.{seed.changed_node});
    try expectAbsent(allocator, adapter, graph, "uid", @intCast(seed.deleted_uid), seed.deleted_node);
    // A rebuild was forced by the query above (or by the reopen spawn).
    try testing.expect(adapter_mod.getExactRebuildRunsForTesting() >= 1);
}

test "E2: reverse map ABSENT → safe full rebuild (never an unsound reconcile)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph = "rev_absent";

    var seed: Seed = undefined;
    var uuid_hex: [32]u8 = undefined;
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        seed = try seedAndApplyTail(allocator, adapter, graph);
        const mg = try adapter.getOrCreateGraph(graph);
        uuid_hex = std.fmt.bytesToHex(mg.uuid, .lower);
        adapter.simulateCrashForTesting();
    }
    defer allocator.free(seed.node_ids);

    // Delete prop_rev.idx before reopen → reconcile can't evict → fall back.
    const rev_path = try std.fmt.allocPrint(allocator, "{s}/{s}/prop_rev.idx", .{ path, &uuid_hex });
    defer allocator.free(rev_path);
    std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), rev_path) catch {};

    adapter_mod.resetExactRebuildRunsForTesting();
    adapter_mod.resetExactIndexReconcileCountersForTesting();
    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph(graph);

    try testing.expectEqual(@as(u64, 0), adapter_mod.getExactIndexReconciledForTesting());
    // Correct results via the rebuild fallback.
    try expectLookup(allocator, adapter, graph, "grp", seed.new_changed_grp, &.{seed.changed_node});
    try expectLookup(allocator, adapter, graph, "grp", seed.inserted_grp, &.{seed.inserted_node});
    try testing.expect(adapter_mod.getExactRebuildRunsForTesting() >= 1);
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn expectLookup(allocator: std.mem.Allocator, adapter: *StorageAdapter, graph: []const u8, key: []const u8, val: i64, expected: []const u64) !void {
    const got = try querySorted(allocator, adapter, graph, key, .{ .Int = val });
    defer allocator.free(got);
    try testing.expectEqualSlices(u64, expected, got);
}

fn expectAbsent(allocator: std.mem.Allocator, adapter: *StorageAdapter, graph: []const u8, key: []const u8, val: i64, node: u64) !void {
    const got = try querySorted(allocator, adapter, graph, key, .{ .Int = val });
    defer allocator.free(got);
    for (got) |g| try testing.expect(g != node);
}

const SummaryEntry = struct { value_hash: u64, count: u64 };

fn summaryMap(allocator: std.mem.Allocator, summaries: []const adapter_mod.StorageAdapter.PropertyPostingSummary) ![]SummaryEntry {
    const out = try allocator.alloc(SummaryEntry, summaries.len);
    for (summaries, out) |s, *o| o.* = .{ .value_hash = s.value_hash, .count = s.count };
    std.mem.sort(SummaryEntry, out, {}, struct {
        fn lt(_: void, a: SummaryEntry, b: SummaryEntry) bool {
            return a.value_hash < b.value_hash;
        }
    }.lt);
    return out;
}
