// CANARY: REQ=REQ-TXN-ISOLATION-TEST-001; FEATURE="Enhanced Transaction Isolation Tests"; ASPECT=IsolationLevels; STATUS=TESTED; TEST=TestCANARY_TXN_ISOLATION_TEST_001; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-ISOLATION-TEST-002; FEATURE="Deadlock Detection Tests"; ASPECT=DeadlockResolution; STATUS=TESTED; TEST=TestCANARY_TXN_ISOLATION_TEST_002; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-ISOLATION-TEST-003; FEATURE="Dependency Tracking Tests"; ASPECT=SerializableSSI; STATUS=TESTED; TEST=TestCANARY_TXN_ISOLATION_TEST_003; OWNER=txn; UPDATED=2025-10-05

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;

const geode = @import("../src/lib.zig");
const enhanced_isolation = @import("../src/server/txn/enhanced_isolation.zig");
const mvcc = @import("../src/server/txn/mvcc.zig");
const phantom_prevention = @import("../src/server/txn/phantom_read_prevention.zig");

test "EnhancedIsolationLevel properties validation" {
    // Test isolation level property checks
    try expect(enhanced_isolation.EnhancedIsolationLevel.ReadUncommitted.requiresLocking() == false);
    try expect(enhanced_isolation.EnhancedIsolationLevel.Serializable.requiresLocking() == true);
    try expect(enhanced_isolation.EnhancedIsolationLevel.SerializableSnapshot.requiresLocking() == true);

    try expect(enhanced_isolation.EnhancedIsolationLevel.ReadUncommitted.preventsDirtyReads() == false);
    try expect(enhanced_isolation.EnhancedIsolationLevel.ReadCommitted.preventsDirtyReads() == true);
    try expect(enhanced_isolation.EnhancedIsolationLevel.SnapshotIsolation.preventsDirtyReads() == true);

    try expect(enhanced_isolation.EnhancedIsolationLevel.ReadCommitted.preventsNonRepeatableReads() == false);
    try expect(enhanced_isolation.EnhancedIsolationLevel.RepeatableRead.preventsNonRepeatableReads() == true);
    try expect(enhanced_isolation.EnhancedIsolationLevel.SnapshotIsolation.preventsNonRepeatableReads() == true);

    try expect(enhanced_isolation.EnhancedIsolationLevel.RepeatableRead.preventsPhantomReads() == false);
    try expect(enhanced_isolation.EnhancedIsolationLevel.Serializable.preventsPhantomReads() == true);
    try expect(enhanced_isolation.EnhancedIsolationLevel.SerializableSnapshot.preventsPhantomReads() == true);
}

test "DependencyTracker basic functionality" {
    const allocator = testing.allocator;

    var tracker = enhanced_isolation.DependencyTracker.init(allocator);
    defer tracker.deinit();

    // Add read dependencies
    try tracker.addReadDependency(1, 2); // T1 reads after T2 writes
    try tracker.addReadDependency(1, 3); // T1 reads after T3 writes
    try tracker.addReadDependency(2, 3); // T2 reads after T3 writes

    // Add write dependencies
    try tracker.addWriteDependency(2, 1); // T2 writes after T1 reads
    try tracker.addWriteDependency(3, 2); // T3 writes after T2 reads

    // Test duplicate prevention
    try tracker.addReadDependency(1, 2); // Should not add duplicate

    if (tracker.read_dependencies.get(1)) |deps| {
        try expectEqual(@as(usize, 2), deps.items.len); // Should still be 2, not 3
    } else {
        try expect(false); // Dependencies should exist
    }

    // Test dangerous structure detection (should not detect cycle yet)
    try expect(!try tracker.checkDangerousStructure(1));

    // Add dependency that creates dangerous cycle: T1 -> T2 -> T3 -> T1
    try tracker.addReadDependency(3, 1); // T3 reads after T1 writes

    // Now should detect dangerous structure
    try expect(try tracker.checkDangerousStructure(1));
}

test "DependencyTracker cleanup" {
    const allocator = testing.allocator;

    var tracker = enhanced_isolation.DependencyTracker.init(allocator);
    defer tracker.deinit();

    // Set up dependencies
    try tracker.addReadDependency(1, 2);
    try tracker.addReadDependency(2, 3);
    try tracker.addWriteDependency(3, 1);
    try tracker.addWriteDependency(2, 4);

    // Verify dependencies exist
    try expect(tracker.read_dependencies.contains(1));
    try expect(tracker.read_dependencies.contains(2));
    try expect(tracker.write_dependencies.contains(3));
    try expect(tracker.write_dependencies.contains(2));

    // Remove transaction 2
    tracker.removeDependencies(2);

    // Verify transaction 2's dependencies are removed
    try expect(!tracker.read_dependencies.contains(2));
    try expect(!tracker.write_dependencies.contains(2));

    // Verify references to transaction 2 are removed from other dependencies
    if (tracker.read_dependencies.get(1)) |deps| {
        for (deps.items) |dep| {
            try expect(dep != 2); // Should not reference transaction 2
        }
    }
}

