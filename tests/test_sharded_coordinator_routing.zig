// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Routing correctness: an op lands on the shard whose index matches
//! `shardIndex(op.shardKey())`.

const std = @import("std");
const geode = @import("geode");
const graph_storage = @import("graph_storage");
const adapter_mod = geode.graph_storage_adapter;
const group_commit = geode.group_commit;

test "ShardedCoordinator routes ops by shardIndex(shardKey)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(data_dir);

    var adapter = try adapter_mod.StorageAdapter.init(allocator, data_dir, .{
        .data_dir = data_dir,
        .encryption_key = null,
    });
    defer adapter.deinit();
    _ = try adapter.getOrCreateGraph("g_route");

    group_commit.setEnabledForTest(true);
    defer {
        group_commit.setEnabledForTest(false);
        group_commit.shutdownAllCoordinators();
    }

    const coord = try group_commit.getOrStartCoordinator(allocator, adapter, "g_route");

    // Submit one `bulk_insert_node` op; it is applied synchronously
    // by whichever shard its assigned id routes to. Observe that
    // shard's `ops_applied` atomic incremented, and assert the
    // shard index matches `shardIndex(returned_id)`.
    const labels = [_][]const u8{"L"};
    const props = [_]adapter_mod.StorageAdapter.PropKV{};
    var op = group_commit.ApplyOp{ .bulk_insert_node = .{
        .labels = &labels,
        .props = &props,
        .result = .{},
    } };
    const id = try coord.submit(&op);
    try std.testing.expect(id != 0);

    var seen_on_shard: ?usize = null;
    for (0..graph_storage.sharded_store.SHARD_COUNT) |s| {
        const n = coord.shardOpsAppliedForTest(s);
        if (n > 0) {
            try std.testing.expect(seen_on_shard == null);
            seen_on_shard = s;
        }
    }
    try std.testing.expect(seen_on_shard != null);
    try std.testing.expectEqual(
        graph_storage.sharded_store.shardIndex(id),
        seen_on_shard.?,
    );
}
