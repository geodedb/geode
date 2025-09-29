// Comprehensive test suite for 2PC distributed transactions
// CANARY: REQ=REQ-GQL-2PC-TEST; FEATURE="2PC Test Suite"; ASPECT=Testing; STATUS=TESTED; TEST=TestCANARY_2PC_Suite; OWNER=test; UPDATED=2025-09-29

const std = @import("std");
const testing = std.testing;
const root = @import("root");
const lib = @import("geode");
const txn_coordinator = lib.distributed.txn_coordinator;
const raft_consensus = lib.distributed.raft_consensus;

test "TestCANARY_2PC_Suite prepare phase success" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    // Test successful prepare
    const prepare = raft_consensus.TxnPrepare{
        .xid = 1001,
        .shard_id = 1,
        .write_set = "key1\nkey2\nkey3",
        .metadata = "test_metadata",
    };

    const can_commit = try coordinator.handlePrepare(prepare);
    try testing.expect(can_commit);
    try testing.expect(coordinator.prepared_txns.contains(1001));
}

test "TestCANARY_2PC_Suite prepare phase conflict" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    // First transaction prepares
    const prepare1 = raft_consensus.TxnPrepare{
        .xid = 2001,
        .shard_id = 1,
        .write_set = "key1\nkey2",
        .metadata = "txn1",
    };

    const can_commit1 = try coordinator.handlePrepare(prepare1);
    try testing.expect(can_commit1);

    // Second transaction conflicts
    const prepare2 = raft_consensus.TxnPrepare{
        .xid = 2002,
        .shard_id = 2,
        .write_set = "key1\nkey3", // key1 conflicts
        .metadata = "txn2",
    };

    const can_commit2 = try coordinator.handlePrepare(prepare2);
    try testing.expect(!can_commit2); // Should fail due to conflict
}

test "TestCANARY_2PC_Suite commit decision" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    // Prepare transaction
    const prepare = raft_consensus.TxnPrepare{
        .xid = 3001,
        .shard_id = 1,
        .write_set = "key1\nkey2",
        .metadata = "commit_test",
    };

    _ = try coordinator.handlePrepare(prepare);
    try testing.expect(coordinator.prepared_txns.contains(3001));

    // Commit decision
    const decide = raft_consensus.TxnDecide{
        .xid = 3001,
        .commit = true,
    };

    try coordinator.handleDecide(decide);
    try testing.expect(!coordinator.prepared_txns.contains(3001)); // Should be cleaned up
}

test "TestCANARY_2PC_Suite abort decision" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    // Prepare transaction
    const prepare = raft_consensus.TxnPrepare{
        .xid = 4001,
        .shard_id = 1,
        .write_set = "key1",
        .metadata = "abort_test",
    };

    _ = try coordinator.handlePrepare(prepare);

    // Abort decision
    const decide = raft_consensus.TxnDecide{
        .xid = 4001,
        .commit = false,
    };

    try coordinator.handleDecide(decide);
    try testing.expect(!coordinator.prepared_txns.contains(4001));
    try testing.expect(coordinator.lock_table.count() == 0); // Locks should be released
}

test "TestCANARY_2PC_Suite timeout handling" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    coordinator.timeout_ms = 1; // Very short timeout for testing

    // Prepare transaction
    const prepare = raft_consensus.TxnPrepare{
        .xid = 5001,
        .shard_id = 1,
        .write_set = "key1",
        .metadata = "timeout_test",
    };

    _ = try coordinator.handlePrepare(prepare);

    // Wait and check timeout
    std.time.sleep(5 * std.time.ns_per_ms);
    try coordinator.checkTimeouts();

    try testing.expect(!coordinator.prepared_txns.contains(5001)); // Should be auto-aborted
}

test "TestCANARY_2PC_Suite concurrent transactions" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    // Prepare multiple non-conflicting transactions
    const txns = [_]raft_consensus.TxnPrepare{
        .{ .xid = 6001, .shard_id = 1, .write_set = "key1\nkey2", .metadata = "txn1" },
        .{ .xid = 6002, .shard_id = 2, .write_set = "key3\nkey4", .metadata = "txn2" },
        .{ .xid = 6003, .shard_id = 3, .write_set = "key5\nkey6", .metadata = "txn3" },
    };

    for (txns) |prepare| {
        const can_commit = try coordinator.handlePrepare(prepare);
        try testing.expect(can_commit);
    }

    try testing.expect(coordinator.prepared_txns.count() == 3);

    // Commit all
    for (txns) |prepare| {
        const decide = raft_consensus.TxnDecide{
            .xid = prepare.xid,
            .commit = true,
        };
        try coordinator.handleDecide(decide);
    }

    try testing.expect(coordinator.prepared_txns.count() == 0);
}

test "TestCANARY_2PC_Suite idempotence" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    const prepare = raft_consensus.TxnPrepare{
        .xid = 7001,
        .shard_id = 1,
        .write_set = "key1",
        .metadata = "idempotent",
    };

    // First prepare
    const result1 = try coordinator.handlePrepare(prepare);
    try testing.expect(result1);

    // Duplicate decide should be idempotent
    const decide = raft_consensus.TxnDecide{
        .xid = 7001,
        .commit = true,
    };

    try coordinator.handleDecide(decide);
    try coordinator.handleDecide(decide); // Second call should be safe

    try testing.expect(!coordinator.prepared_txns.contains(7001));
}

test "TestCANARY_2PC_Suite large write set" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    // Create large write set
    var write_set = std.ArrayList(u8).init(allocator);
    defer write_set.deinit();

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try write_set.writer().print("key_{}\n", .{i});
    }

    const prepare = raft_consensus.TxnPrepare{
        .xid = 8001,
        .shard_id = 1,
        .write_set = write_set.items,
        .metadata = "large_write_set",
    };

    const can_commit = try coordinator.handlePrepare(prepare);
    try testing.expect(can_commit);
    try testing.expect(coordinator.lock_table.count() == 1000);
}

test "TestCANARY_2PC_Suite mixed operations" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    // Prepare, abort, prepare again with same keys
    const prepare1 = raft_consensus.TxnPrepare{
        .xid = 9001,
        .shard_id = 1,
        .write_set = "key1\nkey2",
        .metadata = "first",
    };

    _ = try coordinator.handlePrepare(prepare1);

    // Abort first transaction
    try coordinator.handleDecide(.{ .xid = 9001, .commit = false });

    // Now same keys should be available
    const prepare2 = raft_consensus.TxnPrepare{
        .xid = 9002,
        .shard_id = 1,
        .write_set = "key1\nkey2",
        .metadata = "second",
    };

    const can_commit = try coordinator.handlePrepare(prepare2);
    try testing.expect(can_commit);
}

test "TestCANARY_2PC_Suite stress test" {
    const allocator = testing.allocator;

    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();

    // Rapid prepare/commit cycles
    var xid: u64 = 10000;
    var cycles: u32 = 0;
    while (cycles < 100) : (cycles += 1) {
        xid += 1;

        const prepare = raft_consensus.TxnPrepare{
            .xid = xid,
            .shard_id = @intCast(cycles % 10),
            .write_set = try std.fmt.allocPrint(allocator, "key_{}", .{cycles}),
            .metadata = "stress",
        };
        defer allocator.free(prepare.write_set);

        _ = try coordinator.handlePrepare(prepare);
        try coordinator.handleDecide(.{ .xid = xid, .commit = cycles % 2 == 0 });
    }

    try testing.expect(coordinator.prepared_txns.count() == 0);
}
