const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const PropertyValue = graph_store.PropertyValue;
const raft_apply = geode.distributed.raft_apply;
const raft_consensus = geode.distributed.raft_consensus;
const Command = raft_consensus.Command;

// CANARY: REQ=REQ-GQL-RAFT-APPLY; FEATURE="Raft Apply Callback"; ASPECT=IntegrationTest; STATUS=TESTED; TEST=test_raft_apply; OWNER=distributed; UPDATED=2026-04-09

test "noop command returns empty result" {
    const allocator = std.testing.allocator;
    const result = try raft_apply.applyCommand(allocator, null, .noop);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "write command returns empty result (MVP)" {
    const allocator = std.testing.allocator;
    const result = try raft_apply.applyCommand(allocator, null, .{ .write = "key=value" });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "unhandled command types return empty without error" {
    const allocator = std.testing.allocator;

    // config_change
    const r1 = try raft_apply.applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .add_server,
        .server_id = 42,
        .server_endpoint = "10.0.0.1",
    } });
    defer allocator.free(r1);
    try std.testing.expectEqual(@as(usize, 0), r1.len);

    // snapshot_pointer
    const r2 = try raft_apply.applyCommand(allocator, null, .{ .snapshot_pointer = .{
        .last_included_index = 1,
        .last_included_term = 1,
        .size_bytes = 0,
        .checksum = 0,
    } });
    defer allocator.free(r2);
    try std.testing.expectEqual(@as(usize, 0), r2.len);

    // txn_prepare
    const r3 = try raft_apply.applyCommand(allocator, null, .{ .txn_prepare = .{
        .xid = 1,
        .shard_id = 0,
        .write_set = "",
        .metadata = "",
    } });
    defer allocator.free(r3);
    try std.testing.expectEqual(@as(usize, 0), r3.len);

    // txn_decide
    const r4 = try raft_apply.applyCommand(allocator, null, .{ .txn_decide = .{
        .xid = 1,
        .commit = true,
    } });
    defer allocator.free(r4);
    try std.testing.expectEqual(@as(usize, 0), r4.len);
}

test "graph_mutation create with store creates node and returns node ID" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const result = try raft_apply.applyCommand(allocator, &store, .{ .graph_mutation = .{
        .graph = "raft_test",
        .mutation_type = .create,
        .data = "test_payload",
        .txn_id = null,
    } });
    defer allocator.free(result);

    // Result is a u64 node ID
    try std.testing.expectEqual(@as(usize, 8), result.len);
    const node_id = std.mem.readInt(u64, result[0..8], .little);
    try std.testing.expect(node_id > 0);

    // Graph was implicitly created
    try std.testing.expect(store.graphs.contains("raft_test"));
}

test "graph_mutation without store returns StoreNotAvailable" {
    const allocator = std.testing.allocator;
    const result = raft_apply.applyCommand(allocator, null, .{ .graph_mutation = .{
        .graph = "orphan",
        .mutation_type = .create,
        .data = "",
        .txn_id = null,
    } });
    try std.testing.expectError(error.StoreNotAvailable, result);
}

test "schema_change create_graph then drop_graph" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // create
    const r1 = try raft_apply.applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "ephemeral",
        .schema = "",
    } });
    defer allocator.free(r1);
    try std.testing.expect(store.graphs.contains("ephemeral"));

    // drop
    const r2 = try raft_apply.applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .drop_graph,
        .graph = "ephemeral",
        .schema = "",
    } });
    defer allocator.free(r2);
    try std.testing.expect(!store.graphs.contains("ephemeral"));
}

test "global store set/get/reset round-trip" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(?*GraphStore, null), raft_apply.getGlobalStore());

    raft_apply.setGlobalStore(&store);
    try std.testing.expectEqual(@as(?*GraphStore, &store), raft_apply.getGlobalStore());

    raft_apply.resetGlobalStore();
    try std.testing.expectEqual(@as(?*GraphStore, null), raft_apply.getGlobalStore());
}

test "applyCallbackFn works via module-level g_store" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    raft_apply.setGlobalStore(&store);
    defer raft_apply.resetGlobalStore();

    const result = try raft_apply.applyCallbackFn(allocator, .noop);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
