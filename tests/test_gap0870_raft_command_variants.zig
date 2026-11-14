// GAP-0870: Raft command variants + query transport routing.
//
// Closes the silent log-and-skip behavior for the remaining Raft Command
// variants and the placeholder query-transport message handlers:
//
//   * config_change      → applied to the registered AppliedClusterConfig
//   * snapshot_pointer   → recorded (monotonic) for log truncation
//   * txn_prepare        → routed into the existing 2PC TxnCoordinator
//   * txn_decide         → commits (applies write set) or aborts via TxnCoordinator
//   * alter_graph        → REJECTED at proposal time (validateCommand) and
//                          fails loud at apply time (no ALTER GRAPH semantics)
//   * transport handlers → route to their real counterpart or return
//                          error.NotImplemented through dispatchQueryMessage
//
// KNOWN BLOCKER preserved: the pinned protobuf 0.1.3 cannot encode OR decode
// a TwoPhaseMessage (union-as-submessage @compileError) — the protobuf wire
// path stays gated behind `protobuf_union_submessage_supported` in
// tests/test_txn_coordinator_2pc.zig.  The 2PC APPLY path no longer depends
// on it: write sets use the native G2PC codec
// (txn_coordinator.serializeWriteSet), exercised end-to-end here.

const std = @import("std");
const geode = @import("geode");
const graph_store = geode.graph_store;
const GraphStore = graph_store.GraphStore;
const raft_apply = geode.distributed.raft_apply;
const raft_consensus = geode.distributed.raft_consensus;
const Command = raft_consensus.Command;
const txn_mod = geode.distributed.txn_coordinator;
const TxnCoordinator = txn_mod.TxnCoordinator;

// CANARY: REQ=REQ-DIST-RAFT-CMD-VARIANTS; FEATURE="Raft Command Variants"; ASPECT=IntegrationTest; STATUS=TESTED; TEST=test-gap0870; OWNER=distributed; UPDATED=2026-06-11

// ---------------------------------------------------------------------------
// config_change
// ---------------------------------------------------------------------------

test "config_change: add_server applied to cluster config (observable member)" {
    const allocator = std.testing.allocator;
    var cfg = raft_apply.AppliedClusterConfig.init(allocator);
    defer cfg.deinit();
    raft_apply.setGlobalClusterConfig(&cfg);
    defer raft_apply.resetGlobalClusterConfig();

    const r = try raft_apply.applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .add_server,
        .server_id = 9,
        .server_endpoint = "node9.cluster.local",
        .server_port = 4242,
    } }, 1);
    defer allocator.free(r);

    const m = cfg.getMember(9) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("node9.cluster.local", m.endpoint);
    try std.testing.expectEqual(@as(?u16, 4242), m.port);
    try std.testing.expectEqual(@as(u64, 1), cfg.version);
}

test "config_change: update_server replaces endpoint, remove_server drops member" {
    const allocator = std.testing.allocator;
    var cfg = raft_apply.AppliedClusterConfig.init(allocator);
    defer cfg.deinit();
    raft_apply.setGlobalClusterConfig(&cfg);
    defer raft_apply.resetGlobalClusterConfig();

    const r1 = try raft_apply.applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .add_server,
        .server_id = 5,
        .server_endpoint = "10.0.0.5",
    } }, 1);
    defer allocator.free(r1);

    const r2 = try raft_apply.applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .update_server,
        .server_id = 5,
        .server_endpoint = "10.0.1.5",
        .server_port = 9000,
    } }, 2);
    defer allocator.free(r2);

    const updated = cfg.getMember(5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("10.0.1.5", updated.endpoint);
    try std.testing.expectEqual(@as(?u16, 9000), updated.port);

    const r3 = try raft_apply.applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .remove_server,
        .server_id = 5,
        .server_endpoint = null,
    } }, 3);
    defer allocator.free(r3);
    try std.testing.expect(cfg.getMember(5) == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.memberCount());
}

test "config_change: full wire round-trip (serialize -> deserialize -> apply)" {
    const allocator = std.testing.allocator;
    var cfg = raft_apply.AppliedClusterConfig.init(allocator);
    defer cfg.deinit();
    raft_apply.setGlobalClusterConfig(&cfg);
    defer raft_apply.resetGlobalClusterConfig();

    const cmd = Command{ .config_change = .{
        .change_type = .add_server,
        .server_id = 77,
        .server_endpoint = "wire.example",
        .server_port = 1234,
    } };
    const bytes = try raft_consensus.serializeCommand(allocator, cmd);
    defer allocator.free(bytes);
    const restored = try raft_consensus.deserializeCommand(bytes);

    const r = try raft_apply.applyCommand(allocator, null, restored, 4);
    defer allocator.free(r);

    const m = cfg.getMember(77) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("wire.example", m.endpoint);
}

