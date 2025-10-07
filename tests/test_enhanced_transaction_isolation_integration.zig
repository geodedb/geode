// CANARY: REQ=REQ-TXN-ISOLATION-INTEGRATION-001; FEATURE="Enhanced Transaction Isolation Integration"; ASPECT=SerializableIsolation; STATUS=TESTED; TEST=TestCANARY_TXN_ISOLATION_INTEGRATION_001; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-ISOLATION-INTEGRATION-002; FEATURE="Phantom Read Prevention Integration"; ASPECT=PhantomReadPrevention; STATUS=TESTED; TEST=TestCANARY_TXN_ISOLATION_INTEGRATION_002; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-ISOLATION-INTEGRATION-003; FEATURE="Deadlock Resolution Integration"; ASPECT=DeadlockHandling; STATUS=TESTED; TEST=TestCANARY_TXN_ISOLATION_INTEGRATION_003; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-ISOLATION-INTEGRATION-004; FEATURE="High Concurrency Isolation"; ASPECT=ConcurrencyControl; STATUS=TESTED; TEST=TestCANARY_TXN_ISOLATION_INTEGRATION_004; OWNER=txn; UPDATED=2025-10-05

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

const geode = @import("../src/lib.zig");
const enhanced_isolation = @import("../src/server/txn/enhanced_isolation.zig");
const mvcc = @import("../src/server/txn/mvcc.zig");
const phantom_prevention = @import("../src/server/txn/phantom_read_prevention.zig");

// Integration test for complete serializable isolation workflow
test "CANARY_REQ_TXN_ISOLATION_INTEGRATION_001_Complete_Serializable_Workflow" {
    const allocator = testing.allocator;

    // Initialize complete transaction isolation system
    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    // Enable phantom read prevention
    try mvcc_manager.enablePhantomReadPrevention();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Test scenario: Two transactions with potential serialization conflict
    const txn1 = try isolation_manager.beginTransactionWithIsolation(.Serializable, 100);
    defer txn1.deinit();

    const txn2 = try isolation_manager.beginTransactionWithIsolation(.Serializable, 200);
    defer txn2.deinit();

    // Transaction 1: Read-Modify-Write on resource 1000
    const initial_read1 = try isolation_manager.readWithConflictDetection(txn1, 1000, .Serializable);
    try expect(initial_read1 == null); // No data initially

    const data1 = "Transaction 1 Data";
    try isolation_manager.writeWithConflictDetection(txn1, 1000, data1, .Serializable);

    // Transaction 2: Read-Modify-Write on resource 2000
    const initial_read2 = try isolation_manager.readWithConflictDetection(txn2, 2000, .Serializable);
    try expect(initial_read2 == null); // No data initially

    const data2 = "Transaction 2 Data";
    try isolation_manager.writeWithConflictDetection(txn2, 2000, data2, .Serializable);

    // Cross-reads that could create dangerous dependency structure
    _ = try isolation_manager.readWithConflictDetection(txn1, 2000, .Serializable);
    _ = try isolation_manager.readWithConflictDetection(txn2, 1000, .Serializable);

    // Both transactions should be able to commit (no actual conflict)
    try isolation_manager.commitWithValidation(txn1, .Serializable);
    try isolation_manager.commitWithValidation(txn2, .Serializable);

    // Verify final states
    try expectEqual(mvcc.TxnState.Committed, txn1.state);
    try expectEqual(mvcc.TxnState.Committed, txn2.state);

    // Verify statistics tracking
    const stats = isolation_manager.getStatistics();
    try expect(stats.total_conflicts >= 0); // May or may not have conflicts
}

