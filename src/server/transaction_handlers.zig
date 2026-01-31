const std = @import("std");
const ServerState = @import("server_state.zig").ServerState;
const wal_mod = @import("wal");
const wal_manager = @import("wal_manager.zig");
// CANARY: REQ=REQ-TXN-UNDO-SERVER-001; FEATURE="TransactionUndoLog"; ASPECT=ServerIntegration; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
const txn_undo_log = @import("../txn_undo_log.zig");
const graph_store = @import("../graph_store.zig");
// CANARY: REQ=REQ-TXN-UNDO-SERVER-016; FEATURE="TransactionUndoLog"; ASPECT=GraphStorageImport; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
const graph_storage_mgr = @import("graph_storage_manager.zig");
const graph_exec = @import("graph/exec.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-016; FEATURE="Structured Logging"; ASPECT=TransactionHandlers; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-056; FEATURE="JSON Library Migration"; ASPECT=TransactionHandlers; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const json_lib = @import("json");

// JSON response types for transaction operations
const TxnStateError = struct {
    status_class: []const u8 = "25000",
    status_subclass: []const u8 = "TxnState",
    message: []const u8,
    additional_statuses: []const AdditionalStatus,

    const AdditionalStatus = struct {
        code: []const u8 = "TxnState",
        message: []const u8,
    };
};

const SerializationError = struct {
    status_class: []const u8 = "40001",
    status_subclass: []const u8 = "SerializationFailure",
    message: []const u8,
    additional_statuses: []const AdditionalStatus,

    const AdditionalStatus = struct {
        code: []const u8 = "SerializationFailure",
        message: []const u8,
    };
};

const CommitError = struct {
    status_class: []const u8 = "25000",
    status_subclass: []const u8 = "SerializationFailure",
    message: []const u8,
    additional_statuses: []const AdditionalStatus,

    const AdditionalStatus = struct {
        code: []const u8 = "SerializationFailure",
        message: []const u8,
    };
};

const TxnSuccessResponse = struct {
    status_class: []const u8 = "00000",
    result: TxnResult,

    const TxnResult = struct {
        type: []const u8,
        txn_id: u64,
    };
};

// CANARY: REQ=REQ-SERVER-REFACTOR-009; FEATURE="ServerRefactoring"; ASPECT=TRANSACTION_HANDLERS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.2 - Transaction Message Handlers Module (Fifth Increment)
// Extracted from server/main.zig to improve modularity and reduce main() function size

/// Get graph storage for the current session, falling back to default if no graph selected
fn getSessionGraphStorage(allocator: std.mem.Allocator, state: *ServerState) *graph_exec.GraphStorage {
    // Try to get graph by session's current_graph name
    if (graph_storage_mgr.getGraphStorageByName(state.current_graph)) |storage| {
        return storage;
    }
    // Fall back to default graph
    return graph_storage_mgr.getOrCreateGraphStorage(allocator);
}

/// Get or create MVCC manager (helper function)
fn getOrCreateMVCCManager(allocator: std.mem.Allocator) *@import("txn/mvcc.zig").MVCCManager {
    const mvcc = @import("txn/mvcc.zig");
    // In a real implementation, this should be stored in ServerState
    // For now, we'll create a new one (this is prototype code)
    const manager = allocator.create(mvcc.MVCCManager) catch unreachable;
    manager.* = mvcc.MVCCManager.init(allocator);
    return manager;
}

fn rollbackActiveTransaction(allocator: std.mem.Allocator, state: *ServerState) void {
    if (state.active_txn == null) return;
    var tx = state.active_txn.?;

    // Abort MVCC transaction if still tracked
    if (state.current_mvcc_txn) |mvcc_txn| {
        state.mvcc_manager.?.abortTransaction(mvcc_txn) catch {};
        state.current_mvcc_txn = null;
    }

    // Mark uncommitted inserts for this txn as aborted
    var ia: usize = 0;
    while (ia < state.inserted_values.items.len) : (ia += 1) {
        if (state.inserted_values.items[ia].creator_txn == tx.id and state.inserted_values.items[ia].commit_ts == null) {
            state.inserted_values.items[ia].aborted = true;
        }
    }

    // Rollback undo log changes (if any)
    const session_storage = getSessionGraphStorage(allocator, state);
    const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
    undo_log.rollbackGraphStorage(session_storage);

    state.txn_manager.rollback(&tx);
    state.active_txn = null;
    state.in_txn = false;
}

/// Handle BEGIN transaction message
/// Returns JSON response string (caller must free) or null if no response needed
pub fn handleBegin(allocator: std.mem.Allocator, state: *ServerState) !?[]const u8 {
    if (state.active_txn != null) {
        // Return proper transaction state error with status_class 25000
        const err_response = TxnStateError{
            .message = "Transaction already active",
            .additional_statuses = &[_]TxnStateError.AdditionalStatus{
                .{ .message = "Cannot BEGIN when transaction is already active" },
            },
        };
        const json_str = try json_lib.encode(allocator, err_response, .{});
        defer allocator.free(json_str);
        const result = try allocator.alloc(u8, json_str.len + 1);
        @memcpy(result[0..json_str.len], json_str);
        result[json_str.len] = '\n';
        return result;
    } else {
        const t = state.txn_manager.begin();
        state.active_txn = t;
        state.in_txn = true;
        state.txn_id = t.id;
        // Capture snapshot timestamp (current global commit ts)
        state.session_snapshot_ts = state.global_commit_ts;

        // Initialize MVCC transaction for conflict detection
        if (state.mvcc_manager == null) {
            state.mvcc_manager = getOrCreateMVCCManager(allocator);
        }
        state.current_mvcc_txn = state.mvcc_manager.?.beginTransaction(.SnapshotIsolation) catch null;

        // CANARY: REQ=REQ-TXN-UNDO-SERVER-002; FEATURE="TransactionUndoLog"; ASPECT=BeginTransaction; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
        // Start undo log for tracking changes during this transaction
        const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
        undo_log.begin();

        // Return success with status_class 00000
        const success_response = TxnSuccessResponse{
            .result = .{ .type = "TXN_BEGIN", .txn_id = t.id },
        };
        const json_str = try json_lib.encode(allocator, success_response, .{});
        defer allocator.free(json_str);
        const result = try allocator.alloc(u8, json_str.len + 1);
        @memcpy(result[0..json_str.len], json_str);
        result[json_str.len] = '\n';
        return result;
    }
}

/// Handle COMMIT transaction message
/// Returns JSON response string (caller must free) or null if no response needed
pub fn handleCommit(allocator: std.mem.Allocator, state: *ServerState, env_wal_compact_interval: usize) !?[]const u8 {
    if (state.active_txn == null) {
        // Return proper transaction state error with status_class 25000
        const err_response = TxnStateError{
            .message = "No active transaction",
            .additional_statuses = &[_]TxnStateError.AdditionalStatus{
                .{ .message = "Cannot COMMIT without active transaction" },
            },
        };
        const json_str = try json_lib.encode(allocator, err_response, .{});
        defer allocator.free(json_str);
        const result = try allocator.alloc(u8, json_str.len + 1);
        @memcpy(result[0..json_str.len], json_str);
        result[json_str.len] = '\n';
        return result;
    } else {
        var tx = state.active_txn.?;

        // Try to commit MVCC transaction first for conflict detection
        var mvcc_commit_success = true;
        if (state.current_mvcc_txn) |mvcc_txn| {
            state.mvcc_manager.?.commitTransaction(mvcc_txn) catch |err| {
                mvcc_commit_success = false;
                // Handle serialization failure
                const err_msg = switch (err) {
                    error.SerializationFailure => "Write-write conflict detected",
                    else => "Transaction commit failed",
                };
                const ser_error = SerializationError{
                    .message = err_msg,
                    .additional_statuses = &[_]SerializationError.AdditionalStatus{
                        .{ .message = "Transaction rolled back due to concurrent update" },
                    },
                };
                const json_str = try json_lib.encode(allocator, ser_error, .{});
                defer allocator.free(json_str);
                const err_json = try allocator.alloc(u8, json_str.len + 1);
                @memcpy(err_json[0..json_str.len], json_str);
                err_json[json_str.len] = '\n';

                // Clean up transaction state
                state.current_mvcc_txn = null;
                rollbackActiveTransaction(allocator, state);
                return err_json;
            };
            state.current_mvcc_txn = null;
        }

        if (!mvcc_commit_success) {
            return null; // Error already returned above
        }

        state.txn_manager.commit(&tx) catch |err| {
            // Handle commit failure (e.g., serialization failure)
            const commit_error = CommitError{
                .message = @errorName(err),
                .additional_statuses = &[_]CommitError.AdditionalStatus{
                    .{ .message = "Transaction commit failed due to conflicts" },
                },
            };
            const json_str = try json_lib.encode(allocator, commit_error, .{});
            defer allocator.free(json_str);
            const result = try allocator.alloc(u8, json_str.len + 1);
            @memcpy(result[0..json_str.len], json_str);
            result[json_str.len] = '\n';
            rollbackActiveTransaction(allocator, state);
            return result;
        };

        // Assign commit timestamp to newly committed records from this txn
        state.global_commit_ts += 1;
        const cts = state.global_commit_ts;
        var i_mvcc: usize = 0;
        while (i_mvcc < state.inserted_values.items.len) : (i_mvcc += 1) {
            if (state.inserted_values.items[i_mvcc].creator_txn == tx.id and state.inserted_values.items[i_mvcc].commit_ts == null) {
                state.inserted_values.items[i_mvcc].commit_ts = cts;
            }
        }

        // Append WAL commit record (empty payload) if WAL configured.
        if (state.wal_ptr) |wp| {
            const wptr: *wal_manager.WalManager = @ptrCast(@alignCast(wp));
            // Best-effort: ignore errors in prototype.
            _ = wptr.appendAndFsync(tx.id, wal_mod.RecordType.Commit, &.{}, 0) catch {};
        }

        // Periodic WAL checkpoint + compaction after commit
        const do_checkpoint = if (env_wal_compact_interval > 0)
            (state.global_commit_ts % env_wal_compact_interval) == 0
        else
            false; // 0 disables automatic compaction

        state.active_txn = null;
        state.in_txn = false;

        // CANARY: REQ=REQ-TXN-UNDO-SERVER-003; FEATURE="TransactionUndoLog"; ASPECT=CommitTransaction; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
        // Commit the undo log - clears the log and keeps changes
        const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
        undo_log.commit();

        // Return success with status_class 00000
        const success_response = TxnSuccessResponse{
            .result = .{ .type = "TXN_COMMIT", .txn_id = tx.id },
        };
        const json_str = try json_lib.encode(allocator, success_response, .{});
        defer allocator.free(json_str);
        const success_json = try allocator.alloc(u8, json_str.len + 1);
        @memcpy(success_json[0..json_str.len], json_str);
        success_json[json_str.len] = '\n';

        // Perform checkpoint if needed (after returning success)
        if (do_checkpoint) {
            if (state.wal_ptr) |wp_ck| {
                const wck: *wal_manager.WalManager = @ptrCast(@alignCast(wp_ck));
                const durable = wck.checkpointAndCompact() catch null;
                if (durable) |d_lsn| {
                    // Log compaction for observability
                    log.info("WAL compaction triggered", &.{ Attr.int("commits_interval", @intCast(env_wal_compact_interval)), Attr.int("durable_lsn", @intCast(d_lsn)) });
                }
            }
        }

        return success_json;
    }
}

/// Handle ROLLBACK transaction message
/// Returns JSON response string (caller must free) or null if no response needed
pub fn handleRollback(allocator: std.mem.Allocator, state: *ServerState) !?[]const u8 {
    if (state.active_txn == null) {
        // Return proper transaction state error with status_class 25000
        const err_response = TxnStateError{
            .message = "No active transaction",
            .additional_statuses = &[_]TxnStateError.AdditionalStatus{
                .{ .message = "Cannot ROLLBACK without active transaction" },
            },
        };
        const json_str = try json_lib.encode(allocator, err_response, .{});
        defer allocator.free(json_str);
        const result = try allocator.alloc(u8, json_str.len + 1);
        @memcpy(result[0..json_str.len], json_str);
        result[json_str.len] = '\n';
        return result;
    } else {
        var tx2 = state.active_txn.?;

        // Abort MVCC transaction
        if (state.current_mvcc_txn) |mvcc_txn| {
            state.mvcc_manager.?.abortTransaction(mvcc_txn) catch {};
            state.current_mvcc_txn = null;
        }

        // Mark uncommitted inserts for this txn as aborted
        var ia: usize = 0;
        while (ia < state.inserted_values.items.len) : (ia += 1) {
            if (state.inserted_values.items[ia].creator_txn == tx2.id and state.inserted_values.items[ia].commit_ts == null) {
                state.inserted_values.items[ia].aborted = true;
            }
        }

        // CANARY: REQ=REQ-TXN-UNDO-SERVER-004; FEATURE="TransactionUndoLog"; ASPECT=RollbackTransaction; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
        // Rollback using the undo log - undoes all changes in reverse order
        // Use session graph storage for server-side rollback
        const session_storage = getSessionGraphStorage(allocator, state);
        const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
        undo_log.rollbackGraphStorage(session_storage);

        state.txn_manager.rollback(&tx2);
        state.active_txn = null;
        state.in_txn = false;

        // Return success with status_class 00000
        const success_response = TxnSuccessResponse{
            .result = .{ .type = "TXN_ROLLBACK", .txn_id = tx2.id },
        };
        const json_str = try json_lib.encode(allocator, success_response, .{});
        defer allocator.free(json_str);
        const result = try allocator.alloc(u8, json_str.len + 1);
        @memcpy(result[0..json_str.len], json_str);
        result[json_str.len] = '\n';
        return result;
    }
}
