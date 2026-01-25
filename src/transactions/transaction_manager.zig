// CANARY: REQ=REQ-0004; FEATURE="Transactions & Storage Requirements"; ASPECT=Storage; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=storage; UPDATED=2026-01-15
// CANARY: REQ=REQ-M7.2-TXN-MANAGER-001; FEATURE="Phase 7 Modularization"; ASPECT=TransactionManager; STATUS=EXEMPT; OWNER=transactions; UPDATED=2025-11-14
// Phase 7 M7.2: Unified transaction management interface
//
// This module provides a centralized interface for all transaction-related operations,
// consolidating access to:
// - MVCC transaction manager (begin, commit, abort, locking)
// - Commit coordination (WAL flush, durability)
// - Two-phase commit (distributed transactions)
// - Advanced MVCC features (conflict detection, skew filtering)
// - Range tracking (phantom read prevention)
//
// By providing a single entry point, this module improves:
// - Code organization and discoverability
// - Maintainability through clear boundaries
// - Testability via unified interface

const std = @import("std");
const manager = @import("manager.zig");
const commit_coordinator = @import("commit_coordinator.zig");
const two_phase_commit = @import("two_phase_commit.zig");
const mvcc_adv = @import("mvcc_adv/mod.zig");
const range_tracker = @import("range_tracker.zig");

// ============================================================================
// Re-export core types for convenience
// ============================================================================

/// MVCC transaction manager types
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-002; FEATURE="MVCC Re-export"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub const TxnId = manager.TxnId;
pub const TxnState = manager.TxnState;
pub const Timestamp = manager.Timestamp;
pub const Txn = manager.Txn;
pub const LockMode = manager.LockMode;
pub const LockEntry = manager.LockEntry;
pub const ConflictType = manager.ConflictType;
pub const ConflictMatrix = manager.ConflictMatrix;
pub const Manager = manager.Manager;

/// Commit coordination types
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-003; FEATURE="Commit Coordination Re-export"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub const WalHandle = commit_coordinator.WalHandle;
pub const registerWal = commit_coordinator.registerWal;
pub const beforeCommit = commit_coordinator.beforeCommit;
pub const ensureWalBeforeData = commit_coordinator.ensureWalBeforeData;

/// Two-phase commit types
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-004; FEATURE="2PC Re-export"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub const Xid = two_phase_commit.Xid;
pub const Decision = two_phase_commit.Decision;
pub const ParticipantState = two_phase_commit.ParticipantState;
pub const Participant = two_phase_commit.Participant;
pub const Coordinator = two_phase_commit.Coordinator;

/// Advanced MVCC features
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-005; FEATURE="Advanced MVCC Re-export"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub const Aggregator = mvcc_adv.Aggregator;

/// Range tracking for phantom prevention
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-006; FEATURE="Range Tracker Re-export"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub const RangeTracker = range_tracker.RangeTracker;

// ============================================================================
// Unified Transaction Manager
// ============================================================================

