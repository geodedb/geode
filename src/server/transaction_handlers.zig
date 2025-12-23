const std = @import("std");
const ServerState = @import("server_state.zig").ServerState;
const wal_mod = @import("wal");
// CANARY: REQ=REQ-TXN-UNDO-SERVER-001; FEATURE="TransactionUndoLog"; ASPECT=ServerIntegration; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
const txn_undo_log = @import("../txn_undo_log.zig");
const graph_store = @import("../graph_store.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-009; FEATURE="ServerRefactoring"; ASPECT=TRANSACTION_HANDLERS; STATUS=IMPL; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.2 - Transaction Message Handlers Module (Fifth Increment)
// Extracted from server/main.zig to improve modularity and reduce main() function size

/// Get or create MVCC manager (helper function)
fn getOrCreateMVCCManager(allocator: std.mem.Allocator) *@import("txn/mvcc.zig").MVCCManager {
    const mvcc = @import("txn/mvcc.zig");
    // In a real implementation, this should be stored in ServerState
    // For now, we'll create a new one (this is prototype code)
    const manager = allocator.create(mvcc.MVCCManager) catch unreachable;
    manager.* = mvcc.MVCCManager.init(allocator);
    return manager;
}

/// Handle BEGIN transaction message
/// Returns JSON response string (caller must free) or null if no response needed
pub fn handleBegin(allocator: std.mem.Allocator, state: *ServerState) !?[]const u8 {
    if (state.active_txn != null) {
        // Return proper transaction state error with status_class 25000
        return try std.fmt.allocPrint(allocator, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"Transaction already active\",\"additional_statuses\":[{{\"code\":\"TxnState\",\"message\":\"Cannot BEGIN when transaction is already active\"}}]}}\n", .{});
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

        // CANARY: REQ=REQ-TXN-UNDO-SERVER-002; FEATURE="TransactionUndoLog"; ASPECT=BeginTransaction; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
        // Start undo log for tracking changes during this transaction
        const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
        undo_log.begin();

        // Return success with status_class 00000
        return try std.fmt.allocPrint(allocator, "{{\"status_class\":\"00000\",\"result\":{{\"type\":\"TXN_BEGIN\",\"txn_id\":{}}}}}\n", .{t.id});
    }
}

/// Handle COMMIT transaction message
/// Returns JSON response string (caller must free) or null if no response needed
pub fn handleCommit(allocator: std.mem.Allocator, state: *ServerState, env_wal_compact_interval: usize) !?[]const u8 {
    if (state.active_txn == null) {
        // Return proper transaction state error with status_class 25000
        return try std.fmt.allocPrint(allocator, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"No active transaction\",\"additional_statuses\":[{{\"code\":\"TxnState\",\"message\":\"Cannot COMMIT without active transaction\"}}]}}\n", .{});
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
                const err_json = try std.fmt.allocPrint(allocator, "{{\"status_class\":\"40001\",\"status_subclass\":\"SerializationFailure\",\"message\":\"{s}\",\"additional_statuses\":[{{\"code\":\"SerializationFailure\",\"message\":\"Transaction rolled back due to concurrent update\"}}]}}\n", .{err_msg});

                // Clean up transaction state
                state.current_mvcc_txn = null;
                state.active_txn = null;
                state.in_txn = false;
                return err_json;
            };
            state.current_mvcc_txn = null;
        }

        if (!mvcc_commit_success) {
            return null; // Error already returned above
        }

        state.txn_manager.commit(&tx) catch |err| {
            // Handle commit failure (e.g., serialization failure)
            return try std.fmt.allocPrint(allocator, "{{\"status_class\":\"25000\",\"status_subclass\":\"SerializationFailure\",\"message\":\"{s}\",\"additional_statuses\":[{{\"code\":\"SerializationFailure\",\"message\":\"Transaction commit failed due to conflicts\"}}]}}\n", .{@errorName(err)});
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
            const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
            // best-effort: ignore errors in prototype
            // Append commit record; ignore returned LSN (best-effort prototype)
            _ = wptr.append(tx.id, .Commit, &.{}, 0) catch {};
            wptr.fsync() catch {};
        }

        // Periodic WAL checkpoint + compaction after commit
        const do_checkpoint = if (env_wal_compact_interval > 0)
            (state.global_commit_ts % env_wal_compact_interval) == 0
        else
            false; // 0 disables automatic compaction

        state.active_txn = null;
        state.in_txn = false;

        // CANARY: REQ=REQ-TXN-UNDO-SERVER-003; FEATURE="TransactionUndoLog"; ASPECT=CommitTransaction; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
        // Commit the undo log - clears the log and keeps changes
        const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
        undo_log.commit();

        // Return success with status_class 00000
        const success_json = try std.fmt.allocPrint(allocator, "{{\"status_class\":\"00000\",\"result\":{{\"type\":\"TXN_COMMIT\",\"txn_id\":{}}}}}\n", .{tx.id});

        // Perform checkpoint if needed (after returning success)
        if (do_checkpoint) {
            if (state.wal_ptr) |wp_ck| {
                const wck: *wal_mod.Wal = @ptrCast(@alignCast(wp_ck));
                _ = wck.writeCheckpoint() catch {};
                // Use next_lsn as conservative durable horizon for compaction.
                const durable = wck.next_lsn;
                wck.compact(durable) catch {};
                // Log compaction for observability
                std.log.info("WAL compaction triggered after {} commits, durable LSN: {}", .{ env_wal_compact_interval, durable });
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
        return try std.fmt.allocPrint(allocator, "{{\"status_class\":\"25000\",\"status_subclass\":\"TxnState\",\"message\":\"No active transaction\",\"additional_statuses\":[{{\"code\":\"TxnState\",\"message\":\"Cannot ROLLBACK without active transaction\"}}]}}\n", .{});
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

        // CANARY: REQ=REQ-TXN-UNDO-SERVER-004; FEATURE="TransactionUndoLog"; ASPECT=RollbackTransaction; STATUS=IMPL; OWNER=engine; UPDATED=2025-12-23
        // Rollback using the undo log - undoes all changes in reverse order
        const store = graph_store.getGlobalStore(allocator);
        const undo_log = txn_undo_log.getGlobalUndoLog(allocator);
        undo_log.rollback(store) catch |err| {
            std.log.err("Failed to rollback transaction: {any}", .{err});
        };

        state.txn_manager.rollback(&tx2);
        state.active_txn = null;
        state.in_txn = false;

        // Return success with status_class 00000
        return try std.fmt.allocPrint(allocator, "{{\"status_class\":\"00000\",\"result\":{{\"type\":\"TXN_ROLLBACK\",\"txn_id\":{}}}}}\n", .{tx2.id});
    }
}
