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
        const data_dir = try tmp.dir.realpathAlloc(allocator, ".");
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
