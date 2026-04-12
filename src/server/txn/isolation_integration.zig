// CANARY: REQ=REQ-TXN-ISOLATION-INTEGRATION-001; FEATURE="Transaction Isolation Integration"; ASPECT=ServerIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_TXN_ISOLATION_INTEGRATION_001_ServerIntegration; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-ISOLATION-INTEGRATION-002; FEATURE="Query Engine Integration"; ASPECT=QueryEngineIntegration; STATUS=TESTED; TEST=TestCANARY_REQ_TXN_ISOLATION_INTEGRATION_002_QueryEngineIntegration; OWNER=txn; UPDATED=2025-10-05

const std = @import("std");
const mvcc = @import("mvcc.zig");
const enhanced_isolation = @import("enhanced_isolation.zig");
const geode = @import("geode");
const pooled = @import("transport/thread_pool");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-017; FEATURE="Structured Logging"; ASPECT=IsolationIntegration; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

/// Transaction isolation integration for the main server
pub const IsolationIntegration = struct {
    allocator: std.mem.Allocator,
    mvcc_manager: *mvcc.MVCCManager,
    enhanced_manager: enhanced_isolation.EnhancedIsolationManager,

    // Configuration
    default_isolation: enhanced_isolation.EnhancedIsolationLevel = .SnapshotIsolation,
    enable_deadlock_detection: bool = true,
    detection_interval_ms: u32 = 1000,

    // Background deadlock detection worker
    deadlock_pool: ?*pooled.ThreadPool = null,
    shutdown_deadlock_detection: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, mvcc_manager: *mvcc.MVCCManager) !IsolationIntegration {
        var enhanced_manager = try enhanced_isolation.EnhancedIsolationManager.init(allocator, mvcc_manager);

        return IsolationIntegration{
            .allocator = allocator,
            .mvcc_manager = mvcc_manager,
            .enhanced_manager = enhanced_manager,
        };
    }

    pub fn deinit(self: *IsolationIntegration) void {
        // Shutdown deadlock detection
        if (self.deadlock_pool) |pool| {
            self.shutdown_deadlock_detection.store(true, .Monotonic);
            pool.deinit();
            self.deadlock_pool = null;
        }

        self.enhanced_manager.deinit();
    }

    /// Start the background deadlock detection thread
    pub fn startDeadlockDetection(self: *IsolationIntegration) !void {
        if (!self.enable_deadlock_detection or self.deadlock_pool != null) {
            return;
        }

        const pool = try pooled.ThreadPool.init(self.allocator, .{
            .num_threads = 1,
            .queue_capacity = 4,
        });
        errdefer pool.deinit();
        try pool.submitBlocking(.{
            .context = @ptrCast(self),
            .callback = runDeadlockDetectionLoop,
        });
        self.deadlock_pool = pool;
    }

    /// Background deadlock detection loop
    fn deadlockDetectionLoop(self: *IsolationIntegration) void {
        while (!self.shutdown_deadlock_detection.load(.Monotonic)) {
            // Perform deadlock detection
            self.enhanced_manager.detectAndResolveDeadlocks() catch |err| {
                // Log error but continue detection
                log.err("Deadlock detection error", &.{Attr.string("error", @errorName(err))});
            };

            // Sleep for the configured interval
            std.time.sleep(self.detection_interval_ms * std.time.ns_per_ms);
        }
    }

    fn runDeadlockDetectionLoop(ctx: *anyopaque) void {
        const self: *IsolationIntegration = @ptrCast(@alignCast(ctx));
        self.deadlockDetectionLoop();
    }

    /// Begin transaction with specified isolation level
    pub fn beginTransaction(
        self: *IsolationIntegration,
        isolation: ?enhanced_isolation.EnhancedIsolationLevel,
        priority: ?u32,
    ) !*mvcc.Transaction {
        const actual_isolation = isolation orelse self.default_isolation;
        const actual_priority = priority orelse 100; // Default medium priority

        return self.enhanced_manager.beginTransactionWithIsolation(actual_isolation, actual_priority);
    }

    /// Read operation with enhanced conflict detection
    pub fn read(
        self: *IsolationIntegration,
        txn: *mvcc.Transaction,
        resource_id: u64,
        isolation: ?enhanced_isolation.EnhancedIsolationLevel,
    ) !?[]const u8 {
        const actual_isolation = isolation orelse self.default_isolation;
        return self.enhanced_manager.readWithConflictDetection(txn, resource_id, actual_isolation);
    }

    /// Write operation with enhanced conflict detection
    pub fn write(
        self: *IsolationIntegration,
        txn: *mvcc.Transaction,
        resource_id: u64,
        data: []const u8,
        isolation: ?enhanced_isolation.EnhancedIsolationLevel,
    ) !void {
        const actual_isolation = isolation orelse self.default_isolation;
        return self.enhanced_manager.writeWithConflictDetection(txn, resource_id, data, actual_isolation);
    }

    /// Commit transaction with enhanced validation
    pub fn commit(
        self: *IsolationIntegration,
        txn: *mvcc.Transaction,
        isolation: ?enhanced_isolation.EnhancedIsolationLevel,
    ) !void {
        const actual_isolation = isolation orelse self.default_isolation;
        return self.enhanced_manager.commitWithValidation(txn, actual_isolation);
    }

    /// Abort transaction with cleanup
    pub fn abort(self: *IsolationIntegration, txn: *mvcc.Transaction) !void {
        return self.enhanced_manager.abortWithCleanup(txn);
    }

    /// Get isolation statistics for monitoring
    pub fn getStatistics(self: *IsolationIntegration) enhanced_isolation.EnhancedIsolationManager.ConflictStatistics {
        return self.enhanced_manager.getStatistics();
    }

    /// Get phantom read statistics
    pub fn getPhantomReadStatistics(self: *IsolationIntegration) @import("phantom_read_prevention.zig").PhantomReadStats {
        return self.enhanced_manager.getPhantomReadStatistics();
    }

    /// Configure isolation settings
    pub fn configure(
        self: *IsolationIntegration,
        default_isolation: ?enhanced_isolation.EnhancedIsolationLevel,
        enable_deadlock_detection: ?bool,
        detection_interval_ms: ?u32,
    ) void {
        if (default_isolation) |iso| {
            self.default_isolation = iso;
        }

        if (enable_deadlock_detection) |enable| {
            self.enable_deadlock_detection = enable;
        }

        if (detection_interval_ms) |interval| {
            self.detection_interval_ms = interval;
        }
    }
};

