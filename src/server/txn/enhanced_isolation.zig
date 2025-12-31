// CANARY: REQ=REQ-TXN-ISOLATION-001; FEATURE="Enhanced Transaction Isolation"; ASPECT=IsolationLevels; STATUS=IMPL; TEST=TestCANARY_REQ_TXN_ISOLATION_001_IsolationLevels; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-ISOLATION-002; FEATURE="Advanced Phantom Read Prevention"; ASPECT=PhantomReadPrevention; STATUS=IMPL; TEST=TestCANARY_REQ_TXN_ISOLATION_002_PhantomReadPrevention; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-ISOLATION-003; FEATURE="Serializable Snapshot Isolation"; ASPECT=SerializableSSI; STATUS=IMPL; TEST=TestCANARY_REQ_TXN_ISOLATION_003_SerializableSSI; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-ISOLATION-004; FEATURE="Deadlock Detection and Resolution"; ASPECT=DeadlockResolution; STATUS=IMPL; TEST=TestCANARY_REQ_TXN_ISOLATION_004_DeadlockResolution; OWNER=txn; UPDATED=2025-10-05

const std = @import("std");
const mvcc = @import("mvcc.zig");
const phantom_prevention = @import("phantom_read_prevention.zig");

/// Enhanced transaction isolation levels with additional ANSI SQL support
pub const EnhancedIsolationLevel = enum {
    ReadUncommitted, // No isolation guarantees
    ReadCommitted, // Prevent dirty reads
    RepeatableRead, // Prevent dirty and non-repeatable reads
    Serializable, // Full serializability with phantom read prevention
    SnapshotIsolation, // MVCC-based snapshot isolation (default)
    SerializableSnapshot, // Hybrid: Snapshot isolation + serializable checks

    pub fn requiresLocking(self: EnhancedIsolationLevel) bool {
        return self == .Serializable or self == .SerializableSnapshot;
    }

    pub fn preventsDirtyReads(self: EnhancedIsolationLevel) bool {
        return self != .ReadUncommitted;
    }

    pub fn preventsNonRepeatableReads(self: EnhancedIsolationLevel) bool {
        return self == .RepeatableRead or
            self == .Serializable or
            self == .SnapshotIsolation or
            self == .SerializableSnapshot;
    }

    pub fn preventsPhantomReads(self: EnhancedIsolationLevel) bool {
        return self == .Serializable or self == .SerializableSnapshot;
    }
};

/// Enhanced conflict detection types
pub const ConflictType = enum {
    ReadWriteConflict, // Traditional RW conflict
    WriteReadConflict, // Traditional WR conflict
    WriteWriteConflict, // Traditional WW conflict
    PhantomReadConflict, // Phantom read via predicate lock
    SerializationConflict, // SSI dangerous structure
    DeadlockConflict, // Deadlock detected
};

/// Enhanced conflict information with resolution strategies
pub const EnhancedConflictInfo = struct {
    conflicting_txn: mvcc.TxnId,
    conflict_type: ConflictType,
    resource_id: u64,
    timestamp: mvcc.Timestamp,
    resolution_strategy: ResolutionStrategy,
    severity: ConflictSeverity,

    pub const ResolutionStrategy = enum {
        Abort, // Abort current transaction
        Wait, // Wait for conflicting transaction
        AbortOther, // Abort the conflicting transaction
        Retry, // Retry after backoff
        Escalate, // Escalate to higher isolation level
    };

    pub const ConflictSeverity = enum {
        Low, // Non-critical conflict
        Medium, // Standard conflict
        High, // Critical conflict requiring immediate resolution
        Critical, // Potential deadlock or data integrity issue
    };
};