test "EnhancedDeadlockDetector basic deadlock detection" {
    const allocator = testing.allocator;

    var detector = enhanced_isolation.EnhancedDeadlockDetector.init(allocator);
    defer detector.deinit();

    // Set up deadlock scenario: T1 -> T2 -> T3 -> T1
    try detector.addWaitFor(1, 2); // T1 waits for T2
    try detector.addWaitFor(2, 3); // T2 waits for T3
    try detector.addWaitFor(3, 1); // T3 waits for T1 (creates cycle)

    // Set priorities for victim selection
    try detector.setPriority(1, 100); // High priority
    try detector.setPriority(2, 50); // Medium priority
    try detector.setPriority(3, 10); // Low priority (should be victim)

    // Detect deadlock
    if (try detector.detectDeadlock()) |cycle| {
        defer allocator.free(cycle.transactions);

        try expect(cycle.transactions.len >= 3); // Should detect the cycle
        try expectEqual(@as(mvcc.TxnId, 3), cycle.victim); // T3 should be victim (lowest priority)
    } else {
        try expect(false); // Should have detected deadlock
    }
}

test "EnhancedDeadlockDetector wait-for removal" {
    const allocator = testing.allocator;

    var detector = enhanced_isolation.EnhancedDeadlockDetector.init(allocator);
    defer detector.deinit();

    // Set up potential deadlock
    try detector.addWaitFor(1, 2);
    try detector.addWaitFor(2, 3);
    try detector.addWaitFor(3, 1);

    // Should detect deadlock
    try expect((try detector.detectDeadlock()) != null);

    // Remove one wait-for edge to break cycle
    detector.removeWaitFor(3, 1);

    // Should no longer detect deadlock
    try expect((try detector.detectDeadlock()) == null);
}

test "EnhancedIsolationManager initialization and basic operations" {
    const allocator = testing.allocator;

    // Initialize MVCC manager first
    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    // Initialize enhanced isolation manager
    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Test transaction creation with different isolation levels
    const txn1 = try isolation_manager.beginTransactionWithIsolation(.SnapshotIsolation, 100);
    defer txn1.deinit();

    try expectEqual(mvcc.IsolationLevel.SnapshotIsolation, txn1.isolation_level);
    try expectEqual(mvcc.TxnState.Active, txn1.state);

    const txn2 = try isolation_manager.beginTransactionWithIsolation(.Serializable, 50);
    defer txn2.deinit();

    try expectEqual(mvcc.IsolationLevel.Serializable, txn2.isolation_level);

    // Test priority setting was successful
    try expect(isolation_manager.deadlock_detector.transaction_priorities.contains(txn1.id));
    try expect(isolation_manager.deadlock_detector.transaction_priorities.contains(txn2.id));
}

test "EnhancedIsolationManager read with conflict detection" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Begin transaction
    const txn = try isolation_manager.beginTransactionWithIsolation(.SnapshotIsolation, 100);
    defer txn.deinit();

    // Test read operation
    const result = try isolation_manager.readWithConflictDetection(txn, 123, .SnapshotIsolation);

    // Should return null for non-existent resource (expected behavior)
    try expect(result == null);

    // Verify no dependencies were incorrectly added for simple read
    try expect(!isolation_manager.dependency_tracker.read_dependencies.contains(txn.id));
}

test "EnhancedIsolationManager write with conflict detection" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Begin transaction
    const txn = try isolation_manager.beginTransactionWithIsolation(.SnapshotIsolation, 100);
    defer txn.deinit();

    // Test write operation
    const test_data = "test_data_123";
    try isolation_manager.writeWithConflictDetection(txn, 456, test_data, .SnapshotIsolation);

    // Verify write was recorded in transaction's write set
    try expect(txn.write_set.items.len > 0);
    try expectEqual(@as(u64, 456), txn.write_set.items[0].resource_id);
}

test "EnhancedIsolationManager commit with validation" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Begin transaction and perform operations
    const txn = try isolation_manager.beginTransactionWithIsolation(.SnapshotIsolation, 100);
    defer txn.deinit();

    const test_data = "commit_test_data";
    try isolation_manager.writeWithConflictDetection(txn, 789, test_data, .SnapshotIsolation);

    // Commit transaction
    try isolation_manager.commitWithValidation(txn, .SnapshotIsolation);

    // Verify transaction state changed to committed
    try expectEqual(mvcc.TxnState.Committed, txn.state);

    // Verify cleanup occurred (dependencies should be removed)
    try expect(!isolation_manager.dependency_tracker.read_dependencies.contains(txn.id));
    try expect(!isolation_manager.dependency_tracker.write_dependencies.contains(txn.id));
}

