const std = @import("std");

// Transaction isolation levels
pub const IsolationLevel = enum {
    ReadUncommitted,
    ReadCommitted,
    RepeatableRead,
    Serializable,
    SnapshotIsolation, // Default for geode
};

// Transaction ID type
pub const TxnId = u64;
pub const Timestamp = u64;

// Lock modes for concurrency control
pub const LockMode = enum {
    None,
    Shared,      // Read lock
    Exclusive,   // Write lock
    IntentShared,
    IntentExclusive,
};

// Lock request structure
pub const LockRequest = struct {
    txn_id: TxnId,
    mode: LockMode,
    resource_id: u64, // Could be node_id, edge_id, or page_id
    granted: bool = false,
    waiting_since: ?Timestamp = null,
};

// Transaction state
pub const TxnState = enum {
    Active,
    Preparing,   // For 2PC
    Prepared,    // For 2PC
    Committing,
    Committed,
    Aborting,
    Aborted,
};

// Write operation for conflict detection
pub const WriteOp = struct {
    resource_id: u64,
    timestamp: Timestamp,
    old_value: ?[]const u8 = null,
    new_value: []const u8,
};

// Transaction context
pub const Transaction = struct {
    id: TxnId,
    state: TxnState,
    isolation_level: IsolationLevel,
    start_timestamp: Timestamp,
    commit_timestamp: ?Timestamp,
    snapshot_timestamp: Timestamp, // For MVCC
    
    // Locks held by this transaction
    locks_held: std.ArrayList(LockRequest),
    
    // Write set for conflict detection
    write_set: std.ArrayList(WriteOp),
    
    // Read set for validation
    read_set: std.ArrayList(u64), // Resource IDs read
    
    // Conflict tracking
    conflicts_detected: std.ArrayList(ConflictInfo),
    
    pub fn init(allocator: std.mem.Allocator, id: TxnId, timestamp: Timestamp, isolation: IsolationLevel) Transaction {
        return .{
            .id = id,
            .state = .Active,
            .isolation_level = isolation,
            .start_timestamp = timestamp,
            .commit_timestamp = null,
            .snapshot_timestamp = timestamp,
            .locks_held = std.ArrayList(LockRequest).initCapacity(allocator, 0) catch unreachable,
            .write_set = std.ArrayList(WriteOp).initCapacity(allocator, 0) catch unreachable,
            .read_set = std.ArrayList(u64).initCapacity(allocator, 0) catch unreachable,
            .conflicts_detected = std.ArrayList(ConflictInfo).initCapacity(allocator, 0) catch unreachable,
        };
    }
    
    pub fn deinit(self: *Transaction) void {
        self.locks_held.deinit();
        self.write_set.deinit();
        self.read_set.deinit();
        self.conflicts_detected.deinit();
    }
};

// Conflict information for diagnostics
pub const ConflictInfo = struct {
    conflicting_txn: TxnId,
    resource_id: u64,
    conflict_type: ConflictType,
    timestamp: Timestamp,
};

// Types of conflicts that can occur
pub const ConflictType = enum {
    WriteWrite,     // Two transactions writing same resource
    WriteRead,      // Write-read conflict (dirty read prevention)
    ReadWrite,      // Read-write conflict (lost update prevention)
    PhantomRead,    // Phantom read conflict
    Deadlock,       // Deadlock detected
};

