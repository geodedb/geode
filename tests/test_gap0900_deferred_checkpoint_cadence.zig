// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! GAP-0900 regression: deferred-mode checkpoint never fires during bulk ingest.
//!
//! Bug (confirmed via dataflow):
//!   With `GEODE_WAL_SYNC=deferred`, a sustained bulk ingest through the
//!   group-commit fast path NEVER triggers a periodic checkpoint. The two
//!   `persistenceLoop` triggers (src/graph_store.zig:7866) both depend on
//!   signals the bulk path does not feed:
//!     1. `needs_checkpoint` reads the legacy CDC WAL `g_wal.needsCheckpoint`,
//!        fed only by `notifyMutation`.
//!     2. `persistSplitPhase` is gated on `GraphStore.dirty`.
//!   The group-commit bulk adapter helpers
//!   (bulkInsertNodeWithReservedIdForTenant ~:1981,
//!    bulkMergeNodeWithReservedIdForTenant ~:2319,
//!    bulkMergeNodeWithReservedIdMultiPropForTenant ~:2455)
//!   call NEITHER `notifyMutation` NOR set `store.dirty`. So `checkpointAll`
//!   is never invoked between startup and shutdown during a pure bulk ingest,
//!   and the engine WAL + dirty pages grow unbounded => RSS proportional to
//!   node count => OOM. geode's own comment (graph_store.zig:7541-7547)
//!   documents this bypass; a shutdown-only checkpoint was added to compensate
//!   but does nothing to bound steady-state memory.
//!
//! Fixed behavior this test encodes:
//!   After enough bulk writes through the SAME adapter fast path the ingest
//!   uses (crossing a small, injectable op threshold), the periodic
//!   checkpoint-cadence decision (`StorageAdapter.maybeCheckpoint`) FIRES a
//!   checkpoint independent of the legacy CDC WAL / `GraphStore.dirty`.
//!
//! Observables asserted:
//!   * `adapter.pendingBulkOps()` > 0 after the bulk writes  (the bulk path
//!     must feed the checkpoint-cadence signal — currently it does NOT).
//!   * `adapter.maybeCheckpoint(...)` returns true            (a checkpoint is
//!     due as a result of the bulk writes).
//!   * `adapter.checkpointsTotal()` > 0 after the trigger     (a checkpoint
//!     actually ran).
//!   * `adapter.pendingBulkOps()` == 0 after the checkpoint   (the cadence
//!     signal is reset, i.e. WAL/dirty pressure is bounded).
//!
//! RED today: the bulk path does not bump `pending_bulk_ops`, so it stays 0,
//! `maybeCheckpoint` never fires, and `checkpointsTotal()` stays 0 — exactly
//! reproducing the unbounded-growth bug. The fix wires the bulk fast paths to
//! feed the cadence signal and these assertions pass.
//!
//! Deterministic & CI-safe: no timers/sleeps; the threshold and the elapsed
//! "now" are injected into `maybeCheckpoint` directly.

const std = @import("std");
const geode = @import("geode");
const graph_storage = @import("graph_storage");
const adapter_mod = geode.graph_storage_adapter;
const graph_store = geode.graph_store;

const PropKV = adapter_mod.StorageAdapter.PropKV;

