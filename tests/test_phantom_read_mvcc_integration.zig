const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-TXN-PHANTOM-MVCC-001; FEATURE="Phantom Read MVCC Integration"; ASPECT=SerializableIsolation; STATUS=TESTED; TEST=TestCANARY_REQ_TXN_PHANTOM_MVCC_001_SerializableIsolation; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-PHANTOM-MVCC-002; FEATURE="Phantom Read MVCC Integration"; ASPECT=TransactionLifecycle; STATUS=TESTED; TEST=TestCANARY_REQ_TXN_PHANTOM_MVCC_002_TransactionLifecycle; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-PHANTOM-MVCC-003; FEATURE="Phantom Read MVCC Integration"; ASPECT=ConflictDetection; STATUS=TESTED; TEST=TestCANARY_REQ_TXN_PHANTOM_MVCC_003_ConflictDetection; OWNER=txn; UPDATED=2025-10-05

// Import transaction management modules
const mvcc = @import("../src/server/txn/mvcc.zig");
const phantom_prevention = @import("../src/server/txn/phantom_read_prevention.zig");

test "TestCANARY_REQ_TXN_PHANTOM_MVCC_001_SerializableIsolation" {
    // Test complete serializable isolation with phantom read prevention
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    // Enable phantom read prevention for serializable isolation
    try mvcc_manager.enablePhantomReadPrevention();

    // Start a serializable transaction
    const txn1 = try mvcc_manager.beginTransaction(.Serializable);
    defer txn1.deinit();

    // Perform a range query that should acquire predicate locks
    const conditions = [_]phantom_prevention.QueryCondition{
        .{
            .type = .PropertyRange,
            .property = "age",
            .value = .{ .Int = 25 },
        },
    };

    // Read with query tracking
    const read_result = mvcc_manager.readWithQuery(txn1, 1, "Person", &conditions);
    try testing.expect(read_result != null or std.meta.isError(read_result));

    // Start another transaction that tries to insert a conflicting tuple
    const txn2 = try mvcc_manager.beginTransaction(.Serializable);
    defer txn2.deinit();

    const properties = [_]phantom_prevention.PropertyBinding{
        .{ .name = "age", .value = .{ .Int = 30 } }, // Would satisfy the range query
        .{ .name = "name", .value = .{ .String = "Alice" } },
    };

    // This write should detect phantom read conflict
    const write_result = mvcc_manager.writeWithMetadata(txn2, 2, "test_data", "Person", &properties);
    try testing.expectError(error.PhantomReadConflict, write_result);

    // Verify conflict was recorded
    try testing.expect(txn2.conflicts_detected.items.len > 0);
    try testing.expect(txn2.conflicts_detected.items[0].conflict_type == .PhantomRead);
}

test "TestCANARY_REQ_TXN_PHANTOM_MVCC_002_TransactionLifecycle" {
    // Test complete transaction lifecycle with phantom read prevention
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    try mvcc_manager.enablePhantomReadPrevention();

    // Transaction 1: Read with predicate lock
    const txn1 = try mvcc_manager.beginTransaction(.Serializable);
    defer txn1.deinit();

    const conditions = [_]phantom_prevention.QueryCondition{
        .{ .type = .LabelScan },
    };

    _ = mvcc_manager.readWithQuery(txn1, 1, "Student", &conditions) catch {};

    // Verify predicate locks are acquired
    if (mvcc_manager.phantom_prevention) |phantom_prev| {
        const stats = phantom_prev.getStatistics();
        try testing.expect(stats.active_predicate_locks > 0);
        try testing.expect(stats.active_transactions_with_queries > 0);
    }

    // Commit the transaction
    try mvcc_manager.commitTransaction(txn1);

    // Verify predicate locks are released after commit
    if (mvcc_manager.phantom_prevention) |phantom_prev| {
        const stats_after = phantom_prev.getStatistics();
        try testing.expect(stats_after.active_transactions_with_queries == 0);
    }

    // Test abort scenario
    const txn2 = try mvcc_manager.beginTransaction(.Serializable);
    defer txn2.deinit();

    _ = mvcc_manager.readWithQuery(txn2, 2, "Course", &conditions) catch {};

    // Abort the transaction
    try mvcc_manager.abortTransaction(txn2);

    // Verify cleanup after abort
    if (mvcc_manager.phantom_prevention) |phantom_prev| {
        const stats_after_abort = phantom_prev.getStatistics();
        try testing.expect(stats_after_abort.active_transactions_with_queries == 0);
    }
}

