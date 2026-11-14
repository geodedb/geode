//! SONNY-6548 reproduction (intentionally red until fixed; KNOWN_TEST_ISSUES).
//!
//! `raft_persistent.RaftNode` (src/distributed/raft_persistent.zig, exported
//! as `geode.distributed.raft_persistent`) persists only `current_term`:
//! savePersistentState writes the `current_term` file and loadPersistentState
//! reads it back, and `voted_for` is in neither, so a reopened node has
//! `voted_for = null` in a term it already voted in. Raft's hard state is
//! (currentTerm, votedFor); a node that forgets its vote can vote twice in one
//! term. src/distributed/README.md says the file "provides durable state
//! across restarts".
//!
//! Scope: the server does not use this wrapper. The cluster's RaftNode
//! (src/distributed/raft_consensus.zig) keeps its hard state in the raft
//! library's FileStorage, which writes term and voted_for together
//! (raft v0.1.22 src/file_storage.zig: `hard_state` = term, voted_for, crc32).
//! Moved from tests/e2e_raft_persist_snapshot_membership.zig.
const std = @import("std");
const geode = @import("geode");
const raft_persistent = geode.distributed.raft_persistent;

test "SONNY-6548: raft_persistent.RaftNode keeps voted_for across a reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const sub = &tmp.sub_path;
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/raft_vf", .{sub});
    defer std.testing.allocator.free(path);

    // First session: set voted_for and close
    {
        var node = try raft_persistent.RaftNode.raftOpen(std.testing.allocator, path);
        try std.testing.expect(node.voted_for == null);
        node.voted_for = 5;
        node.deinit();
    }

    // Second session: verify voted_for was persisted
    {
        var node = try raft_persistent.RaftNode.raftOpen(std.testing.allocator, path);
        defer node.deinit();
        try std.testing.expectEqual(@as(?u32, 5), node.voted_for);
    }
}