test "config_change: without registered config fails loud (no silent skip)" {
    const allocator = std.testing.allocator;
    raft_apply.resetGlobalClusterConfig();
    try std.testing.expectError(error.ClusterConfigNotAvailable, raft_apply.applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .add_server,
        .server_id = 1,
        .server_endpoint = "x",
    } }, 1));
}

// ---------------------------------------------------------------------------
// snapshot_pointer
// ---------------------------------------------------------------------------

test "snapshot_pointer: recorded for log truncation and monotonic" {
    const allocator = std.testing.allocator;
    raft_apply.resetSnapshotPointer();
    defer raft_apply.resetSnapshotPointer();
    try std.testing.expect(raft_apply.lastSnapshotPointer() == null);

    const r1 = try raft_apply.applyCommand(allocator, null, .{ .snapshot_pointer = .{
        .last_included_index = 120,
        .last_included_term = 4,
        .size_bytes = 4096,
        .checksum = 0xABCD,
    } }, 1);
    defer allocator.free(r1);

    const sp = raft_apply.lastSnapshotPointer() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 120), sp.last_included_index);
    try std.testing.expectEqual(@as(u64, 4), sp.last_included_term);
    try std.testing.expectEqual(@as(u64, 4096), sp.size_bytes);
    try std.testing.expectEqual(@as(u64, 0xABCD), sp.checksum);

    // Replaying an OLDER pointer (restart log replay) must not regress.
    const r2 = try raft_apply.applyCommand(allocator, null, .{ .snapshot_pointer = .{
        .last_included_index = 60,
        .last_included_term = 3,
        .size_bytes = 1,
        .checksum = 1,
    } }, 2);
    defer allocator.free(r2);
    try std.testing.expectEqual(@as(u64, 120), raft_apply.lastSnapshotPointer().?.last_included_index);

    // A NEWER pointer advances the watermark.
    const r3 = try raft_apply.applyCommand(allocator, null, .{ .snapshot_pointer = .{
        .last_included_index = 200,
        .last_included_term = 5,
        .size_bytes = 8192,
        .checksum = 2,
    } }, 3);
    defer allocator.free(r3);
    try std.testing.expectEqual(@as(u64, 200), raft_apply.lastSnapshotPointer().?.last_included_index);
}

// ---------------------------------------------------------------------------
// txn_prepare / txn_decide — native G2PC write set (see header note)
// ---------------------------------------------------------------------------

/// Build a G2PC write set containing a single node CREATE (default graph,
/// one label) via the real production codec.
fn buildNodeCreateWriteSet(allocator: std.mem.Allocator, node_id: u64, label: []const u8) ![]u8 {
    const ops = [_]txn_mod.WriteSetOp{
        .{ .node_op = .{ .op_type = .create, .node_id = node_id, .label = label } },
    };
    return txn_mod.serializeWriteSet(allocator, &ops);
}

test "txn_prepare: prepared transaction lands in the 2PC table (vote commit)" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();
    var coord = try TxnCoordinator.init(allocator, &store);
    defer coord.deinit();
    raft_apply.setGlobalTxnCoordinator(&coord);
    defer raft_apply.resetGlobalTxnCoordinator();

    const write_set = try buildNodeCreateWriteSet(allocator, 777, "T");
    defer allocator.free(write_set);

    const r = try raft_apply.applyCommand(allocator, null, .{ .txn_prepare = .{
        .xid = 11,
        .shard_id = 0,
        .write_set = write_set,
        .metadata = "",
    } }, 1);
    defer allocator.free(r);

    // Result payload is the vote byte: 1 = VOTE_COMMIT.
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqual(@as(u8, 1), r[0]);

    // Prepared transaction is present in the 2PC table; nothing applied yet.
    try std.testing.expect(coord.prepared_txns.contains(11));
    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());
}