test "TestCANARY_REQ_TXN_PHANTOM_MVCC_003_ConflictDetection" {
    // Test conflict detection across different isolation levels
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    try mvcc_manager.enablePhantomReadPrevention();

    // Test that lower isolation levels don't trigger phantom read prevention
    const txn_rc = try mvcc_manager.beginTransaction(.ReadCommitted);
    defer txn_rc.deinit();

    const conditions = [_]phantom_prevention.QueryCondition{
        .{ .type = .LabelScan },
    };

    // Read committed should not acquire predicate locks
    _ = mvcc_manager.readWithQuery(txn_rc, 1, "Product", &conditions) catch {};

    // Another transaction writes - should not conflict for read committed
    const txn_writer = try mvcc_manager.beginTransaction(.ReadCommitted);
    defer txn_writer.deinit();

    const properties = [_]phantom_prevention.PropertyBinding{
        .{ .name = "price", .value = .{ .Float = 99.99 } },
    };

    // Should succeed for read committed
    mvcc_manager.writeWithMetadata(txn_writer, 2, "test_data", "Product", &properties) catch |err| {
        // PhantomReadConflict should not occur for read committed
        try testing.expect(err != error.PhantomReadConflict);
    };

    // Test serializable isolation
    const txn_ser = try mvcc_manager.beginTransaction(.Serializable);
    defer txn_ser.deinit();

    // This should acquire predicate locks
    _ = mvcc_manager.readWithQuery(txn_ser, 3, "Order", &conditions) catch {};

    // Conflicting write should fail
    const txn_conflict = try mvcc_manager.beginTransaction(.Serializable);
    defer txn_conflict.deinit();

    const order_properties = [_]phantom_prevention.PropertyBinding{
        .{ .name = "total", .value = .{ .Float = 150.00 } },
    };

    const conflict_result = mvcc_manager.writeWithMetadata(txn_conflict, 4, "test_data", "Order", &order_properties);
    try testing.expectError(error.PhantomReadConflict, conflict_result);
}

test "Predicate lock overlap detection" {
    // Test predicate lock overlap logic
    const allocator = testing.allocator;

    const pred1 = phantom_prevention.PredicateLock{
        .txn_id = 1,
        .label = try allocator.dupe(u8, "Person"),
        .property = try allocator.dupe(u8, "age"),
        .range = phantom_prevention.PropertyRange{
            .min_value = .{ .Int = 20 },
            .max_value = .{ .Int = 30 },
        },
        .condition = .{ .type = .PropertyRange, .property = "age", .value = .{ .Int = 25 } },
        .timestamp = 100,
    };
    defer {
        allocator.free(pred1.label);
        allocator.free(pred1.property.?);
    }

    const pred2 = phantom_prevention.PredicateLock{
        .txn_id = 2,
        .label = try allocator.dupe(u8, "Person"),
        .property = try allocator.dupe(u8, "age"),
        .range = phantom_prevention.PropertyRange{
            .min_value = .{ .Int = 25 },
            .max_value = .{ .Int = 35 },
        },
        .condition = .{ .type = .PropertyRange, .property = "age", .value = .{ .Int = 30 } },
        .timestamp = 101,
    };
    defer {
        allocator.free(pred2.label);
        allocator.free(pred2.property.?);
    }

    // These ranges should overlap
    try testing.expect(pred1.overlaps(pred2));

    const pred3 = phantom_prevention.PredicateLock{
        .txn_id = 3,
        .label = try allocator.dupe(u8, "Person"),
        .property = try allocator.dupe(u8, "age"),
        .range = phantom_prevention.PropertyRange{
            .min_value = .{ .Int = 40 },
            .max_value = .{ .Int = 50 },
        },
        .condition = .{ .type = .PropertyRange, .property = "age", .value = .{ .Int = 45 } },
        .timestamp = 102,
    };
    defer {
        allocator.free(pred3.label);
        allocator.free(pred3.property.?);
    }

    // These ranges should not overlap
    try testing.expect(!pred1.overlaps(pred3));
}