/// TransactionManager provides a unified interface for all transaction operations
/// Coordinates between MVCC manager, commit coordination, 2PC, and advanced features
///
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-007; FEATURE="Unified Transaction Manager"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub const TransactionManager = struct {
    allocator: std.mem.Allocator,
    mgr: *Manager,
    wal_handle: ?*WalHandle,
    enable_2pc: bool,
    enable_phantom_prevention: bool,

    /// Initialize transaction manager with all components
    ///
    /// Parameters:
    /// - allocator: Memory allocator for transaction operations
    /// - enable_2pc: Enable two-phase commit support
    /// - enable_phantom_prevention: Enable phantom read prevention
    ///
    /// Returns: Initialized TransactionManager or error
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-008; FEATURE="Transaction Manager Init"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn init(
        allocator: std.mem.Allocator,
        enable_2pc: bool,
        enable_phantom_prevention: bool,
    ) !TransactionManager {
        const mgr_inst = try allocator.create(Manager);
        errdefer allocator.destroy(mgr_inst);

        mgr_inst.init(allocator);
        errdefer mgr_inst.deinit();

        // Enable phantom prevention if requested
        if (enable_phantom_prevention) {
            mgr_inst.phantom_enabled = true;
            mgr_inst.rtracker = range_tracker.RangeTracker.init(allocator);
        }

        return .{
            .allocator = allocator,
            .mgr = mgr_inst,
            .wal_handle = null,
            .enable_2pc = enable_2pc,
            .enable_phantom_prevention = enable_phantom_prevention,
        };
    }

    /// Clean up transaction manager resources
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-009; FEATURE="Transaction Manager Cleanup"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn deinit(self: *TransactionManager) void {
        self.mgr.deinit();
        self.allocator.destroy(self.mgr);
    }

    // ========================================================================
    // Transaction Lifecycle Operations
    // ========================================================================

    /// Begin a new transaction
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-010; FEATURE="Begin Transaction"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn begin(self: *TransactionManager) !TxnId {
        return self.mgr.begin();
    }

    /// Commit a transaction
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-011; FEATURE="Commit Transaction"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn commit(self: *TransactionManager, txn_id: TxnId) !void {
        // Ensure WAL durability before commit
        if (self.wal_handle) |wal| {
            const lsn = self.mgr.next_ts;
            try wal.flushUpToFn(lsn);
        }

        return self.mgr.commit(txn_id);
    }

    /// Abort a transaction
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-012; FEATURE="Abort Transaction"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn abort(self: *TransactionManager, txn_id: TxnId) !void {
        return self.mgr.abort(txn_id);
    }

    /// Get transaction state
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-013; FEATURE="Transaction State Query"; ASPECT=Query; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn getState(self: *TransactionManager, txn_id: TxnId) ?TxnState {
        if (self.mgr.active_txns.get(txn_id)) |txn| {
            return txn.state;
        }
        return null;
    }

    // ========================================================================
    // Locking Operations
    // ========================================================================

    /// Acquire a lock on a key
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-014; FEATURE="Lock Acquisition"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn acquireLock(
        self: *TransactionManager,
        txn_id: TxnId,
        key: []const u8,
        mode: LockMode,
    ) !void {
        return self.mgr.lock(txn_id, key, mode);
    }

    /// Release a lock on a key
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-015; FEATURE="Lock Release"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn releaseLock(
        self: *TransactionManager,
        txn_id: TxnId,
        key: []const u8,
    ) !void {
        return self.mgr.unlock(txn_id, key);
    }

    /// Release all locks held by a transaction
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-016; FEATURE="Lock Release All"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn releaseAllLocks(self: *TransactionManager, txn_id: TxnId) void {
        self.mgr.unlockAll(txn_id);
    }

    // ========================================================================
    // Conflict Detection Operations
    // ========================================================================

    /// Check for deadlock
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-017; FEATURE="Deadlock Detection"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn detectDeadlock(self: *TransactionManager, txn_id: TxnId) bool {
        return self.mgr.detectCycle(txn_id);
    }

    /// Add conflict between transactions
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-018; FEATURE="Conflict Recording"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn addConflict(
        self: *TransactionManager,
        t1: TxnId,
        t2: TxnId,
        conflict_type: ConflictType,
    ) !void {
        return self.mgr.conflict_matrix.addConflict(t1, t2, conflict_type);
    }

    /// Check if two transactions have conflicts
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-019; FEATURE="Conflict Check"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn hasConflict(self: *TransactionManager, t1: TxnId, t2: TxnId) bool {
        return self.mgr.conflict_matrix.hasConflict(t1, t2);
    }

    // ========================================================================
    // Advanced MVCC Operations
    // ========================================================================

    /// Enable advanced MVCC features (conflict prediction, skew filtering)
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-020; FEATURE="Advanced MVCC Enable"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn enableAdvancedMVCC(self: *TransactionManager) !void {
        return self.mgr.enableAdvanced();
    }

    /// Note a read access for conflict prediction
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-021; FEATURE="Note Read Access"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn noteRead(self: *TransactionManager, txn_id: TxnId, key: []const u8) !void {
        if (self.mgr.advanced) |*adv| {
            try adv.noteRead(txn_id, key);
        }
    }

    /// Note a write access for conflict prediction
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-022; FEATURE="Note Write Access"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn noteWrite(
        self: *TransactionManager,
        txn_id: TxnId,
        key: []const u8,
        version: u64,
    ) !void {
        if (self.mgr.advanced) |*adv| {
            try adv.noteWrite(txn_id, key, version);
        }
    }

    /// Predict conflict between two transactions
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-023; FEATURE="Conflict Prediction"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn predictConflict(self: *TransactionManager, t1: TxnId, t2: TxnId) bool {
        if (self.mgr.advanced) |*adv| {
            return adv.predictOverlap(t1, t2);
        }
        return false;
    }

    // ========================================================================
    // Phantom Prevention Operations
    // ========================================================================

    /// Track predicate read for phantom prevention
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-024; FEATURE="Predicate Tracking"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn trackPredicate(
        self: *TransactionManager,
        txn_id: TxnId,
        predicate: []const u8,
    ) !void {
        if (!self.enable_phantom_prevention) return;
        return self.mgr.trackPredicate(txn_id, predicate);
    }

    /// Check for phantom reads
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-025; FEATURE="Phantom Detection"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn checkPhantoms(self: *TransactionManager, txn_id: TxnId) !void {
        if (!self.enable_phantom_prevention) return;
        return self.mgr.checkPhantoms(txn_id);
    }

    // ========================================================================
    // WAL Coordination Operations
    // ========================================================================

    /// Register WAL handle for commit coordination
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-026; FEATURE="WAL Registration"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn registerWalHandle(self: *TransactionManager, wal: *WalHandle) void {
        self.wal_handle = wal;
        registerWal(wal);
    }

    /// Ensure WAL is flushed up to LSN
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-027; FEATURE="WAL Flush"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn ensureWalFlushed(self: *TransactionManager, lsn: u64) !void {
        return ensureWalBeforeData(lsn);
    }

    // ========================================================================
    // Two-Phase Commit Operations
    // ========================================================================

    /// Create a 2PC coordinator
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-028; FEATURE="2PC Coordinator"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn createCoordinator(
        self: *TransactionManager,
        xid: Xid,
        participants: []Participant,
    ) !Coordinator {
        if (!self.enable_2pc) return error.TwoPhaseCommitDisabled;
        return Coordinator.init(xid, participants);
    }

    /// Drive prepare phase for 2PC
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-029; FEATURE="2PC Prepare"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn prepare2PC(self: *TransactionManager, coordinator: *Coordinator) !void {
        if (!self.enable_2pc) return error.TwoPhaseCommitDisabled;
        return coordinator.drivePrepare();
    }

    /// Make commit/abort decision for 2PC
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-030; FEATURE="2PC Decision"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn decide2PC(
        self: *TransactionManager,
        coordinator: *Coordinator,
        commit_flag: bool,
    ) !void {
        if (!self.enable_2pc) return error.TwoPhaseCommitDisabled;
        return coordinator.decide(commit_flag);
    }

    /// Drive commit/abort phase for 2PC
    ///
    /// CANARY: REQ=REQ-M7.2-TXN-MANAGER-031; FEATURE="2PC Commit"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
    pub fn commitOrAbort2PC(self: *TransactionManager, coordinator: *Coordinator) !void {
        if (!self.enable_2pc) return error.TwoPhaseCommitDisabled;
        return coordinator.driveCommitOrAbort();
    }
};

