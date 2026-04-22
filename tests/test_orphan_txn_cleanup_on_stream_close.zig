// Regression test for R3 — orphaned transaction on QUIC stream close.
//
// Triage: `state.in_txn` is set to true in the QUIC BEGIN handler
// (src/server/quic_connection_handler.zig:2977) and the process-global
// undo log is activated at the same time.  If the QUIC stream then closes
// *without* a matching COMMIT/ROLLBACK — for example, because the client
// disconnected mid-chunk during the 16-worker ingest workload — nothing
// runs the rollback path.
//
// Consequences:
//   - `state.in_txn` stays `true`, so the next BEGIN on a reused session
//     sees "transaction already in progress" and the client wedges.
//   - The global undo log keeps stale entries; a later BEGIN from ANY
//     session calls `clear()` on them, freeing memory under another
//     handler's feet (aliased with R1).
//   - `ServerState` has no `deinit`; the only cleanup path is
//     `invalidateAuthenticatedSession` (src/server/quic_connection_handler.zig:1696)
//     and that only runs when the HELLO handshake fails.
//
// Desired contract (pinned by this test):
//   ServerState exposes a teardown hook (`tearDownForStreamClose`) that:
//     (a) releases `in_txn`,
//     (b) rolls back the undo log (or flushes its entries for the
//         orphaned transaction),
//     (c) is safe to call when no transaction is in flight.
//
// This test uses a unit-level seam: we set `state.in_txn = true` and append
// a few undo entries to the global log (simulating BEGIN + CREATE ...),
// then call `tearDownForStreamClose`.  After R3 is fixed, the hook will
// return cleanly, `in_txn` will be false, and the undo log will be empty.
// Today the hook is a stub that returns `error.NotImplemented`, so the
// test fails with that exact error — proving the missing seam.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const server_state_mod = geode.server_state;
const txn_undo_log = geode.txn_undo_log;

test "ServerState has a teardown hook for QUIC stream close (R3)" {
    const allocator = testing.allocator;

    // Start from a clean undo log — other tests in the binary may have
    // left residue.
    {
        const undo = txn_undo_log.getGlobalUndoLog(allocator);
        undo.active = false;
        undo.clear();
    }

    var state = server_state_mod.ServerState{
        .allocator = allocator,
    };

    // Simulate the QUIC BEGIN handler path:
    // src/server/quic_connection_handler.zig:2973-2977 flips `in_txn` and
    // activates the global undo log.
    state.in_txn = true;
    state.txn_id = 42;

    const undo = txn_undo_log.getGlobalUndoLog(allocator);
    undo.begin();
    // Simulate a CREATE inside the transaction — this is what the ingest
    // workload does, 38 statements at a time.
    try undo.logCreateNode(9999, "default");
    try testing.expect(undo.entries.items.len > 0);

    // Ensure we don't leave the global undo log dirty even if the test
    // errors below.
    defer {
        const u = txn_undo_log.getGlobalUndoLog(allocator);
        u.active = false;
        u.clear();
    }

    // This is the hook the transport SHOULD call from the stream-close
    // path (analogous to invalidateAuthenticatedSession at
    // src/server/quic_connection_handler.zig:1696 but keyed on stream
    // termination, not auth-handshake failure).
    //
    // Today `tearDownForStreamClose` is a stub returning
    // error.NotImplemented — the regression evidence that no such hook
    // exists.  Once R3 is fixed, replace the stub with a real rollback
    // and these assertions become meaningful.
    state.tearDownForStreamClose(null) catch |err| {
        std.debug.print(
            "ServerState.tearDownForStreamClose returned {s} — no " ++
                "teardown hook runs when a QUIC stream closes with an " ++
                "open transaction.  See R3 in the triage " ++
                "(src/server/quic_connection_handler.zig:1696-1722, " ++
                "2960-3036; src/server/server_state.zig:250-384).\n",
            .{@errorName(err)},
        );
        return error.StreamCloseTeardownMissing;
    };

    // After the hook runs, the session must no longer claim to be in a
    // transaction, and the global undo log must be empty of the orphaned
    // entries.  (Unreachable today — the stub errors above.)
    if (state.in_txn) {
        std.debug.print(
            "tearDownForStreamClose returned OK but left state.in_txn=true\n",
            .{},
        );
        return error.InTxnFlagNotCleared;
    }
    if (undo.entries.items.len != 0) {
        std.debug.print(
            "tearDownForStreamClose returned OK but left {d} orphaned " ++
                "undo-log entries\n",
            .{undo.entries.items.len},
        );
        return error.OrphanedUndoEntriesRemain;
    }
}