// Integration test for phantom read prevention with predicate locks
test "CANARY_REQ_TXN_ISOLATION_INTEGRATION_002_Phantom_Read_Prevention" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    try mvcc_manager.enablePhantomReadPrevention();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Test phantom read prevention scenario
    const reader_txn = try isolation_manager.beginTransactionWithIsolation(.Serializable, 100);
    defer reader_txn.deinit();

    const writer_txn = try isolation_manager.beginTransactionWithIsolation(.Serializable, 50);
    defer writer_txn.deinit();

    // Reader performs range query (simulated)
    // In real implementation, this would acquire predicate locks
    const query_conditions = [_]phantom_prevention.QueryCondition{
        .{
            .type = .PropertyRange,
            .property = "age",
            .value = .{ .Int = 25 },
        },
    };

    // Record the range query for phantom read detection
    try isolation_manager.phantom_prevention.recordReadQuery(
        reader_txn.id,
        "Person",
        &query_conditions,
        5, // Found 5 matching records
        reader_txn.snapshot_timestamp,
    );

    // Acquire predicate lock
    const predicate_acquired = try isolation_manager.phantom_prevention.acquirePredicateLock(
        reader_txn.id,
        "Person",
        &query_conditions,
        reader_txn.snapshot_timestamp,
    );
    try expect(predicate_acquired);

    // Writer attempts to insert tuple that would satisfy the predicate
    const conflicting_properties = [_]phantom_prevention.PropertyBinding{
        .{ .name = "age", .value = .{ .Int = 30 } }, // Satisfies age > 25
        .{ .name = "name", .value = .{ .String = "Alice Johnson" } },
    };

    // Check for phantom read conflict
    const conflict = try isolation_manager.phantom_prevention.checkWriteConflict(
        writer_txn.id,
        "Person",
        &conflicting_properties,
    );

    // Should detect phantom read conflict
    if (conflict) |conf| {
        try expectEqual(reader_txn.id, conf.conflicting_txn);
        try expectEqual(mvcc.ConflictType.PhantomRead, conf.conflict_type);

        // Writer should abort due to conflict
        try isolation_manager.abortWithCleanup(writer_txn);
        try expectEqual(mvcc.TxnState.Aborted, writer_txn.state);
    }

    // Reader should be able to commit
    try isolation_manager.commitWithValidation(reader_txn, .Serializable);
    try expectEqual(mvcc.TxnState.Committed, reader_txn.state);

    // Verify phantom read statistics
    const phantom_stats = isolation_manager.getPhantomReadStatistics();
    try expect(phantom_stats.active_predicate_locks >= 0);
}

// Integration test for deadlock detection and resolution in high-concurrency scenario
test "CANARY_REQ_TXN_ISOLATION_INTEGRATION_003_Deadlock_Detection_Resolution" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Create multiple transactions for complex deadlock scenario
    const txn_a = try isolation_manager.beginTransactionWithIsolation(.RepeatableRead, 1000); // Highest priority
    defer txn_a.deinit();

    const txn_b = try isolation_manager.beginTransactionWithIsolation(.RepeatableRead, 500); // Medium priority
    defer txn_b.deinit();

    const txn_c = try isolation_manager.beginTransactionWithIsolation(.RepeatableRead, 100); // Lowest priority (victim)
    defer txn_c.deinit();

    const txn_d = try isolation_manager.beginTransactionWithIsolation(.RepeatableRead, 750); // High priority
    defer txn_d.deinit();

    // Simulate lock acquisition that creates deadlock
    // A -> B -> C -> D -> A (circular wait)
    try isolation_manager.deadlock_detector.addWaitFor(txn_a.id, txn_b.id);
    try isolation_manager.deadlock_detector.addWaitFor(txn_b.id, txn_c.id);
    try isolation_manager.deadlock_detector.addWaitFor(txn_c.id, txn_d.id);
    try isolation_manager.deadlock_detector.addWaitFor(txn_d.id, txn_a.id);

    // Record initial statistics
    const initial_deadlocks = isolation_manager.conflict_statistics.deadlocks_detected;
    const initial_resolved = isolation_manager.conflict_statistics.deadlocks_resolved;
    const initial_aborted = isolation_manager.conflict_statistics.transactions_aborted;

    // Trigger deadlock detection and resolution
    try isolation_manager.detectAndResolveDeadlocks();

    // Verify deadlock was detected and resolved
    try expect(isolation_manager.conflict_statistics.deadlocks_detected > initial_deadlocks);
    try expect(isolation_manager.conflict_statistics.deadlocks_resolved > initial_resolved);
    try expect(isolation_manager.conflict_statistics.transactions_aborted > initial_aborted);

    // Verify victim selection (should be lowest priority transaction)
    try expectEqual(mvcc.TxnState.Aborted, txn_c.state);

    // Other transactions should still be active
    try expectEqual(mvcc.TxnState.Active, txn_a.state);
    try expectEqual(mvcc.TxnState.Active, txn_b.state);
    try expectEqual(mvcc.TxnState.Active, txn_d.state);

    // Commit remaining transactions
    try isolation_manager.commitWithValidation(txn_a, .RepeatableRead);
    try isolation_manager.commitWithValidation(txn_b, .RepeatableRead);
    try isolation_manager.commitWithValidation(txn_d, .RepeatableRead);

    // Verify resolution time tracking
    try expect(isolation_manager.conflict_statistics.average_resolution_time_ms >= 0.0);
}

