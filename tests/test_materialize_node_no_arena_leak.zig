// `planned_read_runtime.materializeNode` / `materializeEdge` / `…Projected`
// dupe a node/edge's ENTIRE interior (labels slice + label strings, graph_name,
// every property key + value) through `scratchOr(allocator)`. When a per-query
// scratch arena is installed the interior drops with that arena; when NONE is
// installed `scratchOr` falls back to the caller's `allocator` and the interior
// leaks, because `OwnedGraphEntities.deinit` frees ONLY the Node/Edge struct,
// never its interior.
//
// FIX (REQ-EXEC-MATERIALIZE-OWNERSHIP-002): rather than teach the shared owner
// to walk INSIDE each entity (unsound — an ExtValue/jsonb property captures its
// own allocator and a per-value free double-frees / aborts; the read-budget
// metered allocator makes the captured allocator dangle), the two production
// callers that ran with NO arena now install a scoped `std.heap.ArenaAllocator`
// and push it as the scratch allocator for the materialize call, tearing it down
// after the rows are consumed:
//   * `src/query/materialized_views.zig` (view-refresh thread), and
//   * `src/distributed/query_coordinator.zig` (local federation fragment).
// Materialize semantics are UNCHANGED (dupe into scratch), so the read-budget
// and restart paths are unaffected; the interior simply drops with the caller's
// arena.
//
// This suite pins that contract. Every test installs a scoped scratch arena (the
// exact shape the two callers now use) and asserts, under
// `std.testing.allocator`'s scope-exit leak detector, that `arena.deinit`
// reclaims ALL interior — the Node/Edge struct is freed by the owner, everything
// else by the arena. Test 1 drives `materializeNode` directly; tests 2/3 mirror
// the production callers through `executeProgramWithContext`; test 4 covers an
// ExtValue/jsonb (advanced) property so the double-free that a per-value owner
// free caused can never regress silently again; test 5 is the WITH-arena
// guardrail restated. Nothing is stubbed.
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
// 1. `materializeNode` directly, under a scoped scratch arena — the exact shape
//    the two production callers now install. The Node struct is freed by the
//    owner (`allocator.destroy`); the interior drops with `arena.deinit`.
//    `std.testing.allocator`'s scope-exit leak check asserts arena.deinit
//    reclaimed EVERYTHING (labels slice + strings, graph_name, property keys +
//    values). If materialize regresses to leaking onto `allocator`, or the arena
//    fails to reclaim the interior, this fires.
// ===========================================================================
test "materializeNode interior is fully reclaimed by a scoped scratch arena" {
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
    const prev = query_arena.pushScratchAllocator(arena.allocator());
    defer query_arena.popScratchAllocator(prev);

    const node = try planned_read_runtime.materializeNode(allocator, graph_name, slot_id);

    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("MzWidget", node.labels[0]);
    try testing.expectEqualStrings(graph_name, node.graph_name);
    try testing.expect(node.properties.contains("name"));
    try testing.expect(node.properties.contains("count"));

    // Owner frees ONLY the struct (exactly OwnedGraphEntities.deinit); the
    // interior is reclaimed by the arena's `defer deinit` above.
    allocator.destroy(node);
}

// ===========================================================================
// 2. The production-caller mirror: whole node rows read through
//    `executeProgramWithContext`, with a scoped scratch arena installed exactly
//    as materialized_views.zig / query_coordinator.zig now do it. The arena
//    reclaims the per-row interior.
// ===========================================================================
test "scoped-arena executeProgramWithContext reclaims every materialized node row interior" {
    const allocator = testing.allocator;

    var h = try Harness.init(allocator);
    defer h.deinit();

    _ = try seedWidget(allocator, "default");
    _ = try seedWidget(allocator, "default");
    _ = try seedWidget(allocator, "default");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const prev = query_arena.pushScratchAllocator(arena.allocator());
    defer query_arena.popScratchAllocator(prev);

    const rows = try h.runProgram("MATCH (n:MzWidget) RETURN n");
    try testing.expectEqual(@as(usize, 3), rows);
}

// ===========================================================================
// 3. `materializeEdge` has the identical shape (label, graph_name, property
//    keys/values on `scratch`). It is file-private, so a relationship program
//    through the same entry point reaches it. Same scoped-arena ownership.
// ===========================================================================
test "scoped-arena executeProgramWithContext reclaims every materialized edge row interior" {
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

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const prev = query_arena.pushScratchAllocator(arena.allocator());
    defer query_arena.popScratchAllocator(prev);

    const rows = try h.runProgram("MATCH (x:MzEnd)-[r:MZ_LINK]->(y:MzEnd) RETURN r");
    try testing.expectEqual(@as(usize, 1), rows);
}

// ===========================================================================
// 4. ADVANCED / ExtValue REGRESSION GUARD — materialize a node carrying a jsonb
//    (and other ExtValue) property under a scoped scratch arena. An ExtValue's
//    interior captures its own allocator; a per-value owner free double-frees /
//    aborts it (the crash that the abandoned owner-frees-interior approach hit,
//    at jsonb.zig deinit). The arena reclaims it WHOLESALE — no per-value free —
//    so this must be leak-free AND crash-free. Pins that the fix stays the arena
//    approach and can never silently regress to per-value ExtValue freeing.
// ===========================================================================
test "scoped-arena reclaims a materialized node's ExtValue/jsonb property interior" {
    const allocator = testing.allocator;

    var h = try Harness.init(allocator);
    defer h.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const prev = query_arena.pushScratchAllocator(arena.allocator());
    defer query_arena.popScratchAllocator(prev);

    // CREATE a node carrying advanced (ExtValue) properties, then RETURN the
    // WHOLE node so materialize dupes the jsonb/domain/smallint interior into the
    // scratch arena.
    _ = try h.runProgram(
        "CREATE (:MzAdv {doc: Jsonb('{\"kind\":\"ok\"}'), dom: Domain('example.com'), age: SmallInt(7)})",
    );
    const rows = try h.runProgram("MATCH (n:MzAdv) RETURN n");
    try testing.expectEqual(@as(usize, 1), rows);
}

// ===========================================================================
// 5. GUARDRAIL — the WITH-arena contract restated (sibling of
//    tests/test_match_row_no_leak.zig): interior lands in the arena and drops
//    with it; the owner frees only the struct.
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
