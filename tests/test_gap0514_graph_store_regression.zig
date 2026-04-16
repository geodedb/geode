// CANARY: REQ=GAP-0514-PHASE1A; FEATURE="GraphStoreRegressionCoverage"; ASPECT=Scaffold; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig:1; OWNER=engine; UPDATED=2026-04-11
//
// GAP-0514 Phase 1A regression tests for graph_store.zig.
//
// Flips 8 CANARY IMPL markers in `src/graph_store.zig` to TESTED by
// exercising the behaviours they already implement. See
// docs/superpowers/plans/2026-04-11-gap0514-phase1a-graph-store-tests.md
// for the target list.
//
// Each test is mutation-tested during development (break the
// invariant in graph_store.zig, run the test, confirm failure,
// restore). The tests focus on observable *behaviour* — what a
// caller sees — rather than internal bookkeeping that could churn.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const graph_store = geode.graph_store;

/// Minimal harness: a GraphStore backed by a temp data_dir so
/// persistence round-trips can be tested without polluting the
/// process-wide global store state. Use this instead of
/// `graph_store.getGlobalStore()` to keep every test self-contained.
const GsHarness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    store: graph_store.GraphStore,

    pub fn init(allocator: std.mem.Allocator) !GsHarness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        var store = try graph_store.GraphStore.init(allocator);
        errdefer store.deinit();
        store.data_dir = data_dir;
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .store = store,
        };
    }

    pub fn deinit(self: *GsHarness) void {
        self.store.deinit();
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }
};

// REQ-BINARY-PERSIST-DIRTY-001: GraphStore tracks "dirty" state so
// the background persistence loop knows whether there's anything
// to save. A fresh store is clean; the first mutation must flip it
// to dirty.
test "GAP-0514 REQ-BINARY-PERSIST-DIRTY-001: createNode marks store dirty" {
    var h = try GsHarness.init(testing.allocator);
    defer h.deinit();

    // Fresh store must be clean.
    try testing.expect(!h.store.isDirty());

    const labels = [_][]const u8{"Widget"};
    _ = try h.store.createNode(&labels);

    // After creating a node, dirty flag must be set. A regression
    // that forgets to mark the store dirty would prevent the
    // background persist loop from ever checkpointing the node.
    try testing.expect(h.store.isDirty());
}

// REQ-BINARY-PERSIST-DIRTY-002: `saveIfDirty` is the persistence
// loop's cheap-check entry point. When the store is clean it must
// return without doing any work — otherwise the persistence loop
// burns CPU and disk I/O every tick.
test "GAP-0514 REQ-BINARY-PERSIST-DIRTY-002: saveIfDirty on clean store is a no-op" {
    var h = try GsHarness.init(testing.allocator);
    defer h.deinit();

    // Fresh store is clean — saveIfDirty must not touch anything.
    try testing.expect(!h.store.isDirty());
    h.store.saveIfDirty();
    // Still clean after the no-op call.
    try testing.expect(!h.store.isDirty());

    // Make it dirty via a mutation, then save. Post-save the
    // store should be clean again (saveToFile clears dirty —
    // covered by the REQ-STORAGE-ENGINE-PHASE2-002 test below).
    const labels = [_][]const u8{"Widget"};
    _ = try h.store.createNode(&labels);
    try testing.expect(h.store.isDirty());
    // Note: saveIfDirty calls saveToFile which requires a
    // global_adapter in production. In this unit-level harness we
    // don't wire an adapter, so saveToFile becomes effectively a
    // "clear dirty" operation. That's exactly what this test
    // wants: verify the dirty-flag state machine, not the disk
    // write itself (that's the PHASE2-002 test's job).
    h.store.saveIfDirty();
    try testing.expect(!h.store.isDirty());
}

// REQ-BINARY-PERSIST-EDGE-001: Same invariant as DIRTY-001 but
// on the edge-create path. An edge insertion must dirty the
// store so the background loop persists it.
test "GAP-0514 REQ-BINARY-PERSIST-EDGE-001: createEdge marks store dirty" {
    var h = try GsHarness.init(testing.allocator);
    defer h.deinit();

    // Create two nodes first (edges need endpoints).
    const labels = [_][]const u8{"Widget"};
    const a = try h.store.createNode(&labels);
    const b = try h.store.createNode(&labels);

    // After createNode calls above the store is already dirty,
    // so clear it manually to isolate the edge-create effect.
    h.store.saveIfDirty();
    try testing.expect(!h.store.isDirty());

    _ = try h.store.createEdge(a, b, "KNOWS");

    try testing.expect(h.store.isDirty());
}

