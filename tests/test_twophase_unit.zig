const std = @import("std");
const geode = @import("geode");
const twophase = geode.distributed.twophase;

// --- Test send functions ---

/// A send function that always returns VOTE_COMMIT (simulates all participants agreeing).
fn sendCommitVote(
    _: ?*anyopaque,
    _: []const u8,
    _: twophase.TwoPhaseMessage,
    _: u64,
) anyerror!twophase.TwoPhaseResponse {
    return twophase.TwoPhaseResponse{
        .msg_type = .PREPARE,
        .transaction_id = "",
        .participant_id = "",
        .vote = .VOTE_COMMIT,
        .timestamp = 0,
    };
}

/// A send function that always returns VOTE_ABORT (simulates a participant refusing).
fn sendAbortVote(
    _: ?*anyopaque,
    _: []const u8,
    _: twophase.TwoPhaseMessage,
    _: u64,
) anyerror!twophase.TwoPhaseResponse {
    return twophase.TwoPhaseResponse{
        .msg_type = .PREPARE,
        .transaction_id = "",
        .participant_id = "",
        .vote = .VOTE_ABORT,
        .timestamp = 0,
    };
}

/// A send function that always returns a connection error.
fn sendNetworkError(
    _: ?*anyopaque,
    _: []const u8,
    _: twophase.TwoPhaseMessage,
    _: u64,
) anyerror!twophase.TwoPhaseResponse {
    return error.ConnectionFailed;
}

/// GAP-0889: votes commit during PREPARE, then the participant becomes
/// unreachable for the COMMIT delivery — the classic "decided but not acked"
/// 2PC failure window.
fn sendCommitVoteThenFailCommit(
    _: ?*anyopaque,
    _: []const u8,
    msg: twophase.TwoPhaseMessage,
    _: u64,
) anyerror!twophase.TwoPhaseResponse {
    if (msg.msg_type == .COMMIT) return error.ConnectionFailed;
    return twophase.TwoPhaseResponse{
        .msg_type = .PREPARE,
        .transaction_id = "",
        .participant_id = "",
        .vote = .VOTE_COMMIT,
        .timestamp = 0,
    };
}

// --- Tests ---

test "Transaction: init produces active state" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-001",
        "coord-1",
        sendCommitVote,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    try std.testing.expectEqual(twophase.TransactionState.active, txn.state);
    try std.testing.expectEqualStrings("txn-001", txn.id);
    try std.testing.expectEqualStrings("coord-1", txn.coordinator_id);
    try std.testing.expectEqual(@as(usize, 0), txn.participants.items.len);
    try std.testing.expectEqual(@as(usize, 0), txn.operations.items.len);
    try std.testing.expectEqual(twophase.IsolationLevel.read_committed, txn.isolation_level);
}

test "Transaction: addParticipant accumulates participants" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-002",
        "coord-1",
        sendCommitVote,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "host1:5000");
    try txn.addParticipant("p2", "host2:5000");

    try std.testing.expectEqual(@as(usize, 2), txn.participants.items.len);
    try std.testing.expectEqualStrings("p1", txn.participants.items[0].id);
    try std.testing.expectEqualStrings("host2:5000", txn.participants.items[1].endpoint);
    try std.testing.expectEqual(twophase.TransactionState.active, txn.participants.items[0].state);
}

test "Transaction: prepare with all VOTE_COMMIT transitions to prepared" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-003",
        "coord-1",
        sendCommitVote,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "host1:5000");
    try txn.addParticipant("p2", "host2:5000");

    const can_commit = try txn.prepare();
    try std.testing.expect(can_commit);
    try std.testing.expectEqual(twophase.TransactionState.prepared, txn.state);
}

test "Transaction: prepare with VOTE_ABORT transitions to aborting" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-004",
        "coord-1",
        sendAbortVote,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "host1:5000");

    const can_commit = try txn.prepare();
    try std.testing.expect(!can_commit);
    try std.testing.expectEqual(twophase.TransactionState.aborting, txn.state);
}

test "Transaction: prepare with network error transitions to aborting" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-005",
        "coord-1",
        sendNetworkError,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "host1:5000");

    const can_commit = try txn.prepare();
    try std.testing.expect(!can_commit);
    try std.testing.expectEqual(twophase.TransactionState.aborting, txn.state);
    // Network error should be treated as VOTE_TIMEOUT
    try std.testing.expectEqual(twophase.PrepareResponse.VOTE_TIMEOUT, txn.participants.items[0].prepare_response.?);
}

