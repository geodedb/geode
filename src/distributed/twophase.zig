const std = @import("std");

/// Two-Phase Commit transaction states
pub const TransactionState = enum {
    active,
    preparing,
    prepared,
    committing,
    committed,
    aborting,
    aborted,
};

/// 2PC message types
pub const MessageType = enum {
    prepare,
    prepare_response,
    commit,
    commit_response,
    abort,
    abort_response,
    recovery_request,
    recovery_response,
};

/// Participant response to prepare
pub const PrepareResponse = enum {
    vote_commit,
    vote_abort,
    timeout,
};

/// Transaction participant information
pub const Participant = struct {
    id: []const u8,
    endpoint: []const u8,
    state: TransactionState,
    last_message_time: i64,
    prepare_response: ?PrepareResponse,
};

/// 2PC transaction context
pub const Transaction = struct {
    id: []const u8,
    coordinator_id: []const u8,
    participants: std.ArrayList(Participant),
    state: TransactionState,
    start_time: i64,
    timeout_ms: u64,
    operations: std.ArrayList([]const u8),
    
    pub fn init(allocator: std.mem.Allocator, id: []const u8, coordinator_id: []const u8) Transaction {
        return .{
            .id = id,
            .coordinator_id = coordinator_id,
            .participants = std.ArrayList(Participant).initCapacity(allocator, 0) catch @panic("OOM"),
            .state = .active,
            .start_time = std.time.timestamp(),
            .timeout_ms = 30000, // 30 seconds default
            .operations = std.ArrayList([]const u8).initCapacity(allocator, 0) catch @panic("OOM"),
        };
    }
    
    pub fn deinit(self: *Transaction, allocator: std.mem.Allocator) void {
        for (self.participants.items) |participant| {
            allocator.free(participant.id);
            allocator.free(participant.endpoint);
        }
        self.participants.deinit(allocator);
        
        for (self.operations.items) |op| {
            allocator.free(op);
        }
        self.operations.deinit(allocator);
        
        allocator.free(self.id);
        allocator.free(self.coordinator_id);
    }
    
    pub fn addParticipant(self: *Transaction, allocator: std.mem.Allocator, id: []const u8, endpoint: []const u8) !void {
        const participant = Participant{
            .id = try allocator.dupe(u8, id),
            .endpoint = try allocator.dupe(u8, endpoint),
            .state = .active,
            .last_message_time = std.time.timestamp(),
            .prepare_response = null,
        };
        try self.participants.append(allocator, participant);
    }
    
    pub fn addOperation(self: *Transaction, allocator: std.mem.Allocator, operation: []const u8) !void {
        try self.operations.append(allocator, try allocator.dupe(u8, operation));
    }
    
    pub fn isTimedOut(self: *const Transaction) bool {
        const now = std.time.timestamp();
        return (now - self.start_time) * 1000 > @as(i64, @intCast(self.timeout_ms));
    }
    
    pub fn allParticipantsPrepared(self: *const Transaction) bool {
        for (self.participants.items) |participant| {
            if (participant.prepare_response != .vote_commit) {
                return false;
            }
        }
        return true;
    }
    
    pub fn anyParticipantAborted(self: *const Transaction) bool {
        for (self.participants.items) |participant| {
            if (participant.prepare_response == .vote_abort) {
                return true;
            }
        }
        return false;
    }
};

/// 2PC Coordinator configuration
pub const CoordinatorConfig = struct {
    coordinator_id: []const u8,
    default_timeout_ms: u64 = 30000,
    max_concurrent_transactions: usize = 1000,
    recovery_interval_ms: u64 = 5000,
    participant_timeout_ms: u64 = 10000,
};

