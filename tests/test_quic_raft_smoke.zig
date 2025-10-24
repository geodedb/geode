const std = @import("std");
const raft = @import("../src/distributed/raft_consensus.zig");

// Smoke test: simulate a RaftFrame line as would be received over a QUIC stream
// and ensure decode + handleMessage path works without network stack.
// This does not start a real QUIC listener; it focuses on the framing contract.
// CANARY: REQ=REQ-GQL-074; FEATURE="RaftFrame/TransportEnvelope"; ASPECT=NetworkTransport; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_074_RaftFrameSmoke; OWNER=cluster; UPDATED=2025-09-23
test "TestCANARY_REQ_GQL_074_RaftFrameSmoke" {
    const allocator = std.testing.allocator;
    var peers = [_]raft.Peer{.{ .id = 2, .endpoint = "127.0.0.1", .port = 8567, .alive = true, .last_contact = 0, .rpc_client = null }};
    var node = try raft.RaftNode.init(allocator, 1, &peers, 150);
    defer node.deinit();

    // Create an append_entries heartbeat style message (no entries) from peer id 2
    const msg = raft.Message{ .append_entries = .{ .term = 0, .leader_id = 2, .prev_log_index = 0, .prev_log_term = 0, .entries = &[_]raft.LogEntry{}, .leader_commit = 0 } };
    const line = try raft.encodeRaftFrame(allocator, 2, 0, msg);
    defer allocator.free(line);

    // Simulate receive path: decode and dispatch.
    const decoded = try raft.decodeRaftFrame(allocator, line);
    defer decoded.deinit(allocator);

    // Dispatch to Raft (as if cluster's handleQuicConnection forwarded it)
    try node.handleMessage(decoded.from, decoded.body);

    // Expectations: node term may update or remain (0), state should remain follower (no election triggered), and no panic.
    try std.testing.expect(node.state == .follower);
}