fn tmpDataDir(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

/// Build a deferred-mode StorageAdapter over a fresh tmp dir — mirrors how
/// graph_store.zig:7445-7470 selects `.deferred` from `GEODE_WAL_SYNC` and
/// constructs the adapter, minus the full server bring-up.
fn initDeferredAdapter(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) !*adapter_mod.StorageAdapter {
    return adapter_mod.StorageAdapter.init(allocator, data_dir, graph_storage.GraphConfig{
        .data_dir = data_dir,
        .encryption_key = null,
        .sync_mode = .deferred,
    });
}

test "GAP-0900: deferred-mode periodic checkpoint fires after bulk inserts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    const adapter = try initDeferredAdapter(allocator, data_dir);
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph("g");

    // No checkpoint should have happened yet (init resets the cadence clock).
    try std.testing.expectEqual(@as(u64, 0), adapter.checkpointsTotal());
    try std.testing.expectEqual(@as(u64, 0), adapter.pendingBulkOps());

    const store = graph_store.getGlobalStore(graph_store.global_allocator());

    // Small, deterministic threshold — a few hundred ops, not millions. No OOM
    // risk, fast in CI.
    const checkpoint_ops_threshold: u64 = 256;
    const total_ops: usize = 600; // comfortably crosses the threshold

    // Drive the SAME group-commit bulk fast path the ingest uses.
    const labels = [_][]const u8{"L"};
    const empty_props = [_]PropKV{};
    var i: usize = 0;
    while (i < total_ops) : (i += 1) {
        const reserved = store.reserveNodeId();
        _ = try adapter.bulkInsertNodeWithReservedId("g", reserved, &labels, &empty_props);
    }

    // OBSERVABLE 1 (secondary guard): the bulk path must feed the
    // checkpoint-cadence signal. Today it does not, so this is 0 — RED.
    try std.testing.expect(adapter.pendingBulkOps() >= checkpoint_ops_threshold);

    // OBSERVABLE 2: the periodic decision must now FIRE a checkpoint as a
    // result of the bulk writes. `now_mono_ns = 0` and a non-zero time
    // threshold ensure ONLY the op-count trigger can fire here (deterministic).
    const fired = try adapter.maybeCheckpoint(
        checkpoint_ops_threshold,
        60_000, // time threshold (ms) — irrelevant; op trigger drives this
        0, // injected "now" (monotonic ns) — no time elapsed
    );
    try std.testing.expect(fired);

    // OBSERVABLE 3: a checkpoint actually ran.
    try std.testing.expect(adapter.checkpointsTotal() >= 1);

    // OBSERVABLE 4: the cadence signal is reset — WAL/dirty pressure bounded.
    try std.testing.expectEqual(@as(u64, 0), adapter.pendingBulkOps());
}

test "GAP-0900: deferred-mode time-based checkpoint fires for un-checkpointed bulk merges" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDataDir(allocator, &tmp);
    defer allocator.free(data_dir);

    const adapter = try initDeferredAdapter(allocator, data_dir);
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph("g");

    const store = graph_store.getGlobalStore(graph_store.global_allocator());

    // Far fewer ops than the op threshold, so ONLY the time trigger can fire.
    const checkpoint_ops_threshold: u64 = 100_000;
    const time_threshold_ms: u64 = 60_000;
    const total_ops: usize = 200;

    const empty_props = [_]PropKV{};
    var i: usize = 0;
    while (i < total_ops) : (i += 1) {
        const reserved = store.reserveNodeId();
        // Bulk MERGE fast path (the distinct-key MERGE stream the divelife seed
        // hits). Each distinct merge_value is a fresh upsert.
        _ = try adapter.bulkMergeNodeWithReservedId(
            "g",
            reserved,
            "M", // label (single, not a slice)
            "node_id", // merge_key
            .{ .Int = @intCast(reserved) }, // merge_value (distinct per op)
            &empty_props, // on_create_props
            false, // apply_on_match
        );
    }

    // Bulk merges must have fed the cadence signal (RED today: stays 0).
    try std.testing.expect(adapter.pendingBulkOps() > 0);

    // No checkpoint yet — below op threshold and (now == last) no time elapsed.
    try std.testing.expectEqual(@as(u64, 0), adapter.checkpointsTotal());
    const not_yet = try adapter.maybeCheckpoint(checkpoint_ops_threshold, time_threshold_ms, 0);
    try std.testing.expect(!not_yet);

    // Inject elapsed time past the 60 s cadence — the time trigger must fire
    // because there IS un-checkpointed bulk work.
    const elapsed_ns: u64 = (time_threshold_ms + 1) * std.time.ns_per_ms;
    const fired = try adapter.maybeCheckpoint(checkpoint_ops_threshold, time_threshold_ms, elapsed_ns);
    try std.testing.expect(fired);
    try std.testing.expect(adapter.checkpointsTotal() >= 1);
    try std.testing.expectEqual(@as(u64, 0), adapter.pendingBulkOps());
}