/// Two-Phase Commit Coordinator
pub const TwoPCCoordinator = struct {
    allocator: std.mem.Allocator,
    config: CoordinatorConfig,
    
    // Active transactions
    transactions: std.StringHashMap(Transaction),
    
    // Recovery state
    recovery_log: std.ArrayList([]const u8),
    
    // Callbacks for integration
    send_message_callback: ?*const fn ([]const u8, MessageType, []const u8) void,
    local_prepare_callback: ?*const fn ([]const u8, []const []const u8) PrepareResponse,
    local_commit_callback: ?*const fn ([]const u8, []const []const u8) bool,
    local_abort_callback: ?*const fn ([]const u8, []const []const u8) bool,
    
    // Feature flags
    enable_distributed_transactions: bool = false,
    enable_recovery: bool = false,
    
    pub fn init(allocator: std.mem.Allocator, config: CoordinatorConfig) TwoPCCoordinator {
        return .{
            .allocator = allocator,
            .config = config,
            .transactions = std.StringHashMap(Transaction).init(allocator),
            .recovery_log = std.ArrayList([]const u8).initCapacity(allocator, 0) catch @panic("OOM"),
            .send_message_callback = null,
            .local_prepare_callback = null,
            .local_commit_callback = null,
            .local_abort_callback = null,
        };
    }
    
    pub fn deinit(self: *TwoPCCoordinator) void {
        var iter = self.transactions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.transactions.deinit();
        
        for (self.recovery_log.items) |log_entry| {
            self.allocator.free(log_entry);
        }
        self.recovery_log.deinit(self.allocator);
    }
    
    /// Enable 2PC features (for gradual rollout)
    pub fn enableFeatures(self: *TwoPCCoordinator, distributed_transactions: bool, recovery: bool) void {
        self.enable_distributed_transactions = distributed_transactions;
        self.enable_recovery = recovery;
    }
    
    /// Begin a new distributed transaction
    pub fn beginTransaction(self: *TwoPCCoordinator, transaction_id: []const u8, participants: []const []const u8) !bool {
        if (self.transactions.count() >= self.config.max_concurrent_transactions) {
            return false;
        }
        
        var txn = Transaction.init(self.allocator, 
            try self.allocator.dupe(u8, transaction_id),
            try self.allocator.dupe(u8, self.config.coordinator_id));
        
        // Add participants
        for (participants) |participant| {
            try txn.addParticipant(self.allocator, participant, participant); // Using ID as endpoint for simplicity
        }
        
        try self.transactions.put(transaction_id, txn);
        
        if (self.enable_recovery) {
            try self.logTransactionStart(transaction_id);
        }
        
        return true;
    }
    
    /// Add an operation to a transaction
    pub fn addOperation(self: *TwoPCCoordinator, transaction_id: []const u8, operation: []const u8) !bool {
        var txn = self.transactions.getPtr(transaction_id) orelse return false;
        
        if (txn.state != .active) {
            return false;
        }
        
        try txn.addOperation(self.allocator, operation);
        return true;
    }
    
    /// Commit a transaction (initiates 2PC protocol)
    pub fn commitTransaction(self: *TwoPCCoordinator, transaction_id: []const u8) !bool {
        var txn = self.transactions.getPtr(transaction_id) orelse return false;
        
        if (txn.state != .active) {
            return false;
        }
        
        if (!self.enable_distributed_transactions) {
            // Single-node mode: commit locally
            return self.commitLocal(txn);
        }
        
        // Start prepare phase
        txn.state = .preparing;
        
        if (self.enable_recovery) {
            try self.logTransactionPreparing(transaction_id);
        }
        
        return true;
    }
    
    /// Abort a transaction
    pub fn abortTransaction(self: *TwoPCCoordinator, transaction_id: []const u8) !bool {
        var txn = self.transactions.getPtr(transaction_id) orelse return false;
        
        if (txn.state == .committed or txn.state == .aborted) {
            return false;
        }
        
        txn.state = .aborting;
        
        if (self.enable_recovery) {
            try self.logTransactionAborting(transaction_id);
        }
        
        if (!self.enable_distributed_transactions) {
            _ = self.abortLocal(txn);
        }
        
        txn.state = .aborted;
        return true;
    }
    
    /// Handle incoming 2PC messages
    pub fn handleMessage(self: *TwoPCCoordinator, from: []const u8, message_type: MessageType, payload: []const u8) !void {
        _ = self;
        _ = from;
        _ = message_type;
        _ = payload;
        // Message handling not fully implemented in v0.15.0
    }
    
    /// Process periodic tasks (timeouts, recovery, etc.)
    pub fn tick(self: *TwoPCCoordinator) !void {
        try self.processTimeouts();
        
        if (self.enable_recovery) {
            try self.processRecovery();
        }
    }
    
    /// Get transaction statistics
    pub fn getStats(self: *const TwoPCCoordinator) struct {
        active_transactions: usize,
        total_transactions: usize,
        committed_transactions: usize,
        aborted_transactions: usize,
    } {
        var committed: usize = 0;
        var aborted: usize = 0;
        
        var iter = self.transactions.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.state) {
                .committed => committed += 1,
                .aborted => aborted += 1,
                else => {},
            }
        }
        
        return .{
            .active_transactions = self.transactions.count(),
            .total_transactions = self.transactions.count(),
            .committed_transactions = committed,
            .aborted_transactions = aborted,
        };
    }
    
    // Private methods
    
    fn commitLocal(self: *TwoPCCoordinator, txn: *Transaction) bool {
        if (self.local_commit_callback) |callback| {
            return callback(txn.id, txn.operations.items);
        }
        return true; // Default success for testing
    }
    
    fn abortLocal(self: *TwoPCCoordinator, txn: *Transaction) bool {
        if (self.local_abort_callback) |callback| {
            return callback(txn.id, txn.operations.items);
        }
        return true; // Default success for testing
    }
    
    fn processTimeouts(self: *TwoPCCoordinator) !void {
        var to_abort = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch @panic("OOM");
        defer to_abort.deinit(self.allocator);
        
        var iter = self.transactions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isTimedOut()) {
                try to_abort.append(self.allocator, entry.key_ptr.*);
            }
        }
        
        for (to_abort.items) |txn_id| {
            _ = try self.abortTransaction(txn_id);
        }
    }
    
    fn processRecovery(self: *TwoPCCoordinator) !void {
        // Recovery processing not fully implemented in v0.15.0
        _ = self;
    }
    
    fn logTransactionStart(self: *TwoPCCoordinator, transaction_id: []const u8) !void {
        const log_entry = try std.fmt.allocPrint(self.allocator, "START {s}", .{transaction_id});
        try self.recovery_log.append(self.allocator, log_entry);
    }
    
    fn logTransactionPreparing(self: *TwoPCCoordinator, transaction_id: []const u8) !void {
        const log_entry = try std.fmt.allocPrint(self.allocator, "PREPARING {s}", .{transaction_id});
        try self.recovery_log.append(self.allocator, log_entry);
    }
    
    fn logTransactionAborting(self: *TwoPCCoordinator, transaction_id: []const u8) !void {
        const log_entry = try std.fmt.allocPrint(self.allocator, "ABORTING {s}", .{transaction_id});
        try self.recovery_log.append(self.allocator, log_entry);
    }
};