// ============================================================================
// Convenience Functions
// ============================================================================

/// Create a new TransactionManager instance with default settings
///
/// This is the recommended way to initialize transaction management for the database.
///
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-032; FEATURE="Transaction Manager Factory"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub fn createTransactionManager(allocator: std.mem.Allocator) !TransactionManager {
    return TransactionManager.init(allocator, false, false);
}

/// Create a TransactionManager with phantom prevention enabled
///
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-033; FEATURE="Transaction Manager with Phantom Prevention"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub fn createWithPhantomPrevention(allocator: std.mem.Allocator) !TransactionManager {
    return TransactionManager.init(allocator, false, true);
}

/// Create a TransactionManager with 2PC enabled
///
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-034; FEATURE="Transaction Manager with 2PC"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub fn createWith2PC(allocator: std.mem.Allocator) !TransactionManager {
    return TransactionManager.init(allocator, true, false);
}

/// Create a TransactionManager with all advanced features enabled
///
/// CANARY: REQ=REQ-M7.2-TXN-MANAGER-035; FEATURE="Transaction Manager Full Features"; ASPECT=Core; STATUS=TESTED; TEST=geodetestlab/specs/geode_transaction_manager.yml; OWNER=core; UPDATED=2026-01-25
pub fn createWithAllFeatures(allocator: std.mem.Allocator) !TransactionManager {
    return TransactionManager.init(allocator, true, true);
}