test "txn_decide(commit=true): applies the prepared write set to the store" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();
    var coord = try TxnCoordinator.init(allocator, &store);
    defer coord.deinit();
    raft_apply.setGlobalTxnCoordinator(&coord);
    defer raft_apply.resetGlobalTxnCoordinator();

    const write_set = try buildNodeCreateWriteSet(allocator, 777, "T");
    defer allocator.free(write_set);

    const rp = try raft_apply.applyCommand(allocator, null, .{ .txn_prepare = .{
        .xid = 21,
        .shard_id = 0,
        .write_set = write_set,
        .metadata = "",
    } }, 1);
    defer allocator.free(rp);
    try std.testing.expectEqual(@as(u8, 1), rp[0]);

    const rd = try raft_apply.applyCommand(allocator, null, .{ .txn_decide = .{
        .xid = 21,
        .commit = true,
    } }, 2);
    defer allocator.free(rd);

    // Committed: node 777 exists with label T, prepared table drained.
    const node = store.getNodePtr(777) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), node.labels.len);
    try std.testing.expectEqualStrings("T", node.labels[0]);
    try std.testing.expect(!coord.prepared_txns.contains(21));
}

test "txn_decide(commit=false): aborts without applying" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();
    var coord = try TxnCoordinator.init(allocator, &store);
    defer coord.deinit();
    raft_apply.setGlobalTxnCoordinator(&coord);
    defer raft_apply.resetGlobalTxnCoordinator();

    const write_set = try buildNodeCreateWriteSet(allocator, 888, "T");
    defer allocator.free(write_set);

    const rp = try raft_apply.applyCommand(allocator, null, .{ .txn_prepare = .{
        .xid = 31,
        .shard_id = 0,
        .write_set = write_set,
        .metadata = "",
    } }, 1);
    defer allocator.free(rp);
    try std.testing.expect(coord.prepared_txns.contains(31));

    const rd = try raft_apply.applyCommand(allocator, null, .{ .txn_decide = .{
        .xid = 31,
        .commit = false,
    } }, 2);
    defer allocator.free(rd);

    // Aborted: nothing applied, prepared table drained.
    try std.testing.expect(store.getNodePtr(888) == null);
    try std.testing.expectEqual(@as(usize, 0), store.nodes.count());
    try std.testing.expect(!coord.prepared_txns.contains(31));
}

test "txn_prepare/txn_decide: without registered coordinator fail loud" {
    const allocator = std.testing.allocator;
    raft_apply.resetGlobalTxnCoordinator();
    try std.testing.expectError(error.TxnCoordinatorNotAvailable, raft_apply.applyCommand(allocator, null, .{ .txn_prepare = .{
        .xid = 1,
        .shard_id = 0,
        .write_set = "x",
        .metadata = "",
    } }, 1));
    try std.testing.expectError(error.TxnCoordinatorNotAvailable, raft_apply.applyCommand(allocator, null, .{ .txn_decide = .{
        .xid = 1,
        .commit = true,
    } }, 1));
}

// ---------------------------------------------------------------------------
// alter_graph — rejected at proposal time, fails loud at apply time
// ---------------------------------------------------------------------------

test "alter_graph: rejected at proposal time by validateCommand" {
    try std.testing.expectError(error.UnsupportedSchemaOperation, raft_consensus.validateCommand(.{ .schema_change = .{
        .operation = .alter_graph,
        .graph = "g",
        .schema = "whatever",
    } }));
}

test "alter_graph: apply fails loud instead of silently skipping" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();
    try std.testing.expectError(error.UnsupportedSchemaOperation, raft_apply.applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .alter_graph,
        .graph = "g",
        .schema = "whatever",
    } }, 1));
}

test "proposal-time validation: invalid variants rejected before reaching the log" {
    // add_server without endpoint
    try std.testing.expectError(error.InvalidConfigChange, raft_consensus.validateCommand(.{ .config_change = .{
        .change_type = .add_server,
        .server_id = 1,
        .server_endpoint = null,
    } }));
    // snapshot pointer at index 0 ("no snapshot")
    try std.testing.expectError(error.InvalidSnapshotPointer, raft_consensus.validateCommand(.{ .snapshot_pointer = .{
        .last_included_index = 0,
        .last_included_term = 0,
        .size_bytes = 0,
        .checksum = 0,
    } }));
    // empty 2PC write set
    try std.testing.expectError(error.EmptyWriteSet, raft_consensus.validateCommand(.{ .txn_prepare = .{
        .xid = 1,
        .shard_id = 0,
        .write_set = "",
        .metadata = "",
    } }));
}