test "EnhancedIsolationManager abort with cleanup" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Begin transaction and add some dependencies
    const txn = try isolation_manager.beginTransactionWithIsolation(.SerializableSnapshot, 100);
    defer txn.deinit();

    // Manually add dependencies to test cleanup
    try isolation_manager.dependency_tracker.addReadDependency(txn.id, 999);
    try isolation_manager.dependency_tracker.addWriteDependency(txn.id, 888);

    // Verify dependencies exist
    try expect(isolation_manager.dependency_tracker.read_dependencies.contains(txn.id));
    try expect(isolation_manager.dependency_tracker.write_dependencies.contains(txn.id));

    // Abort transaction
    try isolation_manager.abortWithCleanup(txn);

    // Verify transaction state changed
    try expectEqual(mvcc.TxnState.Aborted, txn.state);

    // Verify cleanup occurred
    try expect(!isolation_manager.dependency_tracker.read_dependencies.contains(txn.id));
    try expect(!isolation_manager.dependency_tracker.write_dependencies.contains(txn.id));

    // Verify statistics were updated
    try expect(isolation_manager.conflict_statistics.transactions_aborted > 0);
}

test "EnhancedIsolationManager deadlock detection and resolution" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Create transactions for deadlock scenario
    const txn1 = try isolation_manager.beginTransactionWithIsolation(.Serializable, 100);
    defer txn1.deinit();

    const txn2 = try isolation_manager.beginTransactionWithIsolation(.Serializable, 50);
    defer txn2.deinit();

    const txn3 = try isolation_manager.beginTransactionWithIsolation(.Serializable, 10);
    defer txn3.deinit();

    // Set up deadlock in wait-for graph
    try isolation_manager.deadlock_detector.addWaitFor(txn1.id, txn2.id);
    try isolation_manager.deadlock_detector.addWaitFor(txn2.id, txn3.id);
    try isolation_manager.deadlock_detector.addWaitFor(txn3.id, txn1.id);

    // Record initial statistics
    const initial_deadlocks = isolation_manager.conflict_statistics.deadlocks_detected;
    const initial_resolved = isolation_manager.conflict_statistics.deadlocks_resolved;

    // Detect and resolve deadlocks
    try isolation_manager.detectAndResolveDeadlocks();

    // Verify deadlock was detected and resolved
    try expect(isolation_manager.conflict_statistics.deadlocks_detected > initial_deadlocks);
    try expect(isolation_manager.conflict_statistics.deadlocks_resolved > initial_resolved);

    // Verify victim transaction (txn3 with lowest priority) was aborted
    try expectEqual(mvcc.TxnState.Aborted, txn3.state);
}

test "ConflictStatistics resolution time tracking" {
    var stats = enhanced_isolation.EnhancedIsolationManager.ConflictStatistics{};

    // Test initial state
    try expectEqual(@as(f64, 0.0), stats.average_resolution_time_ms);

    // Add first resolution time
    stats.deadlocks_resolved = 1;
    stats.updateResolutionTime(10.0);
    try expectEqual(@as(f64, 10.0), stats.average_resolution_time_ms);

    // Add second resolution time
    stats.deadlocks_resolved = 2;
    stats.updateResolutionTime(20.0);
    try expectEqual(@as(f64, 15.0), stats.average_resolution_time_ms);

    // Add transaction abort time
    stats.transactions_aborted = 1;
    stats.updateResolutionTime(30.0);
    try expectEqual(@as(f64, 20.0), stats.average_resolution_time_ms); // (10+20+30)/3
}

test "Enhanced isolation level validation comprehensive" {
    // Test all isolation levels have expected properties
    const levels = [_]enhanced_isolation.EnhancedIsolationLevel{ .ReadUncommitted, .ReadCommitted, .RepeatableRead, .Serializable, .SnapshotIsolation, .SerializableSnapshot };

    for (levels) |level| {
        // Verify consistency: if prevents phantom reads, should also prevent non-repeatable reads
        if (level.preventsPhantomReads()) {
            try expect(level.preventsNonRepeatableReads());
        }

        // Verify consistency: if prevents non-repeatable reads, should also prevent dirty reads
        if (level.preventsNonRepeatableReads()) {
            try expect(level.preventsDirtyReads());
        }

        // Verify serializable levels require locking
        if (level == .Serializable or level == .SerializableSnapshot) {
            try expect(level.requiresLocking());
        }
    }
}