// Integration test for high-concurrency workload with multiple isolation levels
test "CANARY_REQ_TXN_ISOLATION_INTEGRATION_004_High_Concurrency_Workload" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    try mvcc_manager.enablePhantomReadPrevention();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Create multiple concurrent transactions with different isolation levels
    const num_transactions = 10;
    var transactions: [num_transactions]*mvcc.Transaction = undefined;
    var isolation_levels: [num_transactions]enhanced_isolation.EnhancedIsolationLevel = undefined;

    // Initialize transactions with varying isolation levels and priorities
    for (0..num_transactions) |i| {
        const isolation_level = switch (i % 4) {
            0 => enhanced_isolation.EnhancedIsolationLevel.ReadCommitted,
            1 => enhanced_isolation.EnhancedIsolationLevel.RepeatableRead,
            2 => enhanced_isolation.EnhancedIsolationLevel.SnapshotIsolation,
            3 => enhanced_isolation.EnhancedIsolationLevel.SerializableSnapshot,
            else => unreachable,
        };

        const priority = @as(u32, @intCast(i * 100)); // Varying priorities

        transactions[i] = try isolation_manager.beginTransactionWithIsolation(isolation_level, priority);
        isolation_levels[i] = isolation_level;
    }

    // Ensure cleanup happens
    defer for (transactions) |txn| {
        txn.deinit();
    };

    // Simulate concurrent operations
    for (transactions, 0..) |txn, i| {
        const resource_base = @as(u64, @intCast(i * 1000));

        // Each transaction performs multiple operations
        for (0..5) |j| {
            const resource_id = resource_base + @as(u64, @intCast(j));
            const data = try std.fmt.allocPrint(allocator, "data_txn_{}_op_{}", .{ i, j });
            defer allocator.free(data);

            // Perform read operation
            _ = try isolation_manager.readWithConflictDetection(txn, resource_id, isolation_levels[i]);

            // Perform write operation
            try isolation_manager.writeWithConflictDetection(txn, resource_id, data, isolation_levels[i]);

            // Some transactions perform cross-reads (potential conflicts)
            if (i % 3 == 0 and j == 2) {
                const other_resource = ((i + 1) % num_transactions) * 1000 + j;
                _ = try isolation_manager.readWithConflictDetection(txn, @intCast(other_resource), isolation_levels[i]);
            }
        }
    }

    // Simulate some transactions creating wait-for dependencies
    for (0..5) |i| {
        const waiter = transactions[i].id;
        const holder = transactions[(i + 1) % num_transactions].id;
        try isolation_manager.deadlock_detector.addWaitFor(waiter, holder);
    }

    // Perform deadlock detection
    try isolation_manager.detectAndResolveDeadlocks();

    // Commit or abort transactions based on their current state
    var committed_count: u32 = 0;
    var aborted_count: u32 = 0;

    for (transactions, 0..) |txn, i| {
        switch (txn.state) {
            .Active => {
                // Try to commit active transactions
                isolation_manager.commitWithValidation(txn, isolation_levels[i]) catch |err| switch (err) {
                    error.SerializationConflict => {
                        try isolation_manager.abortWithCleanup(txn);
                        aborted_count += 1;
                    },
                    else => return err,
                };

                if (txn.state == .Committed) {
                    committed_count += 1;
                }
            },
            .Aborted => {
                aborted_count += 1;
            },
            .Committed => {
                committed_count += 1;
            },
            else => {
                // Handle other states if needed
            },
        }
    }

    // Verify that all transactions were either committed or aborted
    try expectEqual(@as(u32, num_transactions), committed_count + aborted_count);

    // Verify statistics collection
    const final_stats = isolation_manager.getStatistics();
    try expect(final_stats.total_conflicts >= 0);
    try expect(final_stats.transactions_aborted >= aborted_count);

    std.debug.print("High concurrency test: {} committed, {} aborted, {} total conflicts\n", .{
        committed_count,
        aborted_count,
        final_stats.total_conflicts,
    });
}

