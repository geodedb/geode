// `planned_read_runtime.materializeNode` / `materializeEdge` leak a node's
// ENTIRE interior for any caller that has NOT installed a per-thread scratch
// arena.
//
// VERIFIED READ-ONLY against this branch before the fix:
//
//   * `src/execution/planned_read_runtime.zig:2910` — `materializeNode` does
//     `const scratch = scratchOr(allocator);`. When no scratch arena is
//     installed on the calling thread `scratchOr` FALLS BACK to `allocator`, so
//     the labels slice + label strings (:2916), the `graph_name` dupe (:2928),
//     and every property key (:2940) and value (:2941) are allocated straight
//     out of the caller's allocator.
//   * `src/execution.zig:662-671` — `OwnedGraphEntities.deinit`, the ONLY
//     cleanup these nodes ever get, does `self.allocator.destroy(node)` and
//     nothing else. It never walks INSIDE the Node. So the interior bytes are
//     released only as a side effect of somebody else tearing down an arena.
//   * `src/execution/planned_read_runtime.zig:2978-2986` — `materializeEdge` is
//     the exact same shape for edges (label, graph_name, property keys/values).
//   * `src/execution/planned_read_runtime.zig:2855-2901` —
//     `materializeNodeProjected` is a THIRD instance of the same pattern
//     (`scratchOr` at :2861, labels at :2867, `graph_name` at :2879, projected
//     keys/values at :2895-2898). It is the one the ROW path actually reaches
//     (`materializeNodeForBinding:2416` -> `materializePathRow:2365/:2375`),
//     so a fix that touches only `materializeNode`/`materializeEdge` will leave
//     the production callers below still leaking. Found while measuring this
//     suite; the leak stacks in tests 2 and 3 name it directly.
//
//   The net contract today is "correct if and only if a thread arena happens to
//   be installed". `tests/test_match_row_no_leak.zig` pins the WITH-arena half
//   (it installs one at :88-91 and passes) — this suite pins the WITHOUT-arena
//   half, which is the half that is broken.
//
// THE NO-ARENA CALLERS ARE REAL PRODUCTION CODE, not hypotheticals:
//
//   * `src/query/materialized_views.zig:711` —
//     `lib.executeProgramWithContext(self.allocator, pr.program, &exec_ctx)`,
//     on the view-refresh thread, with no `pushScratchAllocator` anywhere in
//     the call chain. Every row of every materialized-view refresh leaks its
//     interior, forever, for the life of the process.
//   * `src/distributed/query_coordinator.zig:375` —
//     `execution.executeProgramWithContext(self.allocator, &parse_result.program, context)`
//     for a local federation fragment. Same story.
//
//   Neither is on the QUIC/gRPC request path, which is why the per-request
//   arena (GAP-0755) hides this from the wire tests.
//
// This suite drives the REAL store and the REAL planned-read path under
// `std.testing.allocator`, whose scope-exit leak detector is the assertion.
// Nothing is stubbed. Test 1 calls `materializeNode` directly (the tightest
// possible attribution of the leak to its allocation sites); test 2 mirrors the
// production callers exactly by going through `executeProgramWithContext` with
// no arena installed; test 3 does the same for a relationship row so the
// `materializeEdge` sites are covered too (it is file-private, so a program is
// the only way to reach it). Test 4 is the guardrail that the WITH-arena
// contract still holds.
//
// MEASURED RED SIGNATURE ON THIS BRANCH — 60 leaks total, `std.testing.allocator`
// scope-exit reports, attributed per test:
//
//   test 1 (direct materializeNode, 1 node) ......... 12
//        10 x std/mem/Allocator.zig:454 (the `dupe` behind
//             planned_read_runtime.zig:2916/:2928/:2940/:2941)
//         1 x std/array_list.zig:661   (labels slice)
//         1 x src/graph_store.zig:1240 (CompactPropertyMap backing store)
//   test 2 (3 node rows via executeProgramWithContext)  36  — exactly 3 x 12,
//        stacks naming planned_read_runtime.zig:2867/:2879
//        (materializeNodeProjected) and graph_storage_adapter.zig:5195
//        (getNodeLabels)
//   test 3 (1 edge row) ............................. 12, stacks naming
//        planned_read_runtime.zig:2985 (materializeEdge property put)
//   test 4 (guardrail, arena installed) .............. 0 — clean today
//
// The exact proportionality (12 per node row) is the tell: this is per-row
// interior bytes, not a one-off.
//
// CANARY: REQ=REQ-EXEC-MATERIALIZE-OWNERSHIP-001; FEATURE="PlannedReadMaterialize"; ASPECT=InteriorBytesUnconditionalOwnership; STATUS=TESTED; TEST=tests/test_materialize_node_no_arena_leak.zig; OWNER=execution; UPDATED=2026-09-01
// CANARY: REQ=REQ-EXEC-MATERIALIZE-OWNERSHIP-002; FEATURE="PlannedReadMaterialize"; ASPECT=NoArenaCallerLeak; STATUS=TESTED; TEST=tests/test_materialize_node_no_arena_leak.zig; OWNER=execution; UPDATED=2026-09-01

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const planned_read_runtime = geode.planned_read_runtime;
const query_arena = geode.query_arena;