// Tests
test "2pc coordinator initialization" {
    const config = CoordinatorConfig{
        .coordinator_id = "coord1",
    };
    
    var coordinator = TwoPCCoordinator.init(std.testing.allocator, config);
    defer coordinator.deinit();
    
    const stats = coordinator.getStats();
    try std.testing.expect(stats.active_transactions == 0);
}

test "2pc single node transaction" {
    const config = CoordinatorConfig{
        .coordinator_id = "coord1",
    };
    
    var coordinator = TwoPCCoordinator.init(std.testing.allocator, config);
    defer coordinator.deinit();
    
    // Begin transaction
    const success = try coordinator.beginTransaction("txn1", &[_][]const u8{});
    try std.testing.expect(success);
    
    // Add operation
    const op_success = try coordinator.addOperation("txn1", "INSERT INTO table VALUES (1)");
    try std.testing.expect(op_success);
    
    // Commit transaction (single-node mode)
    const commit_success = try coordinator.commitTransaction("txn1");
    try std.testing.expect(commit_success);
}

test "2pc transaction timeout" {
    const config = CoordinatorConfig{
        .coordinator_id = "coord1",
        .default_timeout_ms = 100, // Very short timeout for testing
    };
    
    var coordinator = TwoPCCoordinator.init(std.testing.allocator, config);
    defer coordinator.deinit();
    
    // Begin transaction
    _ = try coordinator.beginTransaction("txn1", &[_][]const u8{"participant1"});
    
    // Wait for timeout
    std.time.sleep(150 * std.time.ns_per_ms);
    
    // Process timeouts
    try coordinator.tick();
    
    // Transaction should be aborted
    const txn = coordinator.transactions.get("txn1");
    try std.testing.expect(txn != null);
    try std.testing.expect(txn.?.state == .aborted);
}