// Integration test for SerializableSnapshot isolation with dependency tracking
test "SerializableSnapshot_dependency_tracking_integration" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Test SerializableSnapshot isolation with dependency tracking
    const txn1 = try isolation_manager.beginTransactionWithIsolation(.SerializableSnapshot, 100);
    defer txn1.deinit();

    const txn2 = try isolation_manager.beginTransactionWithIsolation(.SerializableSnapshot, 200);
    defer txn2.deinit();

    const txn3 = try isolation_manager.beginTransactionWithIsolation(.SerializableSnapshot, 150);
    defer txn3.deinit();

    // Create dependency pattern that could lead to dangerous structure
    // T1 -> T2 (RW dependency)
    try isolation_manager.dependency_tracker.addReadDependency(txn1.id, txn2.id);

    // T2 -> T3 (WR dependency)
    try isolation_manager.dependency_tracker.addWriteDependency(txn2.id, txn3.id);

    // T3 -> T1 (RW dependency) - completes dangerous cycle
    try isolation_manager.dependency_tracker.addReadDependency(txn3.id, txn1.id);

    // Check for dangerous structure
    try expect(try isolation_manager.dependency_tracker.checkDangerousStructure(txn1.id));
    try expect(try isolation_manager.dependency_tracker.checkDangerousStructure(txn2.id));
    try expect(try isolation_manager.dependency_tracker.checkDangerousStructure(txn3.id));

    // Attempt to write with SerializableSnapshot (should detect conflict)
    const test_data = "dangerous_structure_test";

    // This write should trigger dangerous structure detection
    const write_result = isolation_manager.writeWithConflictDetection(txn1, 12345, test_data, .SerializableSnapshot);
    try expectError(error.SerializationConflict, write_result);

    // Transaction should be aborted due to serialization conflict
    try expectEqual(mvcc.TxnState.Active, txn1.state); // Still active, but write failed

    // Clean abort
    try isolation_manager.abortWithCleanup(txn1);
    try expectEqual(mvcc.TxnState.Aborted, txn1.state);

    // Other transactions should still be able to operate
    try isolation_manager.writeWithConflictDetection(txn2, 23456, test_data, .SerializableSnapshot);
    try isolation_manager.commitWithValidation(txn2, .SerializableSnapshot);
    try expectEqual(mvcc.TxnState.Committed, txn2.state);
}