// Zig 0.16 compat: `Io.Dir.realpathAlloc` was removed; join cwd with the tmp
// sub_path by hand (same helper as tests/test_match_row_no_leak.zig:33).
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
    tmp: std.testing.TmpDir,
    data_dir: []u8,
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
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    /// EXACT mirror of query/materialized_views.zig:711 and
    /// distributed/query_coordinator.zig:375: parse, then
    /// `executeProgramWithContext(self.allocator, ...)` with NO
    /// `pushScratchAllocator` anywhere. Whatever the read path allocates and
    /// does not release is a real production leak on those two threads.
    pub fn runProgram(self: *Harness, query: []const u8) !usize {
        var parsed = try geode.parseGqlOptions(query, self.allocator, .{});
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        var result = try execution.executeProgramWithContext(
            self.allocator,
            &parsed.program,
            self.ctx,
        );
        defer result.deinit(self.allocator);
        return result.rows.len;
    }
};

/// Seed one node with a label and several properties (mixed string/int, so both
/// the inline and the `fromStorageProperty` dupe paths run).
fn seedWidget(allocator: std.mem.Allocator, graph_name: []const u8) !u64 {
    const store = graph_store.getGlobalStore(allocator);
    const labels = [_][]const u8{"MzWidget"};
    const id = try store.createNodeWithGraph(&labels, graph_name);
    try store.setNodeProperty(id, "name", .{ .String = "alice" });
    try store.setNodeProperty(id, "city", .{ .String = "portland" });
    try store.setNodeProperty(id, "team", .{ .String = "storage" });
    try store.setNodeProperty(id, "count", .{ .Int = 42 });
    try store.setNodeProperty(id, "rank", .{ .Int = 7 });
    return id;
}

// ===========================================================================
// 1. REGRESSION (tightest attribution) — call `materializeNode` DIRECTLY with
//    no scratch arena installed, and free exactly what
//    `OwnedGraphEntities.deinit` frees: the Node struct, nothing else.
//
//    This is the sibling of tests/test_match_row_no_leak.zig with the arena
//    REMOVED. That test installs one at :88-91 and passes; this one must pass
//    too, because the ownership contract may not be conditional on an arena
//    that two production callers never install.
//
//    RED TODAY: leak report at planned_read_runtime.zig:2916 (labels slice +
//    label strings), :2928 (graph_name), :2940 (5 property keys), :2941
//    (5 property values).
// ===========================================================================
test "regression: materializeNode owns its interior bytes with no scratch arena installed" {
    const allocator = testing.allocator;

    var h = try Harness.init(allocator);
    defer h.deinit();

    const graph_name = "default";
    const public_id = try seedWidget(allocator, graph_name);

    const store = graph_store.getGlobalStore(allocator);
    const id_map = store.getIdMap(graph_name) orelse return error.IdMapNotLoaded;
    const slot_id = id_map.nodeSlot(@as(u128, public_id)) orelse return error.SlotMissing;

    // DELIBERATELY no `query_arena.pushScratchAllocator` — that is the whole
    // point. `scratchOr(allocator)` therefore returns `allocator` itself.
    const node = try planned_read_runtime.materializeNode(allocator, graph_name, slot_id);

    // Sanity: if materializeNode stops populating these the leak contract below
    // would be vacuous.
    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("MzWidget", node.labels[0]);
    try testing.expectEqualStrings(graph_name, node.graph_name);
    try testing.expect(node.properties.contains("name"));
    try testing.expect(node.properties.contains("count"));

    // The EXACT cleanup path OwnedGraphEntities.deinit takes (execution.zig:664).
    allocator.destroy(node);
}