/// Query-level transaction isolation helpers
pub const QueryIsolation = struct {
    /// Parse isolation level from query string or configuration
    pub fn parseIsolationLevel(iso_str: ?[]const u8) enhanced_isolation.EnhancedIsolationLevel {
        if (iso_str) |str| {
            if (std.mem.eql(u8, str, "READ_UNCOMMITTED")) return .ReadUncommitted;
            if (std.mem.eql(u8, str, "READ_COMMITTED")) return .ReadCommitted;
            if (std.mem.eql(u8, str, "REPEATABLE_READ")) return .RepeatableRead;
            if (std.mem.eql(u8, str, "SERIALIZABLE")) return .Serializable;
            if (std.mem.eql(u8, str, "SNAPSHOT_ISOLATION")) return .SnapshotIsolation;
            if (std.mem.eql(u8, str, "SERIALIZABLE_SNAPSHOT")) return .SerializableSnapshot;
        }

        return .SnapshotIsolation; // Default
    }

    /// Get isolation level description for error messages
    pub fn getIsolationDescription(isolation: enhanced_isolation.EnhancedIsolationLevel) []const u8 {
        return switch (isolation) {
            .ReadUncommitted => "READ UNCOMMITTED",
            .ReadCommitted => "READ COMMITTED",
            .RepeatableRead => "REPEATABLE READ",
            .Serializable => "SERIALIZABLE",
            .SnapshotIsolation => "SNAPSHOT ISOLATION",
            .SerializableSnapshot => "SERIALIZABLE SNAPSHOT ISOLATION",
        };
    }

    /// Check if isolation level requires special handling
    pub fn requiresSpecialHandling(isolation: enhanced_isolation.EnhancedIsolationLevel) bool {
        return isolation == .Serializable or isolation == .SerializableSnapshot;
    }
};

/// Server state integration helpers
pub const ServerIntegration = struct {
    /// Add isolation integration to server state
    pub fn initializeServerIsolation(
        allocator: std.mem.Allocator,
        mvcc_manager: *mvcc.MVCCManager,
    ) !*IsolationIntegration {
        var integration = try allocator.create(IsolationIntegration);
        integration.* = try IsolationIntegration.init(allocator, mvcc_manager);

        // Start background deadlock detection
        try integration.startDeadlockDetection();

        return integration;
    }

    /// Cleanup server isolation integration
    pub fn deinitializeServerIsolation(allocator: std.mem.Allocator, integration: *IsolationIntegration) void {
        integration.deinit();
        allocator.destroy(integration);
    }

    /// Handle transaction BEGIN with isolation level
    pub fn handleBeginTransaction(
        integration: *IsolationIntegration,
        isolation_str: ?[]const u8,
        priority: ?u32,
    ) !*mvcc.Transaction {
        const isolation = QueryIsolation.parseIsolationLevel(isolation_str);
        return integration.beginTransaction(isolation, priority);
    }

    /// Handle COMMIT with validation
    pub fn handleCommitTransaction(
        integration: *IsolationIntegration,
        txn: *mvcc.Transaction,
        isolation_str: ?[]const u8,
    ) !void {
        const isolation = QueryIsolation.parseIsolationLevel(isolation_str);
        try integration.commit(txn, isolation);
    }

    /// Handle ROLLBACK
    pub fn handleRollbackTransaction(
        integration: *IsolationIntegration,
        txn: *mvcc.Transaction,
    ) !void {
        try integration.abort(txn);
    }

    /// Format isolation statistics for monitoring
    pub fn formatIsolationStatistics(
        allocator: std.mem.Allocator,
        integration: *IsolationIntegration,
    ) ![]u8 {
        const stats = integration.getStatistics();
        const phantom_stats = integration.getPhantomReadStatistics();

        return std.fmt.allocPrint(allocator,
            \\{{
            \\  "total_conflicts": {},
            \\  "phantom_read_conflicts": {},
            \\  "deadlocks_detected": {},
            \\  "deadlocks_resolved": {},
            \\  "transactions_aborted": {},
            \\  "average_resolution_time_ms": {d:.2},
            \\  "predicate_locks_active": {},
            \\  "range_queries_validated": {}
            \\}}
        , .{
            stats.total_conflicts,
            stats.phantom_read_conflicts,
            stats.deadlocks_detected,
            stats.deadlocks_resolved,
            stats.transactions_aborted,
            stats.average_resolution_time_ms,
            phantom_stats.active_predicate_locks,
            phantom_stats.range_queries_validated,
        });
    }
};