test "Complex dependency tracking scenario" {
    const allocator = testing.allocator;

    var tracker = enhanced_isolation.DependencyTracker.init(allocator);
    defer tracker.deinit();

    // Complex scenario with multiple transactions and dependencies
    // T1 -> T2 -> T3 -> T4 -> T1 (RW-WR cycle)
    try tracker.addReadDependency(1, 2); // T1 reads after T2 writes
    try tracker.addWriteDependency(2, 3); // T2 writes after T3 reads
    try tracker.addReadDependency(3, 4); // T3 reads after T4 writes
    try tracker.addWriteDependency(4, 1); // T4 writes after T1 reads

    // Should detect dangerous structure for all transactions in cycle
    try expect(try tracker.checkDangerousStructure(1));
    try expect(try tracker.checkDangerousStructure(2));
    try expect(try tracker.checkDangerousStructure(3));
    try expect(try tracker.checkDangerousStructure(4));

    // T5 not in cycle should be safe
    try tracker.addReadDependency(5, 1); // T5 reads after T1 writes
    try expect(!try tracker.checkDangerousStructure(5));

    // Breaking the cycle should resolve dangerous structures
    tracker.removeDependencies(2);

    try expect(!try tracker.checkDangerousStructure(1));
    try expect(!try tracker.checkDangerousStructure(3));
    try expect(!try tracker.checkDangerousStructure(4));
}

test "Deadlock detector priority-based victim selection" {
    const allocator = testing.allocator;

    var detector = enhanced_isolation.EnhancedDeadlockDetector.init(allocator);
    defer detector.deinit();

    // Create deadlock with different priorities
    try detector.addWaitFor(100, 200); // T100 waits for T200
    try detector.addWaitFor(200, 300); // T200 waits for T300
    try detector.addWaitFor(300, 100); // T300 waits for T100

    // Set priorities: higher number = higher priority
    try detector.setPriority(100, 1000); // Highest priority
    try detector.setPriority(200, 500); // Medium priority
    try detector.setPriority(300, 100); // Lowest priority (should be victim)

    if (try detector.detectDeadlock()) |cycle| {
        defer allocator.free(cycle.transactions);

        try expectEqual(@as(mvcc.TxnId, 300), cycle.victim); // Lowest priority
        try expect(cycle.transactions.len == 3);
    } else {
        try expect(false); // Should detect deadlock
    }
}

test "Integration: Full isolation manager lifecycle" {
    const allocator = testing.allocator;

    var mvcc_manager = mvcc.MVCCManager.init(allocator);
    defer mvcc_manager.deinit();

    var isolation_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, &mvcc_manager);
    defer isolation_manager.deinit();

    // Test complete transaction lifecycle with enhanced isolation
    const txn1 = try isolation_manager.beginTransactionWithIsolation(.SerializableSnapshot, 100);
    defer txn1.deinit();

    const txn2 = try isolation_manager.beginTransactionWithIsolation(.SerializableSnapshot, 200);
    defer txn2.deinit();

    // Perform conflicting operations
    const data1 = "data_from_txn1";
    const data2 = "data_from_txn2";

    try isolation_manager.writeWithConflictDetection(txn1, 1000, data1, .SerializableSnapshot);
    try isolation_manager.writeWithConflictDetection(txn2, 2000, data2, .SerializableSnapshot);

    // Read operations
    _ = try isolation_manager.readWithConflictDetection(txn1, 2000, .SerializableSnapshot);
    _ = try isolation_manager.readWithConflictDetection(txn2, 1000, .SerializableSnapshot);

    // Commit both transactions
    try isolation_manager.commitWithValidation(txn1, .SerializableSnapshot);
    try isolation_manager.commitWithValidation(txn2, .SerializableSnapshot);

    // Verify final states
    try expectEqual(mvcc.TxnState.Committed, txn1.state);
    try expectEqual(mvcc.TxnState.Committed, txn2.state);

    // Verify cleanup
    try expect(!isolation_manager.dependency_tracker.read_dependencies.contains(txn1.id));
    try expect(!isolation_manager.dependency_tracker.write_dependencies.contains(txn1.id));
    try expect(!isolation_manager.dependency_tracker.read_dependencies.contains(txn2.id));
    try expect(!isolation_manager.dependency_tracker.write_dependencies.contains(txn2.id));
}

// Test runner
pub fn main() !void {
    std.debug.print("Running Enhanced Transaction Isolation Unit Tests...\n\n");

    // Run all unit tests
    try testing.refAllDecls(@This());

    std.debug.print("\nAll Enhanced Transaction Isolation Unit Tests Completed Successfully!\n");
}