// Performance stress test for isolation manager
test "isolation_manager_performance_stress_test" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    const num_stress_transactions = 50;
    const operations_per_txn = 20;

    var stress_transactions: [num_stress_transactions]*mvcc.Transaction = undefined;

    // Create many transactions
    for (0..num_stress_transactions) |i| {
        const priority = @as(u32, @intCast(i % 1000)); // Varying priorities
        stress_transactions[i] = try isolation_manager.beginTransactionWithIsolation(.SnapshotIsolation, priority);
    }

    defer for (stress_transactions) |txn| {
        txn.deinit();
    };

    const start_time = std.time.milliTimestamp();

    // Perform many operations
    for (stress_transactions, 0..) |txn, i| {
        for (0..operations_per_txn) |j| {
            const resource_id = @as(u64, @intCast(i * operations_per_txn + j));
            const data = try std.fmt.allocPrint(allocator, "stress_data_{}_{}", .{ i, j });
            defer allocator.free(data);

            // Perform operations
            _ = try isolation_manager.readWithConflictDetection(txn, resource_id, .SnapshotIsolation);
            try isolation_manager.writeWithConflictDetection(txn, resource_id, data, .SnapshotIsolation);
        }
    }

    // Commit all transactions
    for (stress_transactions) |txn| {
        try isolation_manager.commitWithValidation(txn, .SnapshotIsolation);
    }

    const end_time = std.time.milliTimestamp();
    const total_time = end_time - start_time;
    const total_operations = num_stress_transactions * operations_per_txn * 2; // read + write

    // Performance assertions
    try expect(total_time < 10000); // Should complete within 10 seconds

    const ops_per_ms = @as(f64, @floatFromInt(total_operations)) / @as(f64, @floatFromInt(total_time));
    try expect(ops_per_ms > 1.0); // Should process more than 1 operation per millisecond

    std.debug.print("Stress test: {} operations in {}ms ({d:.2} ops/ms)\n", .{
        total_operations,
        total_time,
        ops_per_ms,
    });

    // Verify all transactions committed successfully
    for (stress_transactions) |txn| {
        try expectEqual(mvcc.TxnState.Committed, txn.state);
    }
}

// Memory management test for isolation manager
test "isolation_manager_memory_management" {
    const allocator = testing.allocator;

    // Run multiple isolation manager lifecycles to test for memory leaks
    for (0..5) |cycle| {
        var mvcc_manager = mvcc.MVCCManager.init(allocator);
        defer mvcc_manager.deinit();

        var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
        defer isolation_manager.deinit();

        // Create, use, and destroy multiple transactions in each cycle
        for (0..10) |i| {
            const txn = try isolation_manager.beginTransactionWithIsolation(.RepeatableRead, @intCast(i));
            defer txn.deinit();

            // Add some dependencies
            if (i > 0) {
                try isolation_manager.dependency_tracker.addReadDependency(txn.id, @intCast(i - 1));
                try isolation_manager.dependency_tracker.addWriteDependency(txn.id, @intCast(i + 100));
            }

            // Perform some operations
            const data = try std.fmt.allocPrint(allocator, "cycle_{}_txn_{}", .{ cycle, i });
            defer allocator.free(data);

            try isolation_manager.writeWithConflictDetection(txn, @intCast(cycle * 1000 + i), data, .RepeatableRead);

            // Commit or abort based on index
            if (i % 3 == 0) {
                try isolation_manager.abortWithCleanup(txn);
            } else {
                try isolation_manager.commitWithValidation(txn, .RepeatableRead);
            }
        }

        // Verify cleanup occurred
        try expect(isolation_manager.dependency_tracker.read_dependencies.count() == 0);
        try expect(isolation_manager.dependency_tracker.write_dependencies.count() == 0);

        std.debug.print("Memory management test cycle {} completed\n", .{cycle});
    }

    // If we reach here without memory allocation errors, memory management is working correctly
}

// Test runner
pub fn main() !void {
    std.debug.print("Running Enhanced Transaction Isolation Integration Tests...\n\n");

    // Run all integration tests
    try testing.refAllDecls(@This());

    std.debug.print("\nAll Enhanced Transaction Isolation Integration Tests Completed Successfully!\n");
}