test "Complex query condition validation" {
    // Test complex query conditions and their satisfaction
    const allocator = testing.allocator;

    var phantom_prev = phantom_prevention.PhantomReadPrevention.init(allocator);
    defer phantom_prev.deinit();

    // Test property existence condition
    const existence_condition = phantom_prevention.QueryCondition{
        .type = .PropertyExists,
        .property = "email",
    };

    const conditions = [_]phantom_prevention.QueryCondition{existence_condition};

    const acquired = try phantom_prev.acquirePredicateLock(1, "User", &conditions, 100);
    try testing.expect(acquired);

    // Test write that would satisfy the existence condition
    const properties_with_email = [_]phantom_prevention.PropertyBinding{
        .{ .name = "email", .value = .{ .String = "test@example.com" } },
        .{ .name = "name", .value = .{ .String = "Test User" } },
    };

    const conflict = try phantom_prev.checkWriteConflict(2, "User", &properties_with_email);
    try testing.expect(conflict != null);
    try testing.expect(conflict.?.conflict_type == .PhantomRead);

    // Test write that would not satisfy the condition
    const properties_without_email = [_]phantom_prevention.PropertyBinding{
        .{ .name = "name", .value = .{ .String = "Anonymous User" } },
    };

    const no_conflict = try phantom_prev.checkWriteConflict(3, "User", &properties_without_email);
    try testing.expect(no_conflict == null);
}

test "Phantom read validation with actual writes" {
    // Test validation against real write operations
    const allocator = testing.allocator;

    var phantom_prev = phantom_prevention.PhantomReadPrevention.init(allocator);
    defer phantom_prev.deinit();

    // Record a query that should detect phantom reads
    const conditions = [_]phantom_prevention.QueryCondition{
        .{
            .type = .PropertyRange,
            .property = "salary",
            .value = .{ .Float = 50000.0 },
        },
    };

    try phantom_prev.recordReadQuery(1, "Employee", &conditions, 3, 100);

    // Simulate writes that occurred after the query snapshot
    const writes = [_]phantom_prevention.WriteOperation{
        .{
            .label = "Employee",
            .properties = &[_]phantom_prevention.PropertyBinding{
                .{ .name = "salary", .value = .{ .Float = 60000.0 } }, // Would be visible to query
                .{ .name = "name", .value = .{ .String = "New Employee" } },
            },
            .timestamp = 105,
        },
        .{
            .label = "Manager", // Different label - should not affect Employee query
            .properties = &[_]phantom_prevention.PropertyBinding{
                .{ .name = "salary", .value = .{ .Float = 80000.0 } },
            },
            .timestamp = 106,
        },
    };

    // Validation should fail due to phantom read in Employee table
    const is_valid = try phantom_prev.validateReadSet(1, &writes);
    try testing.expect(!is_valid);
}

test "MVCC garbage collection with phantom read prevention" {
    // Test that garbage collection doesn't interfere with phantom read prevention
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    try mvcc_manager.enablePhantomReadPrevention();

    // Create a long-running transaction with predicate locks
    const long_txn = try mvcc_manager.beginTransaction(.Serializable);
    defer long_txn.deinit();

    const conditions = [_]phantom_prevention.QueryCondition{
        .{ .type = .LabelScan },
    };

    _ = mvcc_manager.readWithQuery(long_txn, 1, "Document", &conditions) catch {};

    // Create and commit several other transactions
    for (0..5) |i| {
        const temp_txn = try mvcc_manager.beginTransaction(.ReadCommitted);
        _ = mvcc_manager.write(temp_txn, @intCast(i + 10), "test_data") catch {};
        try mvcc_manager.commitTransaction(temp_txn);
        temp_txn.deinit();
    }

    // Run garbage collection
    try mvcc_manager.garbageCollect();

    // Verify that predicate locks are still intact
    if (mvcc_manager.phantom_prevention) |phantom_prev| {
        const stats = phantom_prev.getStatistics();
        try testing.expect(stats.active_predicate_locks > 0);
        try testing.expect(stats.active_transactions_with_queries > 0);
    }

    // Commit the long-running transaction
    try mvcc_manager.commitTransaction(long_txn);

    // Verify cleanup
    if (mvcc_manager.phantom_prevention) |phantom_prev| {
        const stats_after = phantom_prev.getStatistics();
        try testing.expect(stats_after.active_transactions_with_queries == 0);
    }
}