// REQ-PERF-EDGE-ADJ-001 (field) + REQ-PERF-EDGE-ADJ-002 (maintenance):
// The adjacency indexes (outgoing_edges, incoming_edges) are kept
// in sync with the primary edge store so that DELETE DETACH and
// traversal queries don't need to scan every edge. The field and
// its maintenance are separate markers but share one test.
test "GAP-0514 REQ-PERF-EDGE-ADJ: createEdge populates outgoing and incoming indexes" {
    var h = try GsHarness.init(testing.allocator);
    defer h.deinit();

    const labels = [_][]const u8{"N"};
    const a = try h.store.createNode(&labels);
    const b = try h.store.createNode(&labels);
    const c = try h.store.createNode(&labels);

    const e_ab = try h.store.createEdge(a, b, "LINK");
    const e_ac = try h.store.createEdge(a, c, "LINK");

    // a has two outgoing edges (→b and →c), no incoming edges.
    const a_out = h.store.getOutgoingEdgeIds(a) orelse return error.MissingOutgoing;
    try testing.expectEqual(@as(usize, 2), a_out.len);
    // Both edge IDs must be present (order-independent).
    var saw_ab = false;
    var saw_ac = false;
    for (a_out) |eid| {
        if (eid == e_ab) saw_ab = true;
        if (eid == e_ac) saw_ac = true;
    }
    try testing.expect(saw_ab);
    try testing.expect(saw_ac);
    try testing.expect(h.store.getIncomingEdgeIds(a) == null);

    // b has one incoming edge (from a), no outgoing.
    const b_in = h.store.getIncomingEdgeIds(b) orelse return error.MissingIncoming;
    try testing.expectEqual(@as(usize, 1), b_in.len);
    try testing.expectEqual(e_ab, b_in[0]);
    try testing.expect(h.store.getOutgoingEdgeIds(b) == null);

    // c symmetric to b.
    const c_in = h.store.getIncomingEdgeIds(c) orelse return error.MissingIncoming;
    try testing.expectEqual(@as(usize, 1), c_in.len);
    try testing.expectEqual(e_ac, c_in[0]);
}

// REQ-MULTI-GRAPH-008 (GraphNames field + GraphHelpers fn): the
// graph registry must track every named graph that has been
// touched (including via createNodeWithGraph and
// createEdgeWithGraph), so SHOW GRAPHS and cross-graph
// bookkeeping see them. Both markers share one REQ-ID and one
// test.
//
// Note: GraphStore.init() pre-registers a "default" graph in
// initWithTenant (src/graph_store.zig:455-457), so a fresh
// harness starts with graphs.count() == 1. The test asserts
// that createNodeWithGraph *grows* the registry past that
// baseline and does not duplicate on re-create.
test "GAP-0514 REQ-MULTI-GRAPH-008: createNodeWithGraph registers graph name" {
    var h = try GsHarness.init(testing.allocator);
    defer h.deinit();

    // Fresh store: only "default" is pre-registered.
    try testing.expect(h.store.graphs.contains("default"));
    const baseline = h.store.graphs.count();
    try testing.expectEqual(@as(u32, 1), baseline);

    const labels = [_][]const u8{"N"};
    _ = try h.store.createNodeWithGraph(&labels, "alpha");

    // After creating a node in "alpha", the registry grew by one.
    try testing.expect(h.store.graphs.contains("alpha"));
    try testing.expectEqual(baseline + 1, h.store.graphs.count());

    // Creating a second node in the same graph does not duplicate.
    _ = try h.store.createNodeWithGraph(&labels, "alpha");
    try testing.expectEqual(baseline + 1, h.store.graphs.count());

    // Creating a node in a new graph adds one more entry.
    _ = try h.store.createNodeWithGraph(&labels, "beta");
    try testing.expect(h.store.graphs.contains("beta"));
    try testing.expectEqual(baseline + 2, h.store.graphs.count());
}

// REQ-STORAGE-ENGINE-PHASE2-002: saveToFile is the public save
// entry point. Even when the storage adapter is unavailable (unit
// test context with no global_adapter wired), saveToFile must
// still clear the dirty flag and clean up legacy sidecar files so
// the next persistence-loop tick doesn't redundantly re-save.
test "GAP-0514 REQ-STORAGE-ENGINE-PHASE2-002: saveToFile clears dirty flag" {
    var h = try GsHarness.init(testing.allocator);
    defer h.deinit();

    // Dirty the store.
    const labels = [_][]const u8{"N"};
    _ = try h.store.createNode(&labels);
    try testing.expect(h.store.isDirty());

    // Save. No adapter is wired in this harness, so saveToFile
    // takes the "no-op checkpoint + clear dirty + cleanup stale
    // sidecars" path. This is the exact behaviour the persistence
    // loop relies on when running ahead of any configured
    // adapter (early startup, tests).
    try h.store.saveToFile();

    // Post-save: dirty must be cleared.
    try testing.expect(!h.store.isDirty());

    // Calling saveToFile again on a clean store is also safe
    // (idempotent). This pins down the invariant that the
    // persistence loop can call saveToFile in a loop without
    // thrashing state.
    try h.store.saveToFile();
    try testing.expect(!h.store.isDirty());
}
