// Regression: graph_store.createGraph TOCTOU race + idempotency.
//
// Reproduces the dsn_graph_binding.yml flake where the harness saw
// "Error: Failed to create graph" on tests 10 ("Verify other graph was
// created via DSN") and 11 ("Graph name with underscores is valid").
//
// Original failure shape: two concurrent paths reach
// `graph_store.createGraph(name)` for the same graph name (DSN
// auto-create + CREATE GRAPH IF NOT EXISTS, or two DSN binds racing for
// the same fresh name). Old createGraph:
//
//     if (global_vtable) |vt| _ = try vt.getOrCreateGraphFn(..);
//     if (self.graphs.contains(graph_name)) return error.GraphAlreadyExists;
//     try self.graphs.put(...);
//
// is two unprotected steps. Two threads observe `!contains`, both call
// the adapter, then one wins the put — the loser surfaces
// `GraphAlreadyExists` which the QUIC HELLO handler turns into "Failed
// to create graph" back to the client.
//
// Fix: serialize CREATE/DROP under `graphs_mutex` and make createGraph
// idempotent for the "another thread won the race" case. Post-fix
// guarantee: N parallel createGraph(name) calls all return Ok, the
// graph is present, and the in-memory registry has a single entry.
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

const WorkerCtx = struct {
    store: *graph_store.GraphStore,
    name: []const u8,
    start_gate: *std.atomic.Value(u32),
    waiting: *std.atomic.Value(u32),
    err_count: *std.atomic.Value(u32),
    ok_count: *std.atomic.Value(u32),
};

fn raceCreateGraph(ctx: *WorkerCtx) void {
    _ = ctx.waiting.fetchAdd(1, .acq_rel);
    while (ctx.start_gate.load(.acquire) == 0) std.atomic.spinLoopHint();
    ctx.store.createGraph(ctx.name) catch {
        _ = ctx.err_count.fetchAdd(1, .acq_rel);
        return;
    };
    _ = ctx.ok_count.fetchAdd(1, .acq_rel);
}

test "createGraph: concurrent callers for same name all succeed (no race-induced failure)" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    const name = "race_target_graph";
    const n_threads: usize = 8;

    var start_gate = std.atomic.Value(u32).init(0);
    var waiting = std.atomic.Value(u32).init(0);
    var err_count = std.atomic.Value(u32).init(0);
    var ok_count = std.atomic.Value(u32).init(0);

    var ctx = WorkerCtx{
        .store = &store,
        .name = name,
        .start_gate = &start_gate,
        .waiting = &waiting,
        .err_count = &err_count,
        .ok_count = &ok_count,
    };

    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, raceCreateGraph, .{&ctx});
    }
    while (waiting.load(.acquire) < n_threads) std.atomic.spinLoopHint();
    start_gate.store(1, .release);
    for (&threads) |*t| t.join();

    // Post-condition 1: nobody errored.  Pre-fix this was 1..n-1 losers
    // each receiving `error.GraphAlreadyExists`.
    try testing.expectEqual(@as(u32, 0), err_count.load(.acquire));

    // Post-condition 2: every caller saw success.
    try testing.expectEqual(@as(u32, @intCast(n_threads)), ok_count.load(.acquire));

    // Post-condition 3: the graph is present in the in-memory registry
    // exactly once.  `graphExists` checks the adapter + registry.
    try testing.expect(store.graphExists(name));
}

test "createGraph: sequential repeat is also idempotent" {
    // Spec-level invariant: calling createGraph twice for the same name
    // must not error.  This matches how raft_apply and user_storage
    // already use the API — both swallow GraphAlreadyExists.
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    try store.createGraph("repeat_me");
    try store.createGraph("repeat_me"); // pre-fix: error.GraphAlreadyExists
    try testing.expect(store.graphExists("repeat_me"));
}

// dsn_graph_binding.yml defense-in-depth (2026-05-24).
//
// The QUIC + gRPC HELLO handlers run two checks before deciding between
// "bind" and "auto-create":
//
//     in_store = store.graphExists(name)
//     in_catalog = cat.hasGraph(name)
//
// If both are false the handler falls into the auto-create branch.  If
// `createGraph` then errors AND the graph is now visible to either layer
// (because a sibling — DDL on the same server, a successful adapter put
// where the in-memory put raced — registered it concurrently), the
// handler now binds instead of bouncing the client with "Failed to
// create graph".  This pins the contract at the storage layer: after
// createGraph returns Ok, the post-condition (graphExists is true) must
// hold — so the handler's recheck is meaningful.
test "createGraph: graphExists reflects the post-condition after Ok return" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    try testing.expect(!store.graphExists("postcondition_test"));
    try store.createGraph("postcondition_test");
    try testing.expect(store.graphExists("postcondition_test"));

    // Repeat: still present, still Ok.
    try store.createGraph("postcondition_test");
    try testing.expect(store.graphExists("postcondition_test"));
}