test "Transaction: commit after prepare transitions to committed" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-006",
        "coord-1",
        sendCommitVote,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "host1:5000");

    const can_commit = try txn.prepare();
    try std.testing.expect(can_commit);

    try txn.commit();
    try std.testing.expectEqual(twophase.TransactionState.committed, txn.state);
    // All participants should also be committed
    try std.testing.expectEqual(twophase.TransactionState.committed, txn.participants.items[0].state);
}

test "Transaction: commit surfaces undelivered participant instead of reporting success (GAP-0889)" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-gap0889",
        "coord-1",
        sendCommitVoteThenFailCommit,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "host1:5000");

    const can_commit = try txn.prepare();
    try std.testing.expect(can_commit);

    // The COMMIT decision is made (2PC point of no return), but delivery to
    // the participant exhausts its retries. The old code marked the
    // participant .committed anyway and reported success — it must surface
    // the incomplete delivery instead.
    try std.testing.expectError(error.CommitDeliveryIncomplete, txn.commit());

    // The decision itself is still commit...
    try std.testing.expectEqual(twophase.TransactionState.committed, txn.state);
    // ...but the unreachable participant must NOT be recorded as committed.
    try std.testing.expect(txn.participants.items[0].state != .committed);
}

test "Transaction: commit without prepare returns InvalidState" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-007",
        "coord-1",
        sendCommitVote,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    // Attempt to commit without preparing first
    const result = txn.commit();
    try std.testing.expectError(error.InvalidState, result);
}

test "Transaction: abort transitions to aborted" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-008",
        "coord-1",
        sendCommitVote,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "host1:5000");

    try txn.abort();
    try std.testing.expectEqual(twophase.TransactionState.aborted, txn.state);
    try std.testing.expectEqual(twophase.TransactionState.aborted, txn.participants.items[0].state);
}

test "Transaction: createSavepoint and rollbackToSavepoint" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-009",
        "coord-1",
        sendCommitVote,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    // Create a savepoint with no operations
    try txn.createSavepoint("sp1");
    try std.testing.expectEqual(@as(usize, 1), txn.savepoints.items.len);
    try std.testing.expectEqualStrings("sp1", txn.savepoints.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), txn.savepoints.items[0].operation_index);

    // Rollback to savepoint (no operations to remove)
    try txn.rollbackToSavepoint("sp1");

    // Rollback to non-existent savepoint
    const result = txn.rollbackToSavepoint("nonexistent");
    try std.testing.expectError(error.SavepointNotFound, result);
}

test "Transaction: prepare with no participants succeeds (vacuous truth)" {
    const allocator = std.testing.allocator;
    var txn = try twophase.Transaction.init(
        allocator,
        "txn-010",
        "coord-1",
        sendCommitVote,
        null,
        30_000,
        null,
    );
    defer txn.deinit();

    // No participants added -- prepare should succeed (no votes to collect)
    const can_commit = try txn.prepare();
    try std.testing.expect(can_commit);
    try std.testing.expectEqual(twophase.TransactionState.prepared, txn.state);
}

test "Coordinator: init and deinit" {
    const allocator = std.testing.allocator;
    var coord = twophase.Coordinator.init(allocator, "node-1");
    defer coord.deinit();

    try std.testing.expectEqual(@as(u64, 30_000), coord.default_timeout_ms);
    try std.testing.expect(coord.log_writer == null);
}

test "Coordinator: beginTransaction creates transaction" {
    const allocator = std.testing.allocator;
    var coord = twophase.Coordinator.init(allocator, "node-1");
    coord.send_fn = sendCommitVote;
    defer coord.deinit();

    const txn = try coord.beginTransaction("txn-100");
    try std.testing.expectEqualStrings("txn-100", txn.id);
    try std.testing.expectEqual(twophase.TransactionState.active, txn.state);
}

test "Coordinator: executeTransaction with commit votes returns true" {
    const allocator = std.testing.allocator;
    var coord = twophase.Coordinator.init(allocator, "node-1");
    coord.send_fn = sendCommitVote;
    defer coord.deinit();

    const txn = try coord.beginTransaction("txn-101");
    try txn.addParticipant("p1", "host1:5000");

    const committed = try coord.executeTransaction("txn-101");
    try std.testing.expect(committed);
}

test "Coordinator: executeTransaction with abort votes returns false" {
    const allocator = std.testing.allocator;
    var coord = twophase.Coordinator.init(allocator, "node-1");
    coord.send_fn = sendAbortVote;
    defer coord.deinit();

    const txn = try coord.beginTransaction("txn-102");
    try txn.addParticipant("p1", "host1:5000");

    const committed = try coord.executeTransaction("txn-102");
    try std.testing.expect(!committed);
}
