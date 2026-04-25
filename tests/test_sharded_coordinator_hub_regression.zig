// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Hub-node concurrent-edge regression: 16 threads × 50 edges into
//! one hub. Pre-restoration this cascaded to 40001; post-restoration
//! the deterministic source-id routing ensures all edges land on
//! the same (source's) shard thread, eliminating same-resource
//! writer contention.

// CANARY: REQ=REQ-PERF-SHARD-COORD-HUB; FEATURE="ShardedCoordinatorHubRegression"; ASPECT=MVCCContention; STATUS=TESTED; TEST=tests/test_sharded_coordinator_hub_regression.zig; OWNER=perf; UPDATED=2026-04-25

const std = @import("std");
const geode = @import("geode");
const adapter_mod = geode.graph_storage_adapter;
const group_commit = geode.group_commit;

const Ctx = struct {
    coord: *group_commit.ShardedCoordinator,
    hub_id: u64,
    source_ids: []const u64,
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn worker(ctx_ptr: *anyopaque) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_ptr));
    for (ctx.source_ids) |sid| {
        var op = group_commit.ApplyOp{ .bulk_insert_edge = .{
            .source_id = sid,
            .target_id = ctx.hub_id,
            .rel_type = "MEMBER_OF",
            .props = &.{},
            .result = .{},
        } };
        _ = ctx.coord.submit(&op) catch {
            ctx.err.store(1, .release);
            ctx.done.store(1, .release);
            return;
        };
    }
    ctx.done.store(1, .release);
}

test "hub-node concurrent edge creation does not trigger SerializationFailure" {
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
    _ = try adapter.getOrCreateGraph("g_hub");

    group_commit.setEnabledForTest(true);
    defer {
        group_commit.setEnabledForTest(false);
        group_commit.shutdownAllCoordinators();
    }

    const coord = try group_commit.getOrStartCoordinator(allocator, adapter, "g_hub");

    // Create one hub node.
    const hub_labels = [_][]const u8{"Group"};
    var hub_op = group_commit.ApplyOp{ .bulk_insert_node = .{
        .labels = &hub_labels,
        .props = &.{},
        .result = .{},
    } };
    const hub_id = try coord.submit(&hub_op);
    try std.testing.expect(hub_id != 0);

    // Create 16 × 50 = 800 source nodes (one per edge).
    var source_ids: [16 * 50]u64 = undefined;
    const member_labels = [_][]const u8{"Member"};
    for (&source_ids) |*sid| {
        var op = group_commit.ApplyOp{ .bulk_insert_node = .{
            .labels = &member_labels,
            .props = &.{},
            .result = .{},
        } };
        sid.* = try coord.submit(&op);
    }

    // Fan out 16 worker threads, each submitting 50 edges into the hub.
    var ctxs: [16]Ctx = undefined;
    var threads: [16]std.Thread = undefined;
    for (&ctxs, 0..) |*c, i| {
        c.* = .{
            .coord = coord,
            .hub_id = hub_id,
            .source_ids = source_ids[i * 50 .. (i + 1) * 50],
        };
        threads[i] = try std.Thread.spawn(.{}, worker, .{@as(*anyopaque, @ptrCast(c))});
    }
    for (threads) |t| t.join();

    for (&ctxs) |*c| try std.testing.expectEqual(@as(u32, 0), c.err.load(.acquire));
}