// ===========================================================================
// 2. The production-caller mirror: a whole node row read through
//    `executeProgramWithContext(allocator, ...)` with no arena, exactly as
//    query/materialized_views.zig:711 and
//    distributed/query_coordinator.zig:375 do it.
//
//    RED TODAY: same interior-byte sites, once per returned row.
// ===========================================================================
test "no-arena executeProgramWithContext frees every materialized node row interior" {
    const allocator = testing.allocator;

    var h = try Harness.init(allocator);
    defer h.deinit();

    _ = try seedWidget(allocator, "default");
    _ = try seedWidget(allocator, "default");
    _ = try seedWidget(allocator, "default");

    const rows = try h.runProgram("MATCH (n:MzWidget) RETURN n");
    try testing.expectEqual(@as(usize, 3), rows);
}

// ===========================================================================
// 3. `materializeEdge` (planned_read_runtime.zig:2948) has the identical
//    shape — label (:2966), graph_name (:2968), property keys (:2983) and
//    values (:2984) all on `scratch`. It is file-private, so a relationship
//    program through the same no-arena entry point is the way to reach it.
// ===========================================================================
test "no-arena executeProgramWithContext frees every materialized edge row interior" {
    const allocator = testing.allocator;

    var h = try Harness.init(allocator);
    defer h.deinit();

    const store = graph_store.getGlobalStore(allocator);
    const labels = [_][]const u8{"MzEnd"};
    const a = try store.createNodeWithGraph(&labels, "default");
    const b = try store.createNodeWithGraph(&labels, "default");
    try store.setNodeProperty(a, "name", .{ .String = "left" });
    try store.setNodeProperty(b, "name", .{ .String = "right" });
    const e = try store.createEdgeWithGraph(a, b, "MZ_LINK", "default");
    try store.setEdgeProperty(e, "kind", .{ .String = "primary" });
    try store.setEdgeProperty(e, "weight", .{ .Int = 3 });

    const rows = try h.runProgram("MATCH (x:MzEnd)-[r:MZ_LINK]->(y:MzEnd) RETURN r");
    try testing.expectEqual(@as(usize, 1), rows);
}

// ===========================================================================
// 4. GUARDRAIL — GREEN TODAY AND MUST STAY GREEN.
//
//    With a scratch arena installed, the interior bytes must land in the ARENA
//    and drop with it — the arena must NOT be double-freed by a fix that starts
//    releasing the interior from the caller's allocator. This is the contract
//    tests/test_match_row_no_leak.zig already pins, restated here so the fixer
//    sees both halves side by side and cannot satisfy one by breaking the
//    other.
// ===========================================================================
test "guardrail: with a scratch arena installed the interior still drops with the arena" {
    const allocator = testing.allocator;

    var h = try Harness.init(allocator);
    defer h.deinit();

    const graph_name = "default";
    const public_id = try seedWidget(allocator, graph_name);

    const store = graph_store.getGlobalStore(allocator);
    const id_map = store.getIdMap(graph_name) orelse return error.IdMapNotLoaded;
    const slot_id = id_map.nodeSlot(@as(u128, public_id)) orelse return error.SlotMissing;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(arena.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);

    const node = try planned_read_runtime.materializeNode(allocator, graph_name, slot_id);
    try testing.expectEqualStrings("MzWidget", node.labels[0]);
    try testing.expect(node.properties.contains("name"));
    allocator.destroy(node);
}
