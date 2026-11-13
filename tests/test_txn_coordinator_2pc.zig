// Standalone 2PC coordinator tests for src/distributed/txn_coordinator.zig.
//
// MOVED here (2026-06-10) out of txn_coordinator.zig's inline `test` blocks so
// they are NOT pulled into the `graph_store_unit_tests` test root (which
// transitively imports txn_coordinator via
// graph_store -> fle_integration -> execution -> raft_consensus).
//
// SONNY-6484: all four tests used to skip (`error.SkipZigTest` behind a
// comptime `protobuf_union_submessage_supported = false` flag). They encoded
// their write sets as a protobuf `distributed_schema.TwoPhaseMessage`, which
// the pinned protobuf library cannot encode (a union as a repeated
// submessage), and since GAP-0870 the coordinator does not accept that format
// at all: `handlePrepare` decodes only the native G2PC write set
// (`txn_coordinator.serializeWriteSet`) and votes abort on anything else. No
// code path produces a protobuf TwoPhaseMessage. The tests now build G2PC
// write sets and run: prepare/commit, a conflicting prepare voting abort, a
// multi-node write set applied, and a delete applied.
//
// CANARY: REQ=REQ-GQL-2PC-002; FEATURE="Distributed Transaction Coordinator"; ASPECT=2PC; STATUS=TESTED; TEST=TestCANARY_2PC_Coordinator; OWNER=distributed; UPDATED=2026-11-13
// CANARY: REQ=REQ-GQL-2PC-003; FEATURE="2PC Idempotence"; ASPECT=2PC; STATUS=TESTED; TEST=TestCANARY_2PC_Idempotent; OWNER=distributed; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");

const txn_coordinator = geode.distributed.txn_coordinator;
const TxnCoordinator = txn_coordinator.TxnCoordinator;
const WriteSetOp = txn_coordinator.WriteSetOp;
const graph_store = geode.graph_store;

fn nodeOp(op_type: txn_coordinator.WriteOpType, node_id: u64, label: []const u8, props: []const txn_coordinator.Prop) WriteSetOp {
    return .{ .node_op = .{
        .op_type = op_type,
        .node_id = node_id,
        .label = label,
        .graph = graph_store.DEFAULT_GRAPH_NAME,
        .props = props,
    } };
}

test "TestCANARY_2PC_Coordinator basic prepare and commit" {
    const allocator = std.testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var coordinator = try TxnCoordinator.init(allocator, &store);
    defer coordinator.deinit();

    const props = [_]txn_coordinator.Prop{.{ .key = "name", .value = .{ .String = "Alice" } }};
    const write_set = try txn_coordinator.serializeWriteSet(allocator, &.{nodeOp(.create, 1, "User", &props)});
    defer allocator.free(write_set);

    try std.testing.expect(try coordinator.handlePrepare(.{ .xid = 1, .shard_id = 0, .write_set = write_set, .metadata = "test" }));
    // Prepared, not applied.
    try std.testing.expect(store.getNodePtr(1) == null);

    try coordinator.handleDecide(.{ .xid = 1, .commit = true });

    try std.testing.expect(store.getNodePtr(1) != null);
    const name_prop = store.getNodeProperty(1, "name") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Alice", name_prop.String);
    try std.testing.expect(!coordinator.prepared_txns.contains(1));
}

test "TestCANARY_2PC_Idempotent repeated prepare" {
    const allocator = std.testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var coordinator = try TxnCoordinator.init(allocator, &store);
    defer coordinator.deinit();

    const write_set = try txn_coordinator.serializeWriteSet(allocator, &.{nodeOp(.create, 42, "LockNode", &.{})});
    defer allocator.free(write_set);

    try std.testing.expect(try coordinator.handlePrepare(.{ .xid = 1, .shard_id = 0, .write_set = write_set, .metadata = "test" }));
    // The same xid again (a restart replaying the log) re-votes commit.
    try std.testing.expect(try coordinator.handlePrepare(.{ .xid = 1, .shard_id = 0, .write_set = write_set, .metadata = "test" }));
    // Another xid on the same node conflicts with the held lock: abort.
    try std.testing.expect(!try coordinator.handlePrepare(.{ .xid = 2, .shard_id = 0, .write_set = write_set, .metadata = "test" }));

    // Once xid 1 is decided, the lock is free again.
    try coordinator.handleDecide(.{ .xid = 1, .commit = false });
    try std.testing.expect(store.getNodePtr(42) == null);
    try std.testing.expect(try coordinator.handlePrepare(.{ .xid = 2, .shard_id = 0, .write_set = write_set, .metadata = "test" }));
}

test "TestCANARY_2PC_WriteSetApplied verifies data is persisted" {
    const allocator = std.testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var coordinator = try TxnCoordinator.init(allocator, &store);
    defer coordinator.deinit();

    const alice = [_]txn_coordinator.Prop{.{ .key = "name", .value = .{ .String = "Alice Smith" } }};
    const bob = [_]txn_coordinator.Prop{.{ .key = "name", .value = .{ .String = "Bob Jones" } }};
    const write_set = try txn_coordinator.serializeWriteSet(allocator, &.{
        nodeOp(.create, 10, "User", &alice),
        nodeOp(.create, 11, "User", &bob),
    });
    defer allocator.free(write_set);

    try std.testing.expect(try coordinator.handlePrepare(.{ .xid = 100, .shard_id = 0, .write_set = write_set, .metadata = "test_persistence" }));
    try coordinator.handleDecide(.{ .xid = 100, .commit = true });

    const a = store.getNodeProperty(10, "name") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Alice Smith", a.String);
    const b = store.getNodeProperty(11, "name") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Bob Jones", b.String);
}

test "TestCANARY_2PC_WriteSetDelete verifies delete operations" {
    const allocator = std.testing.allocator;

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var coordinator = try TxnCoordinator.init(allocator, &store);
    defer coordinator.deinit();

    const create = try txn_coordinator.serializeWriteSet(allocator, &.{nodeOp(.create, 55, "Temp", &.{})});
    defer allocator.free(create);
    try std.testing.expect(try coordinator.handlePrepare(.{ .xid = 200, .shard_id = 0, .write_set = create, .metadata = "insert" }));
    try coordinator.handleDecide(.{ .xid = 200, .commit = true });
    try std.testing.expect(store.getNodePtr(55) != null);

    const delete = try txn_coordinator.serializeWriteSet(allocator, &.{nodeOp(.delete, 55, "Temp", &.{})});
    defer allocator.free(delete);
    try std.testing.expect(try coordinator.handlePrepare(.{ .xid = 201, .shard_id = 0, .write_set = delete, .metadata = "delete" }));
    try coordinator.handleDecide(.{ .xid = 201, .commit = true });
    try std.testing.expect(store.getNodePtr(55) == null);
}
