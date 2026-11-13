// SONNY-6487 item 6: ServerState carried `mvcc_manager` and
// `current_mvcc_txn` (src/server/txn/mvcc.zig types) that nothing set or
// read, so every connection state advertised an MVCC conflict detector the
// server never ran (docs/ENHANCED_TRANSACTION_ISOLATION.md). The fields are
// removed; this pins that they do not come back without a real caller.

const std = @import("std");
const geode = @import("geode");
const ServerState = geode.server_state.ServerState;

test "SONNY-6487: ServerState has no unused MVCC manager fields" {
    try std.testing.expect(!@hasField(ServerState, "mvcc_manager"));
    try std.testing.expect(!@hasField(ServerState, "current_mvcc_txn"));
    // The connection's real MVCC state (the inserted-value heap and its
    // commit/snapshot timestamps) is unaffected.
    try std.testing.expect(@hasField(ServerState, "inserted_values"));
    try std.testing.expect(@hasField(ServerState, "global_commit_ts"));
    try std.testing.expect(@hasField(ServerState, "session_snapshot_ts"));
}
