const std = @import("std");
const graph_store = @import("geode").graph_store;
const pipeline_mod = @import("storage/snapshot_pipeline.zig");

// Helper: record N commits to drive checkpoint cadence.
fn appendCommits(pipe: *pipeline_mod.Pipeline, n: usize) void {
    pipe.recordCommit(n);
}

// TestCANARY_REQ_GQL_083_CheckpointSelection
test "TestCANARY_REQ_GQL_083_CheckpointSelection" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var pipe = pipeline_mod.Pipeline.init(allocator, &store, .{ .checkpoint_interval_override = 3 });
    // Initially should not checkpoint.
    try std.testing.expect(!pipe.shouldCheckpoint());
    appendCommits(&pipe, 2);
    try std.testing.expect(!pipe.shouldCheckpoint());
    appendCommits(&pipe, 1);
    try std.testing.expect(pipe.shouldCheckpoint());
    const res = try pipe.tick();
    try std.testing.expect(res.checkpoint and !res.compacted and !res.archived);
    try std.testing.expect(pipe.last_checkpoint_id > 0);
}

// TestCANARY_REQ_GQL_083_CompactionJob
test "TestCANARY_REQ_GQL_083_CompactionJob" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    // Configure cadence: checkpoint every 2 commits, compact every 2 checkpoints.
    var pipe = pipeline_mod.Pipeline.init(allocator, &store, .{ .checkpoint_interval_override = 2, .compaction_interval = 2 });
    // Emit commits sufficient to trigger two checkpoints -> compaction.
    appendCommits(&pipe, 2); // should trigger first checkpoint on tick
    _ = try pipe.tick();
    appendCommits(&pipe, 2); // second checkpoint
    const res2 = try pipe.tick();
    // After second checkpoint compaction should run (res2.compacted true or segment count reduced)
    try std.testing.expect(res2.checkpoint);
    try std.testing.expect(res2.compacted);
}

// TestCANARY_REQ_GQL_083_ArchivalHook
test "TestCANARY_REQ_GQL_083_ArchivalHook" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var pipe = pipeline_mod.Pipeline.init(allocator, &store, .{ .checkpoint_interval_override = 1, .archival_window = 2 });
    // Two commits -> two checkpoints, archival should fire on second tick (window=2)
    appendCommits(&pipe, 1);
    _ = try pipe.tick();
    const first_archival_id = pipe.last_archival_id;
    try std.testing.expect(first_archival_id == 0); // not yet archived
    appendCommits(&pipe, 1);
    const res = try pipe.tick();
    try std.testing.expect(res.archived);
    try std.testing.expect(pipe.last_archival_id == pipe.last_checkpoint_id);
}
