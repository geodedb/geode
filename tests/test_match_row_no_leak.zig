// CANARY: REQ=REQ-PERF-QPS-0806; FEATURE="MaterializeNodeLeakFix"; ASPECT=InteriorDupeArenaBacked; STATUS=TESTED; TEST=tests/test_match_row_no_leak.zig:1; OWNER=performance; UPDATED=2026-04-19
//
// Task 1.5 regression: `planned_read_runtime.materializeNode` leaked the
// Node's interior bytes (`graph_name` dupe, `labels` slice + label
// strings, property keys, property values) on every returned MATCH row.
// `OwnedGraphEntities.deinit` only destroys the Node struct itself — it
// does NOT walk inside the Node to free these interior bytes. Under
// DebugAllocator a 90-min loadtest accumulated 3,422 leak stacks.
//
// Fix: interior dupes are routed through `match_operations.scratchAllocatorOr`,
// which returns the per-query arena (GAP-0755) when installed. The Node
// struct itself stays on the caller's allocator — only the interior bytes
// migrate.
//
// This test pins the contract: with a scratch arena installed on the
// current thread, calling `materializeNode` under `testing.allocator` and
// freeing ONLY the Node struct (the cleanup path that
// `OwnedGraphEntities.deinit` takes) must not leak. Without the fix the
// interior bytes would be allocated from `testing.allocator` directly
// and the scope-exit leak check would fire on every dupe.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const planned_read_runtime = geode.planned_read_runtime;
const query_arena = geode.query_arena;

// Build a path to a tmp data dir without relying on Zig 0.16's removed
// `Io.Dir.realpathAlloc`. Same pattern as test_match_set_label_scan_regression.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

test "Task 1.5: materializeNode's interior dupes route through per-query arena" {
    const allocator = testing.allocator;

    // 1. Tear down any global state left over by other tests in the same
    //    binary so the adapter sees a clean slate.
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    // 2. Stand up the global store with an engine-backed storage adapter.
    //    `materializeNode` calls `graph_store.getGlobalAdapter()` and will
    //    fail fast with `error.Unsupported` if no adapter is wired.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    const store = graph_store.getGlobalStore(allocator);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
    }

    // 3. Seed a node with multiple properties (one string, one int). The
    //    string property exercises the `fromStorageProperty` dupe path;
    //    multiple keys exercise the per-key `allocator.dupe` at
    //    `materializeNode:962`.
    const graph_name = "default";
    const label_slice = [_][]const u8{"Widget"};
    const public_id = try store.createNodeWithGraph(&label_slice, graph_name);
    try store.setNodeProperty(public_id, "name", .{ .String = "alice" });
    try store.setNodeProperty(public_id, "count", .{ .Int = 42 });

    // `materializeNode` takes a slot_id, not a public id. Look it up via
    // the IdMap (the same path the executor uses).
    const id_map = store.getIdMap(graph_name) orelse return error.IdMapNotLoaded;
    const slot_id = id_map.nodeSlot(@as(u128, public_id)) orelse return error.SlotMissing;

    // 4. Install a per-query arena on the current thread. This is the
    //    production path: the QUIC/gRPC handler calls
    //    `pushScratchAllocator` around each query. Interior dupes inside
    //    `materializeNode` must land in this arena — not in
    //    `testing.allocator` — and must drop on arena deinit.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(arena.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);

    // 5. Call materializeNode. The Node struct itself is owned by
    //    `allocator` (= testing.allocator). Interior bytes (graph_name
    //    dupe, labels, property keys, "alice" string) must come from
    //    the arena.
    const node = try planned_read_runtime.materializeNode(allocator, graph_name, slot_id);

    // Light sanity on the materialized data — we expect one label and
    // both properties to be present. If `materializeNode` stops populating
    // them the test's leak contract is meaningless.
    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("Widget", node.labels[0]);
    try testing.expectEqualStrings(graph_name, node.graph_name);
    try testing.expect(node.properties.contains("name"));
    try testing.expect(node.properties.contains("count"));

    // 6. Free only the Node struct — the exact cleanup path taken by
    //    `OwnedGraphEntities.deinit`. If the fix regresses and interior
    //    bytes are again allocated from `testing.allocator`, the
    //    `testing.allocator`'s scope-exit leak check will fire on every
    //    dupe.
    allocator.destroy(node);
}