/// Transaction dependency tracking for Serializable Snapshot Isolation
pub const DependencyTracker = struct {
    allocator: std.mem.Allocator,
    read_dependencies: std.AutoHashMap(mvcc.TxnId, std.ArrayList(mvcc.TxnId)), // RW dependencies
    write_dependencies: std.AutoHashMap(mvcc.TxnId, std.ArrayList(mvcc.TxnId)), // WR dependencies

    pub fn init(allocator: std.mem.Allocator) DependencyTracker {
        return DependencyTracker{
            .allocator = allocator,
            .read_dependencies = std.AutoHashMap(mvcc.TxnId, std.ArrayList(mvcc.TxnId)).init(allocator),
            .write_dependencies = std.AutoHashMap(mvcc.TxnId, std.ArrayList(mvcc.TxnId)).init(allocator),
        };
    }

    pub fn deinit(self: *DependencyTracker) void {
        var read_iter = self.read_dependencies.iterator();
        while (read_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.read_dependencies.deinit();

        var write_iter = self.write_dependencies.iterator();
        while (write_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.write_dependencies.deinit();
    }

    /// Add RW dependency (reader depends on writer)
    pub fn addReadDependency(self: *DependencyTracker, reader: mvcc.TxnId, writer: mvcc.TxnId) !void {
        var deps = self.read_dependencies.get(reader) orelse blk: {
            const list = std.ArrayList(mvcc.TxnId).init(self.allocator);
            try self.read_dependencies.put(reader, list);
            break :blk self.read_dependencies.get(reader).?;
        };

        // Avoid duplicate dependencies
        for (deps.items) |existing| {
            if (existing == writer) return;
        }

        try deps.append(writer);
    }

    /// Add WR dependency (writer depends on reader)
    pub fn addWriteDependency(self: *DependencyTracker, writer: mvcc.TxnId, reader: mvcc.TxnId) !void {
        var deps = self.write_dependencies.get(writer) orelse blk: {
            const list = std.ArrayList(mvcc.TxnId).init(self.allocator);
            try self.write_dependencies.put(writer, list);
            break :blk self.write_dependencies.get(writer).?;
        };

        // Avoid duplicate dependencies
        for (deps.items) |existing| {
            if (existing == reader) return;
        }

        try deps.append(reader);
    }

    /// Check for dangerous structure (potential cycle)
    pub fn checkDangerousStructure(self: *DependencyTracker, txn_id: mvcc.TxnId) !bool {
        const read_deps = self.read_dependencies.get(txn_id);
        const write_deps = self.write_dependencies.get(txn_id);

        if (read_deps == null or write_deps == null) return false;

        // Look for T1 <- T2 <- T3 <- T1 pattern (RW-WR-RW cycle)
        for (read_deps.?.items) |rd_target| {
            if (self.write_dependencies.get(rd_target)) |wr_deps| {
                for (wr_deps.items) |wr_target| {
                    if (self.read_dependencies.get(wr_target)) |rw_deps| {
                        for (rw_deps.items) |rw_target| {
                            if (rw_target == txn_id) {
                                return true; // Dangerous cycle detected
                            }
                        }
                    }
                }
            }
        }

        return false;
    }

    /// Remove all dependencies for a transaction
    pub fn removeDependencies(self: *DependencyTracker, txn_id: mvcc.TxnId) void {
        if (self.read_dependencies.getPtr(txn_id)) |deps| {
            deps.deinit();
            _ = self.read_dependencies.remove(txn_id);
        }

        if (self.write_dependencies.getPtr(txn_id)) |deps| {
            deps.deinit();
            _ = self.write_dependencies.remove(txn_id);
        }

        // Remove references to this transaction from other dependencies
        var read_iter = self.read_dependencies.iterator();
        while (read_iter.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                if (entry.value_ptr.items[i] == txn_id) {
                    _ = entry.value_ptr.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        var write_iter = self.write_dependencies.iterator();
        while (write_iter.next()) |entry| {
            var i: usize = 0;
            while (i < entry.value_ptr.items.len) {
                if (entry.value_ptr.items[i] == txn_id) {
                    _ = entry.value_ptr.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }
};

/// Enhanced deadlock detection with timeout and priority-based resolution
pub const EnhancedDeadlockDetector = struct {
    allocator: std.mem.Allocator,
    wait_for_graph: std.AutoHashMap(mvcc.TxnId, std.ArrayList(mvcc.TxnId)),
    transaction_priorities: std.AutoHashMap(mvcc.TxnId, u32),
    detection_interval_ms: u32,
    max_wait_time_ms: u32,

    pub fn init(allocator: std.mem.Allocator) EnhancedDeadlockDetector {
        return EnhancedDeadlockDetector{
            .allocator = allocator,
            .wait_for_graph = std.AutoHashMap(mvcc.TxnId, std.ArrayList(mvcc.TxnId)).init(allocator),
            .transaction_priorities = std.AutoHashMap(mvcc.TxnId, u32).init(allocator),
            .detection_interval_ms = 1000, // Check every second
            .max_wait_time_ms = 30000, // 30 second timeout
        };
    }

    pub fn deinit(self: *EnhancedDeadlockDetector) void {
        var iter = self.wait_for_graph.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.wait_for_graph.deinit();
        self.transaction_priorities.deinit();
    }

    /// Add wait-for edge between transactions
    pub fn addWaitFor(self: *EnhancedDeadlockDetector, waiter: mvcc.TxnId, holder: mvcc.TxnId) !void {
        var waiters = self.wait_for_graph.get(waiter) orelse blk: {
            const list = std.ArrayList(mvcc.TxnId).init(self.allocator);
            try self.wait_for_graph.put(waiter, list);
            break :blk self.wait_for_graph.get(waiter).?;
        };

        try waiters.append(holder);
    }

    /// Remove wait-for edge
    pub fn removeWaitFor(self: *EnhancedDeadlockDetector, waiter: mvcc.TxnId, holder: mvcc.TxnId) void {
        if (self.wait_for_graph.getPtr(waiter)) |waiters| {
            var i: usize = 0;
            while (i < waiters.items.len) {
                if (waiters.items[i] == holder) {
                    _ = waiters.swapRemove(i);
                    break;
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Detect deadlocks using cycle detection
    pub fn detectDeadlock(self: *EnhancedDeadlockDetector) !?DeadlockCycle {
        var visited = std.AutoHashMap(mvcc.TxnId, void).init(self.allocator);
        defer visited.deinit();

        var stack = std.ArrayList(mvcc.TxnId).init(self.allocator);
        defer stack.deinit();

        var iter = self.wait_for_graph.iterator();
        while (iter.next()) |entry| {
            const start_txn = entry.key_ptr.*;

            if (visited.contains(start_txn)) continue;

            if (try self.dfsDetectCycle(start_txn, &visited, &stack)) |cycle| {
                return cycle;
            }
        }

        return null;
    }

    const DeadlockCycle = struct {
        transactions: []mvcc.TxnId,
        victim: mvcc.TxnId, // Transaction to abort
    };

    /// DFS-based cycle detection
    fn dfsDetectCycle(
        self: *EnhancedDeadlockDetector,
        current: mvcc.TxnId,
        visited: *std.AutoHashMap(mvcc.TxnId, void),
        stack: *std.ArrayList(mvcc.TxnId),
    ) !?DeadlockCycle {
        try visited.put(current, {});
        try stack.append(current);

        if (self.wait_for_graph.get(current)) |dependents| {
            for (dependents.items) |dependent| {
                // Check if we found a cycle
                for (stack.items, 0..) |stack_txn, idx| {
                    if (stack_txn == dependent) {
                        // Cycle found - select victim based on priority
                        const cycle_transactions = try self.allocator.dupe(mvcc.TxnId, stack.items[idx..]);
                        const victim = self.selectVictim(cycle_transactions);

                        return DeadlockCycle{
                            .transactions = cycle_transactions,
                            .victim = victim,
                        };
                    }
                }

                if (!visited.contains(dependent)) {
                    if (try self.dfsDetectCycle(dependent, visited, stack)) |cycle| {
                        return cycle;
                    }
                }
            }
        }

        _ = stack.pop(); // Remove current from stack
        return null;
    }

    /// Select deadlock victim based on priorities and heuristics
    fn selectVictim(self: *EnhancedDeadlockDetector, transactions: []mvcc.TxnId) mvcc.TxnId {
        // Priority-based victim selection
        var lowest_priority: u32 = std.math.maxInt(u32);
        var victim = transactions[0];

        for (transactions) |txn| {
            const priority = self.transaction_priorities.get(txn) orelse 0;
            if (priority < lowest_priority) {
                lowest_priority = priority;
                victim = txn;
            }
        }

        return victim;
    }

    /// Set transaction priority for deadlock resolution
    pub fn setPriority(self: *EnhancedDeadlockDetector, txn_id: mvcc.TxnId, priority: u32) !void {
        try self.transaction_priorities.put(txn_id, priority);
    }
};

/// Enhanced transaction isolation manager
pub const EnhancedIsolationManager = struct {
    allocator: std.mem.Allocator,
    mvcc_manager: *mvcc.MVCCManager,
    phantom_prevention: phantom_prevention.PhantomReadPrevention,
    dependency_tracker: DependencyTracker,
    deadlock_detector: EnhancedDeadlockDetector,

    // Statistics and monitoring
    conflict_statistics: ConflictStatistics,

    pub const ConflictStatistics = struct {
        total_conflicts: u64 = 0,
        phantom_read_conflicts: u64 = 0,
        deadlocks_detected: u64 = 0,
        deadlocks_resolved: u64 = 0,
        transactions_aborted: u64 = 0,
        average_resolution_time_ms: f64 = 0.0,

        pub fn updateResolutionTime(self: *ConflictStatistics, time_ms: f64) void {
            const total_resolutions = self.deadlocks_resolved + self.transactions_aborted;
            if (total_resolutions > 0) {
                self.average_resolution_time_ms =
                    (self.average_resolution_time_ms * @as(f64, @floatFromInt(total_resolutions - 1)) + time_ms) /
                    @as(f64, @floatFromInt(total_resolutions));
            } else {
                self.average_resolution_time_ms = time_ms;
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, mvcc_manager: *mvcc.MVCCManager) !EnhancedIsolationManager {
        return EnhancedIsolationManager{
            .allocator = allocator,
            .mvcc_manager = mvcc_manager,
            .phantom_prevention = phantom_prevention.PhantomReadPrevention.init(allocator),
            .dependency_tracker = DependencyTracker.init(allocator),
            .deadlock_detector = EnhancedDeadlockDetector.init(allocator),
            .conflict_statistics = ConflictStatistics{},
        };
    }

    pub fn deinit(self: *EnhancedIsolationManager) void {
        self.phantom_prevention.deinit();
        self.dependency_tracker.deinit();
        self.deadlock_detector.deinit();
    }

    /// Enhanced transaction begin with isolation level validation
    pub fn beginTransactionWithIsolation(
        self: *EnhancedIsolationManager,
        isolation: EnhancedIsolationLevel,
        priority: u32,
    ) !*mvcc.Transaction {
        const base_isolation = switch (isolation) {
            .ReadUncommitted => mvcc.IsolationLevel.ReadUncommitted,
            .ReadCommitted => mvcc.IsolationLevel.ReadCommitted,
            .RepeatableRead => mvcc.IsolationLevel.RepeatableRead,
            .Serializable, .SerializableSnapshot => mvcc.IsolationLevel.Serializable,
            .SnapshotIsolation => mvcc.IsolationLevel.SnapshotIsolation,
        };

        const txn = try self.mvcc_manager.beginTransaction(base_isolation);

        // Set transaction priority for deadlock resolution
        try self.deadlock_detector.setPriority(txn.id, priority);

        return txn;
    }

    /// Enhanced read with conflict detection and dependency tracking
    pub fn readWithConflictDetection(
        self: *EnhancedIsolationManager,
        txn: *mvcc.Transaction,
        resource_id: u64,
        isolation: EnhancedIsolationLevel,
    ) !?[]const u8 {
        // Perform base MVCC read
        const result = try self.mvcc_manager.read(txn, resource_id);

        // CANARY: REQ=REQ-TXN-ISOLATION-005; FEATURE="SSI RW Dependency Tracking"; ASPECT=ReadDependencies; STATUS=IMPL; OWNER=txn; UPDATED=2025-12-30
        // Track dependencies for SSI
        if (isolation == .SerializableSnapshot) {
            // Identify writing transactions and add RW dependencies
            // Look at version history to find which transaction wrote the version we're reading
            if (self.mvcc_manager.versions.get(resource_id)) |versions| {
                for (versions.items) |version| {
                    // If this version was written by another active transaction, add RW dependency
                    if (version.txn_id != txn.id and version.end_ts == null) {
                        // This version is from an active transaction - add RW dependency
                        // (reader depends on writer)
                        try self.dependency_tracker.addReadDependency(txn.id, version.txn_id);
                    } else if (version.txn_id != txn.id and
                        version.start_ts <= txn.snapshot_timestamp and
                        (version.end_ts == null or version.end_ts.? > txn.snapshot_timestamp))
                    {
                        // This is the visible version we read - track dependency if writer still active
                        if (self.mvcc_manager.active_transactions.contains(version.txn_id)) {
                            try self.dependency_tracker.addReadDependency(txn.id, version.txn_id);
                        }
                    }
                }
            }
        }

        return result;
    }

    /// Enhanced write with comprehensive conflict detection
    pub fn writeWithConflictDetection(
        self: *EnhancedIsolationManager,
        txn: *mvcc.Transaction,
        resource_id: u64,
        data: []const u8,
        isolation: EnhancedIsolationLevel,
    ) !void {
        const start_time = std.time.milliTimestamp();

        // CANARY: REQ=REQ-TXN-ISOLATION-006; FEATURE="SSI Predicate Lock Checking"; ASPECT=PredicateLocks; STATUS=IMPL; OWNER=txn; UPDATED=2025-12-30
        // Check for phantom read conflicts if required
        if (isolation.preventsPhantomReads()) {
            // Check predicate locks - look for conflicting range/predicate locks held by other transactions
            const predicate_conflicts = self.phantom_prevention.checkPredicateConflicts(txn.id, resource_id);
            if (predicate_conflicts) {
                self.conflict_statistics.total_conflicts += 1;
                self.conflict_statistics.phantom_read_conflicts += 1;
                return error.PhantomReadConflict;
            }
        }

        // Perform base MVCC write
        try self.mvcc_manager.write(txn, resource_id, data);

        // CANARY: REQ=REQ-TXN-ISOLATION-007; FEATURE="SSI WR Dependency Tracking"; ASPECT=WriteDependencies; STATUS=IMPL; OWNER=txn; UPDATED=2025-12-30
        // Track dependencies for SSI
        if (isolation == .SerializableSnapshot) {
            // Identify reading transactions and add WR dependencies
            // Check all active transactions to see if any have read this resource
            var active_iter = self.mvcc_manager.active_transactions.iterator();
            while (active_iter.next()) |entry| {
                const other_txn = entry.value_ptr.*;
                if (other_txn.id != txn.id) {
                    // Check if other transaction has read this resource
                    for (other_txn.read_set.items) |read_resource| {
                        if (read_resource == resource_id) {
                            // Other transaction read what we're writing - add WR dependency
                            // (writer depends on reader for serialization order)
                            try self.dependency_tracker.addWriteDependency(txn.id, other_txn.id);
                            break;
                        }
                    }
                }
            }
        }

        // Check for dangerous structures in SSI
        if (isolation == .SerializableSnapshot) {
            if (try self.dependency_tracker.checkDangerousStructure(txn.id)) {
                self.conflict_statistics.total_conflicts += 1;

                const resolution_time = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time));
                self.conflict_statistics.updateResolutionTime(resolution_time);

                return error.SerializationConflict;
            }
        }
    }

    /// Enhanced commit with final validation
    pub fn commitWithValidation(
        self: *EnhancedIsolationManager,
        txn: *mvcc.Transaction,
        isolation: EnhancedIsolationLevel,
    ) !void {
        const start_time = std.time.milliTimestamp();

        // CANARY: REQ=REQ-TXN-ISOLATION-008; FEATURE="SSI Read Set Validation"; ASPECT=CommitValidation; STATUS=IMPL; OWNER=txn; UPDATED=2025-12-30
        // Final phantom read validation for serializable transactions
        if (isolation.preventsPhantomReads()) {
            // Validate read set against concurrent writes
            // Check if any resource we read has been modified by a committed transaction
            // since we started
            for (txn.read_set.items) |read_resource| {
                if (self.mvcc_manager.versions.get(read_resource)) |versions| {
                    for (versions.items) |version| {
                        // Check if a newer version was committed after our snapshot
                        if (version.txn_id != txn.id and
                            version.start_ts > txn.snapshot_timestamp)
                        {
                            // A concurrent transaction modified data we read
                            // Check if that transaction has committed
                            if (!self.mvcc_manager.active_transactions.contains(version.txn_id)) {
                                // The modifying transaction committed - we have a conflict
                                self.conflict_statistics.total_conflicts += 1;
                                self.conflict_statistics.transactions_aborted += 1;

                                const resolution_time = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time));
                                self.conflict_statistics.updateResolutionTime(resolution_time);

                                return error.WriteSkewConflict;
                            }
                        }
                    }
                }
            }
        }

        // SSI final validation
        if (isolation == .SerializableSnapshot) {
            if (try self.dependency_tracker.checkDangerousStructure(txn.id)) {
                self.conflict_statistics.transactions_aborted += 1;

                const resolution_time = @as(f64, @floatFromInt(std.time.milliTimestamp() - start_time));
                self.conflict_statistics.updateResolutionTime(resolution_time);

                return error.SerializationConflict;
            }
        }

        // Perform base MVCC commit
        try self.mvcc_manager.commit(txn);

        // Clean up tracking structures
        self.dependency_tracker.removeDependencies(txn.id);
        self.phantom_prevention.releasePredicateLocks(txn.id);
    }

    /// Enhanced abort with cleanup
    pub fn abortWithCleanup(
        self: *EnhancedIsolationManager,
        txn: *mvcc.Transaction,
    ) !void {
        // Perform base MVCC abort
        try self.mvcc_manager.abort(txn);

        // Clean up tracking structures
        self.dependency_tracker.removeDependencies(txn.id);
        self.phantom_prevention.releasePredicateLocks(txn.id);

        self.conflict_statistics.transactions_aborted += 1;
    }

    /// Periodic deadlock detection and resolution
    pub fn detectAndResolveDeadlocks(self: *EnhancedIsolationManager) !void {
        if (try self.deadlock_detector.detectDeadlock()) |cycle| {
            defer self.allocator.free(cycle.transactions);

            self.conflict_statistics.deadlocks_detected += 1;

            // Abort the victim transaction
            if (self.mvcc_manager.active_transactions.get(cycle.victim)) |victim_txn| {
                try self.abortWithCleanup(victim_txn);
                self.conflict_statistics.deadlocks_resolved += 1;
            }
        }
    }

    /// Get isolation statistics
    pub fn getStatistics(self: *EnhancedIsolationManager) ConflictStatistics {
        return self.conflict_statistics;
    }

    /// Get phantom read statistics
    pub fn getPhantomReadStatistics(self: *EnhancedIsolationManager) phantom_prevention.PhantomReadStats {
        return self.phantom_prevention.getStatistics();
    }
};