// Lock manager for concurrency control
pub const LockManager = struct {
    // Lock table: resource_id -> list of lock requests
    lock_table: std.AutoHashMap(u64, std.ArrayList(LockRequest)),
    
    // Wait-for graph for deadlock detection
    wait_for: std.AutoHashMap(TxnId, TxnId),
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) LockManager {
        return .{
            .lock_table = std.AutoHashMap(u64, std.ArrayList(LockRequest)).init(allocator),
            .wait_for = std.AutoHashMap(TxnId, TxnId).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *LockManager) void {
        var iter = self.lock_table.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.lock_table.deinit();
        self.wait_for.deinit();
    }
    
    // Request a lock
    pub fn requestLock(self: *LockManager, txn: *Transaction, resource_id: u64, mode: LockMode) !bool {
        // Check for lock compatibility
        var requests = self.lock_table.get(resource_id) orelse blk: {
            const list = std.ArrayList(LockRequest).initCapacity(self.allocator, 0) catch unreachable;
            try self.lock_table.put(resource_id, list);
            break :blk self.lock_table.get(resource_id).?;
        };
        
        // Check if we already hold a lock on this resource
        for (requests.items) |req| {
            if (req.txn_id == txn.id and req.granted) {
                // Check if we need to upgrade
                if (isStrongerLock(mode, req.mode)) {
                    // Upgrade logic would go here
                    return true;
                }
                return true; // Already have sufficient lock
            }
        }
        
        // Check compatibility with existing locks
        var can_grant = true;
        for (requests.items) |req| {
            if (req.granted and !isCompatible(mode, req.mode)) {
                can_grant = false;
                // Add to wait-for graph
                try self.wait_for.put(txn.id, req.txn_id);
                
                // Check for deadlock
                if (try self.detectDeadlock(txn.id)) {
                    return false; // Deadlock detected, abort
                }
                break;
            }
        }
        
        // Create lock request
        const lock_req = LockRequest{
            .txn_id = txn.id,
            .mode = mode,
            .resource_id = resource_id,
            .granted = can_grant,
            .waiting_since = if (!can_grant) @intCast(std.time.timestamp()) else null,
        };
        
        try requests.append(self.allocator, lock_req);
        try txn.locks_held.append(self.allocator, lock_req);
        
        return can_grant;
    }
    
    // Release all locks held by a transaction
    pub fn releaseLocks(self: *LockManager, txn: *Transaction) !void {
        for (txn.locks_held.items) |lock| {
            if (self.lock_table.getPtr(lock.resource_id)) |requests| {
                // Remove this transaction's lock
                var i: usize = 0;
                while (i < requests.items.len) {
                    if (requests.items[i].txn_id == txn.id) {
                        _ = requests.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
                
                // Grant waiting locks if possible
                for (requests.items) |*req| {
                    if (!req.granted) {
                        var can_grant = true;
                        for (requests.items) |other| {
                            if (other.granted and !isCompatible(req.mode, other.mode)) {
                                can_grant = false;
                                break;
                            }
                        }
                        if (can_grant) {
                            req.granted = true;
                            req.waiting_since = null;
                        }
                    }
                }
            }
        }
        
        // Clear wait-for entries
        _ = self.wait_for.remove(txn.id);
        
        txn.locks_held.clearRetainingCapacity();
    }
    
    // Simple cycle detection for deadlock
    fn detectDeadlock(self: *LockManager, start_txn: TxnId) !bool {
        var visited = std.AutoHashMap(TxnId, void).init(self.allocator);
        defer visited.deinit();
        
        var current = start_txn;
        while (self.wait_for.get(current)) |next| {
            if (next == start_txn) {
                return true; // Cycle detected
            }
            if (visited.contains(next)) {
                break; // Already visited, no cycle on this path
            }
            try visited.put(current, {});
            current = next;
        }
        
        return false;
    }
    
    fn isCompatible(mode1: LockMode, mode2: LockMode) bool {
        // Lock compatibility matrix
        return switch (mode1) {
            .None => true,
            .Shared => mode2 == .None or mode2 == .Shared or mode2 == .IntentShared,
            .Exclusive => mode2 == .None,
            .IntentShared => mode2 != .Exclusive,
            .IntentExclusive => mode2 == .None or mode2 == .IntentShared,
        };
    }
    
    fn isStrongerLock(new: LockMode, existing: LockMode) bool {
        // Lock strength ordering: None < IS < S < IX < X
        const strength = [_]u8{ 0, 2, 4, 1, 3 }; // None, S, X, IS, IX
        return strength[@intFromEnum(new)] > strength[@intFromEnum(existing)];
    }
};

// MVCC Manager for snapshot isolation
pub const MVCCManager = struct {
    current_timestamp: Timestamp,
    active_transactions: std.AutoHashMap(TxnId, *Transaction),
    lock_manager: LockManager,
    
    // Version chain for MVCC (simplified - in practice would be per-record)
    versions: std.AutoHashMap(u64, std.ArrayList(Version)),
    
    allocator: std.mem.Allocator,
    
    const Version = struct {
        timestamp: Timestamp,
        txn_id: TxnId,
        data: []const u8,
        deleted: bool = false,
    };
    
    pub fn init(allocator: std.mem.Allocator) MVCCManager {
        return .{
            .current_timestamp = 1,
            .active_transactions = std.AutoHashMap(TxnId, *Transaction).init(allocator),
            .lock_manager = LockManager.init(allocator),
            .versions = std.AutoHashMap(u64, std.ArrayList(Version)).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MVCCManager) void {
        self.active_transactions.deinit();
        self.lock_manager.deinit();
        
        var iter = self.versions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.versions.deinit();
    }
    
    pub fn beginTransaction(self: *MVCCManager, isolation: IsolationLevel) !*Transaction {
        const txn_id = self.current_timestamp;
        self.current_timestamp += 1;
        
        const txn = try self.allocator.create(Transaction);
        txn.* = Transaction.init(self.allocator, txn_id, txn_id, isolation);
        
        try self.active_transactions.put(txn_id, txn);
        return txn;
    }
    
    pub fn read(self: *MVCCManager, txn: *Transaction, resource_id: u64) !?[]const u8 {
        // Acquire shared lock for repeatable read
        if (txn.isolation_level == .RepeatableRead or txn.isolation_level == .Serializable) {
            if (!try self.lock_manager.requestLock(txn, resource_id, .Shared)) {
                return error.LockTimeout;
            }
        }
        
        // Track read for validation
        try txn.read_set.append(self.allocator, resource_id);
        
        // Find visible version
        if (self.versions.get(resource_id)) |version_chain| {
            // Find the latest version visible to this transaction
            var visible_version: ?Version = null;
            for (version_chain.items) |ver| {
                if (ver.timestamp <= txn.snapshot_timestamp) {
                    if (visible_version == null or ver.timestamp > visible_version.?.timestamp) {
                        visible_version = ver;
                    }
                }
            }
            
            if (visible_version) |ver| {
                if (ver.deleted) return null;
                return ver.data;
            }
        }
        
        return null;
    }
    
    pub fn write(self: *MVCCManager, txn: *Transaction, resource_id: u64, data: []const u8) !void {
        // Acquire exclusive lock
        if (!try self.lock_manager.requestLock(txn, resource_id, .Exclusive)) {
            return error.WriteConflict;
        }
        
        // Check for write-write conflicts
        if (self.versions.get(resource_id)) |version_chain| {
            for (version_chain.items) |ver| {
                // Check if another transaction wrote after our snapshot
                if (ver.timestamp > txn.snapshot_timestamp and ver.txn_id != txn.id) {
                    // Write-write conflict detected
                    txn.state = .Aborting;
                    return error.SerializationFailure;
                }
            }
        }
        
        // Add to write set
        try txn.write_set.append(self.allocator, .{
            .resource_id = resource_id,
            .timestamp = self.current_timestamp,
            .new_value = data,
        });
    }
    
    pub fn commitTransaction(self: *MVCCManager, txn: *Transaction) !void {
        if (txn.state != .Active) {
            return error.InvalidTransactionState;
        }
        
        txn.state = .Committing;
        
        // Validate read set for serializable isolation
        if (txn.isolation_level == .Serializable) {
            for (txn.read_set.items) |resource_id| {
                if (self.versions.get(resource_id)) |version_chain| {
                    for (version_chain.items) |ver| {
                        if (ver.timestamp > txn.snapshot_timestamp and ver.timestamp < self.current_timestamp) {
                            // Read validation failed
                            txn.state = .Aborting;
                            return error.SerializationFailure;
                        }
                    }
                }
            }
        }
        
        // Apply writes
        const commit_timestamp = self.current_timestamp;
        self.current_timestamp += 1;
        
        for (txn.write_set.items) |write_op| {
            var version_chain = self.versions.get(write_op.resource_id) orelse blk: {
                const chain = std.ArrayList(Version).initCapacity(self.allocator, 0) catch unreachable;
                try self.versions.put(write_op.resource_id, chain);
                break :blk self.versions.get(write_op.resource_id).?;
            };
            
            try version_chain.append(self.allocator, .{
                .timestamp = commit_timestamp,
                .txn_id = txn.id,
                .data = write_op.new_value,
            });
        }
        
        txn.commit_timestamp = commit_timestamp;
        txn.state = .Committed;
        
        // Release locks
        try self.lock_manager.releaseLocks(txn);
        
        // Remove from active transactions
        _ = self.active_transactions.remove(txn.id);
    }
    
    pub fn abortTransaction(self: *MVCCManager, txn: *Transaction) !void {
        txn.state = .Aborting;
        
        // Release all locks
        try self.lock_manager.releaseLocks(txn);
        
        // Clear write set (nothing to undo in MVCC)
        txn.write_set.clearRetainingCapacity();
        
        txn.state = .Aborted;
        
        // Remove from active transactions
        _ = self.active_transactions.remove(txn.id);
    }
    
    // Garbage collection of old versions
    pub fn garbageCollect(self: *MVCCManager) !void {
        // Find minimum snapshot timestamp of active transactions
        var min_snapshot: Timestamp = self.current_timestamp;
        var iter = self.active_transactions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.snapshot_timestamp < min_snapshot) {
                min_snapshot = entry.value_ptr.*.snapshot_timestamp;
            }
        }
        
        // Remove versions older than min_snapshot (keeping at least one)
        var version_iter = self.versions.iterator();
        while (version_iter.next()) |entry| {
            var chain = entry.value_ptr;
            if (chain.items.len > 1) {
                // Keep only versions visible to active transactions
                var i: usize = 0;
                while (i < chain.items.len - 1) {
                    if (chain.items[i].timestamp < min_snapshot) {
                        _ = chain.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }
    }
    
    // Enhanced conflict detection matrix
    pub fn detectConflict(self: *MVCCManager, txn: *Transaction, resource_id: u64, operation: enum { Read, Write }) !?ConflictInfo {
        // Check against all active transactions
        var iter = self.active_transactions.iterator();
        while (iter.next()) |entry| {
            const other_txn = entry.value_ptr.*;
            if (other_txn.id == txn.id) continue;
            
            // Check write-write conflicts
            if (operation == .Write) {
                for (other_txn.write_set.items) |write_op| {
                    if (write_op.resource_id == resource_id) {
                        // Write-write conflict detected
                        const conflict = ConflictInfo{
                            .conflicting_txn = other_txn.id,
                            .resource_id = resource_id,
                            .conflict_type = .WriteWrite,
                            .timestamp = self.current_timestamp,
                        };
                        try txn.conflicts_detected.append(self.allocator, conflict);
                        return conflict;
                    }
                }
                
                // Check read-write conflicts (lost update prevention)
                for (other_txn.read_set.items) |read_id| {
                    if (read_id == resource_id and other_txn.start_timestamp < txn.start_timestamp) {
                        const conflict = ConflictInfo{
                            .conflicting_txn = other_txn.id,
                            .resource_id = resource_id,
                            .conflict_type = .ReadWrite,
                            .timestamp = self.current_timestamp,
                        };
                        try txn.conflicts_detected.append(self.allocator, conflict);
                        return conflict;
                    }
                }
            }
            
            // Check write-read conflicts (dirty read prevention)
            if (operation == .Read) {
                for (other_txn.write_set.items) |write_op| {
                    if (write_op.resource_id == resource_id and 
                        other_txn.state != .Committed and
                        txn.isolation_level != .ReadUncommitted) {
                        const conflict = ConflictInfo{
                            .conflicting_txn = other_txn.id,
                            .resource_id = resource_id,
                            .conflict_type = .WriteRead,
                            .timestamp = self.current_timestamp,
                        };
                        try txn.conflicts_detected.append(self.allocator, conflict);
                        return conflict;
                    }
                }
            }
        }
        
        return null;
    }
    
    // Map conflict to ISO SQL error code 40001 (serialization failure)
    pub fn conflictToError(conflict: ConflictInfo) !@import("protocol").DiagnosticInfo {
        const protocol = @import("protocol");
        return protocol.DiagnosticInfo{
            .status_class = "40",
            .status_subclass = "001",
            .message = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "Serialization failure: {s} conflict on resource {} with transaction {}",
                .{ @tagName(conflict.conflict_type), conflict.resource_id, conflict.conflicting_txn }
            ),
            .anchor = null,
        };
    }
    
    // Validate transaction at commit time
    pub fn validateTransaction(self: *MVCCManager, txn: *Transaction) !bool {
        // For snapshot isolation, check for write-write conflicts
        if (txn.isolation_level == .SnapshotIsolation) {
            for (txn.write_set.items) |write_op| {
                // Check if any other transaction has written to this resource
                // since our snapshot
                var iter = self.active_transactions.iterator();
                while (iter.next()) |entry| {
                    const other_txn = entry.value_ptr.*;
                    if (other_txn.id == txn.id) continue;
                    if (other_txn.state != .Committed) continue;
                    
                    for (other_txn.write_set.items) |other_write| {
                        if (other_write.resource_id == write_op.resource_id and
                            other_write.timestamp > txn.snapshot_timestamp and
                            other_write.timestamp < self.current_timestamp) {
                            // Conflict detected - abort transaction
                            const conflict = ConflictInfo{
                                .conflicting_txn = other_txn.id,
                                .resource_id = write_op.resource_id,
                                .conflict_type = .WriteWrite,
                                .timestamp = self.current_timestamp,
                            };
                            try txn.conflicts_detected.append(self.allocator, conflict);
                            return false;
                        }
                    }
                }
            }
        }
        
        // For serializable, also check for phantom reads
        if (txn.isolation_level == .Serializable) {
            // Additional validation for phantom reads would go here
            // This requires tracking predicate locks and range queries
        }
        
        return true;
    }
};